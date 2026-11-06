import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase

/// `IValueChanged` (map/src/interfaces.ts). `previousValue` nil is `undefined`.
public struct IValueChanged {
  public let key: JSString
  public let previousValue: JSONValue?
}

/// `mapKernel.ts` PendingKeySet. Its identity is the set's local op metadata.
public final class PendingKeySet {
  let value: ILocalValue
  init(value: ILocalValue) {
    self.value = value
  }
}

/// `mapKernel.ts` PendingKeyDelete. Its identity is the delete's local op metadata.
public final class PendingKeyDelete {
  let key: JSString
  init(key: JSString) {
    self.key = key
  }
}

/// `mapKernel.ts` PendingClear. Its identity is the clear's local op metadata.
public final class PendingClear {
  init() {}
}

/// `mapKernel.ts` PendingKeyLifetime: consecutive pending sets of one key. `keySets` is never empty
/// while the lifetime is in `pendingData`.
final class PendingKeyLifetime {
  let key: JSString
  var keySets: [PendingKeySet] = []
  init(key: JSString) {
    self.key = key
  }
}

/// `mapKernel.ts` PendingDataEntry.
enum PendingDataEntry {
  case lifetime(PendingKeyLifetime)
  case delete(PendingKeyDelete)
  case clear(PendingClear)

  var isClear: Bool {
    if case .clear = self {
      return true
    }
    return false
  }

  /// The entry's key; nil for a clear.
  var key: JSString? {
    switch self {
    case .lifetime(let lifetime):
      return lifetime.key
    case .delete(let delete):
      return delete.key
    case .clear:
      return nil
    }
  }

  /// `entry.type === "clear" || entry.key === key`.
  func isClearOrKey(_ key: JSString) -> Bool {
    isClear || self.key == key
  }

  /// `entry.type === "clear" || (entry.type === "delete" && entry.key === key)`.
  func isClearOrDelete(_ key: JSString) -> Bool {
    switch self {
    case .clear:
      return true
    case .delete(let delete):
      return delete.key == key
    case .lifetime:
      return false
    }
  }
}

/// `mapKernel.ts` PendingLocalOpMetadata.
public enum PendingLocalOpMetadata {
  case set(PendingKeySet)
  case delete(PendingKeyDelete)
  case clear(PendingClear)
}

/// Port of `packages/dds/map/src/mapKernel.ts` MapKernel: sequenced data, pending key lifetimes,
/// local edits and op processing for SharedMap.
public final class MapKernel {
  private let submitMessage: (JSONValue, PendingLocalOpMetadata) throws -> Void
  private let isAttached: () -> Bool
  /// The SharedMap's "valueChanged" and "clear" events.
  var valueChanged: ((IValueChanged, Bool) -> Void)?
  var clearEvent: ((Bool) -> Void)?

  /// Sequenced values in JS Map insertion order.
  private var sequencedData = JSMap<JSString, ILocalValue>()
  private var pendingData: [PendingDataEntry] = []

  init(
    submitMessage: @escaping (JSONValue, PendingLocalOpMetadata) throws -> Void,
    isAttached: @escaping () -> Bool
  ) {
    self.submitMessage = submitMessage
    self.isAttached = isAttached
  }

  public var size: Int {
    internalIterator().count
  }

  /// `internalIterator`: sequenced keys that are not optimistically deleted or cleared, then pending
  /// lifetimes not later deleted or cleared. Keys therefore iterate in initial insertion order.
  private func internalIterator() -> [(JSString, ILocalValue)] {
    var result: [(JSString, ILocalValue)] = []
    for key in sequencedData.keys {
      let hidden = pendingData.contains { $0.isClearOrDelete(key) }
      if hidden {
        continue
      }
      // 0xbf1: never iterate to a key with an undefined optimistic value.
      guard let optimisticValue = getOptimisticLocalValue(key) else {
        preconditionFailure("0xbf1: iterated key without optimistic value")
      }
      result.append((key, optimisticValue))
    }
    for (index, entry) in pendingData.enumerated() {
      guard case .lifetime(let lifetime) = entry else {
        continue
      }
      let mostRecentDeleteOrClearIndex =
        pendingData.lastIndex { $0.isClearOrDelete(lifetime.key) } ?? -1
      if index <= mostRecentDeleteOrClearIndex {
        continue
      }
      guard let latestPendingValue = lifetime.keySets.last else {
        preconditionFailure("pending lifetime without key sets")
      }
      // Skip keys already iterated as part of the sequenced data.
      if !sequencedData.has(lifetime.key) || mostRecentDeleteOrClearIndex != -1 {
        result.append((lifetime.key, latestPendingValue.value))
      }
    }
    return result
  }

  public func entries() -> [(JSString, JSONValue?)] {
    internalIterator().map { ($0.0, $0.1.value) }
  }

  public func keys() -> [JSString] {
    internalIterator().map { $0.0 }
  }

  /// `getOptimisticLocalValue`: the last pending set, nil after a pending delete or clear, otherwise
  /// the sequenced value.
  private func getOptimisticLocalValue(_ key: JSString) -> ILocalValue? {
    guard let latestPendingEntry = pendingData.last(where: { $0.isClearOrKey(key) }) else {
      return sequencedData.get(key)
    }
    guard case .lifetime(let lifetime) = latestPendingEntry else {
      return nil
    }
    return lifetime.keySets.last?.value
  }

  public func get(_ key: JSString) -> JSONValue? {
    getOptimisticLocalValue(key)?.value
  }

  public func has(_ key: JSString) -> Bool {
    getOptimisticLocalValue(key) != nil
  }

  public func set(_ key: JSString, _ value: JSONValue?) throws {
    let localValue = ILocalValue(value: value)
    let previousOptimisticLocalValue = getOptimisticLocalValue(key)

    // If we are not attached, don't submit the op.
    if !isAttached() {
      sequencedData.set(key, localValue)
      valueChanged?(
        IValueChanged(key: key, previousValue: previousOptimisticLocalValue?.value), true)
      return
    }

    // A new lifetime starts unless the latest pending entry for the key is a lifetime.
    let lifetime: PendingKeyLifetime
    if case .lifetime(let latest) = pendingData.last(where: { $0.isClearOrKey(key) }) {
      lifetime = latest
    } else {
      lifetime = PendingKeyLifetime(key: key)
      pendingData.append(.lifetime(lifetime))
    }
    let pendingKeySet = PendingKeySet(value: localValue)
    lifetime.keySets.append(pendingKeySet)

    var op = JSObject<JSONValue>()
    op["key"] = .string(key)
    op["type"] = .string("set")
    op["value"] = serializableValue(localValue.value)
    try submitMessage(.object(op), .set(pendingKeySet))
    valueChanged?(
      IValueChanged(key: key, previousValue: previousOptimisticLocalValue?.value), true)
  }

  @discardableResult
  public func delete(_ key: JSString) throws -> Bool {
    let previousOptimisticLocalValue = getOptimisticLocalValue(key)

    if !isAttached() {
      let successfullyRemoved = sequencedData.delete(key)
      if let previousOptimisticLocalValue {
        valueChanged?(IValueChanged(key: key, previousValue: previousOptimisticLocalValue.value), true)
      }
      return successfullyRemoved
    }

    let pendingKeyDelete = PendingKeyDelete(key: key)
    pendingData.append(.delete(pendingKeyDelete))

    var op = JSObject<JSONValue>()
    op["key"] = .string(key)
    op["type"] = .string("delete")
    try submitMessage(.object(op), .delete(pendingKeyDelete))
    // Speculative deletes submit even when nothing is visible, but only emit when something was.
    if let previousOptimisticLocalValue {
      valueChanged?(IValueChanged(key: key, previousValue: previousOptimisticLocalValue.value), true)
    }
    return true
  }

  public func clear() throws {
    if !isAttached() {
      let keysToDelete = sequencedData.entries.map {
        IValueChanged(key: $0.key, previousValue: $0.value.value)
      }
      sequencedData.clear()
      clearEvent?(true)
      for changed in keysToDelete {
        valueChanged?(changed, true)
      }
      return
    }

    let keysToDelete = internalIterator().map {
      IValueChanged(key: $0.0, previousValue: $0.1.value)
    }
    let pendingClear = PendingClear()
    pendingData.append(.clear(pendingClear))

    var op = JSObject<JSONValue>()
    op["type"] = .string("clear")
    try submitMessage(.object(op), .clear(pendingClear))
    clearEvent?(true)
    for changed in keysToDelete {
      valueChanged?(changed, true)
    }
  }

  /// `getSerializedStorage`: sequenced data only, assigned to a plain object, so array-index keys
  /// enumerate first and `__proto__` (which sets the prototype) is not an own property.
  func getSerializedStorage() -> JSObject<ISerializedValue> {
    var serializedMapData = JSObject<ISerializedValue>()
    for (key, localValue) in sequencedData.entries where key != "__proto__" {
      serializedMapData[key] = serializeValue(localValue.value)
    }
    return serializedMapData
  }

  /// `populateFromSerializable`: `Object.entries` order, without events.
  func populateFromSerializable(_ json: JSONValue) throws {
    for (key, serializable) in try json.asObject().entries {
      sequencedData.set(key, ILocalValue(value: try parseSerializableValue(serializable)))
    }
  }

  /// `tryResubmitMessage`: forwards unchanged content with the original metadata.
  func tryResubmitMessage(_ op: JSONValue, _ localOpMetadata: PendingLocalOpMetadata) throws {
    try submitMessage(op, localOpMetadata)
  }

  func tryApplyStashedOp(_ op: JSONValue) throws {
    switch try op.member("type").asString() {
    case "clear":
      try clear()
    case "delete":
      try delete(op.member("key").asString())
    case "set":
      try set(op.member("key").asString(), parseSerializableValue(op.member("value")))
    default:
      throw SharedObjectError("unknown map stashed op")
    }
  }

  /// Rollback removes the overlay rather than restoring a captured value, exposing current
  /// sequenced state.
  func rollback(_ op: JSONValue, _ localOpMetadata: PendingLocalOpMetadata) throws {
    let type = try op.member("type").asString()
    if type == "clear" {
      guard case .clear(let pendingClear) = pendingData.popLast(),
        case .clear(let metadata) = localOpMetadata, pendingClear === metadata
      else {
        throw SharedObjectError("0xbf2: Unexpected clear rollback")
      }
      for (key, _) in internalIterator() {
        valueChanged?(IValueChanged(key: key, previousValue: nil), true)
      }
      return
    }
    let key = try op.member("key").asString()
    // The entry need not be last: lifetimes are ordered by creation, not by last modification.
    guard let pendingEntryIndex = pendingData.lastIndex(where: { !$0.isClear && $0.key == key })
    else {
      throw SharedObjectError("0xbf3: Unexpected pending data for set/delete op")
    }
    switch pendingData[pendingEntryIndex] {
    case .delete(let pendingDelete):
      guard case .delete(let metadata) = localOpMetadata, pendingDelete === metadata else {
        throw SharedObjectError("0xbf4: Unexpected delete rollback")
      }
      pendingData.remove(at: pendingEntryIndex)
      if getOptimisticLocalValue(key) != nil {
        valueChanged?(IValueChanged(key: key, previousValue: nil), true)
      }
    case .lifetime(let lifetime):
      guard let pendingKeySet = lifetime.keySets.popLast(),
        case .set(let metadata) = localOpMetadata, pendingKeySet === metadata
      else {
        throw SharedObjectError("0xbf5: Unexpected set rollback")
      }
      if lifetime.keySets.isEmpty {
        pendingData.remove(at: pendingEntryIndex)
      }
      valueChanged?(IValueChanged(key: key, previousValue: pendingKeySet.value.value), true)
    case .clear:
      throw SharedObjectError("0xbf3: Unexpected pending data for set/delete op")
    }
  }

  /// `tryProcessMessage` through the "clear", "delete" and "set" message handlers.
  func tryProcessMessage(
    _ op: JSONValue, local: Bool, localOpMetadata: PendingLocalOpMetadata?
  ) throws {
    switch try op.member("type").asString() {
    case "clear":
      try processClear(local: local, localOpMetadata: localOpMetadata)
    case "delete":
      try processDelete(op, local: local, localOpMetadata: localOpMetadata)
    case "set":
      try processSet(op, local: local, localOpMetadata: localOpMetadata)
    default:
      throw SharedObjectError(
        "0xab2: Map received an unrecognized op, possibly from a newer version")
    }
  }

  private func processClear(local: Bool, localOpMetadata: PendingLocalOpMetadata?) throws {
    if local {
      sequencedData.clear()
      guard case .clear(let pendingClear) = pendingData.first,
        case .clear(let metadata) = localOpMetadata, pendingClear === metadata
      else {
        throw SharedObjectError("0xbf6: Got a local clear message we weren't expecting")
      }
      pendingData.removeFirst()
      return
    }
    // Keys with pending edits stay optimistically visible, so they get no event.
    var keysToDelete: [IValueChanged] = []
    for (key, value) in sequencedData.entries {
      let hasPendingOps = pendingData.contains { !$0.isClear && $0.key == key }
      if !hasPendingOps {
        keysToDelete.append(IValueChanged(key: key, previousValue: value.value))
      }
    }
    sequencedData.clear()
    // A pending local clear supersedes this one optimistically.
    if !pendingData.contains(where: { $0.isClear }) {
      clearEvent?(local)
      for changed in keysToDelete {
        valueChanged?(changed, local)
      }
    }
  }

  private func processDelete(
    _ op: JSONValue, local: Bool, localOpMetadata: PendingLocalOpMetadata?
  ) throws {
    let key = try op.member("key").asString()
    if local {
      guard let pendingEntryIndex = pendingData.firstIndex(where: { !$0.isClear && $0.key == key }),
        case .delete(let pendingDelete) = pendingData[pendingEntryIndex],
        case .delete(let metadata) = localOpMetadata, pendingDelete === metadata
      else {
        throw SharedObjectError("0xbf7: Got a local delete message we weren't expecting")
      }
      pendingData.remove(at: pendingEntryIndex)
      sequencedData.delete(key)
      return
    }
    let previousValue = sequencedData.get(key)?.value
    sequencedData.delete(key)
    // Suppress the event if local changes would hide the incoming change optimistically.
    if !pendingData.contains(where: { $0.isClearOrKey(key) }) {
      valueChanged?(IValueChanged(key: key, previousValue: previousValue), local)
    }
  }

  private func processSet(
    _ op: JSONValue, local: Bool, localOpMetadata: PendingLocalOpMetadata?
  ) throws {
    let key = try op.member("key").asString()
    if local {
      guard let pendingEntryIndex = pendingData.firstIndex(where: { !$0.isClear && $0.key == key }),
        case .lifetime(let lifetime) = pendingData[pendingEntryIndex]
      else {
        throw SharedObjectError("0xbf8: Couldn't match local set message to pending lifetime")
      }
      guard let pendingKeySet = lifetime.keySets.first,
        case .set(let metadata) = localOpMetadata, pendingKeySet === metadata
      else {
        throw SharedObjectError("0xbf9: Got a local set message we weren't expecting")
      }
      lifetime.keySets.removeFirst()
      if lifetime.keySets.isEmpty {
        pendingData.remove(at: pendingEntryIndex)
      }
      sequencedData.set(key, pendingKeySet.value)
      return
    }
    let localValue = ILocalValue(value: try parseSerializableValue(op.member("value")))
    let previousValue = sequencedData.get(key)?.value
    sequencedData.set(key, localValue)
    // Suppress the event if local changes would hide the incoming change optimistically.
    if !pendingData.contains(where: { $0.isClearOrKey(key) }) {
      valueChanged?(IValueChanged(key: key, previousValue: previousValue), local)
    }
  }
}
