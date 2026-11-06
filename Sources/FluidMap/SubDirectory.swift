import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase

/// `IDirectoryValueChanged` (map/src/interfaces.ts). `previousValue` nil is `undefined`.
public struct IDirectoryValueChanged {
  public let key: JSString
  public let path: JSString
  public let previousValue: JSONValue?
}

/// `directory.ts` SequenceData: the creation order of a subdirectory.
struct SequenceData {
  var seq: Int
  var clientSeq: Int
}

/// `directory.ts` ICreateInfo, the persisted `ci`.
struct ICreateInfo {
  let csn: Int
  let ccIds: [JSString]
}

/// `directory.ts` seqDataComparator: acknowledged (or detached, seq 0) subdirectories precede local
/// pending ones; within each group, lower seq then lower clientSeq comes first.
func seqDataComparator(_ a: SequenceData, _ b: SequenceData) -> Int {
  if isAcknowledgedOrDetached(a) {
    if isAcknowledgedOrDetached(b) {
      return a.seq == b.seq ? a.clientSeq - b.clientSeq : a.seq - b.seq
    }
    return -1
  }
  if isAcknowledgedOrDetached(b) {
    return 1
  }
  return a.seq == b.seq ? a.clientSeq - b.clientSeq : a.seq - b.seq
}

func isAcknowledgedOrDetached(_ seqData: SequenceData) -> Bool {
  seqData.seq >= 0
}

/// `directory.ts` DirectoryLocalOpMetadata.
public enum DirectoryLocalOpMetadata {
  case set(SubDirectory.PendingKeySet)
  case delete(SubDirectory.PendingKeyDelete)
  case clear(SubDirectory.PendingClear)
  /// ICreateSubDirLocalOpMetadata.
  case createSubDir(parentSubdir: SubDirectory)
  /// IDeleteSubDirLocalOpMetadata.
  case deleteSubDir(subDirectory: SubDirectory, parentSubdir: SubDirectory)
}

/// `Array.prototype.sort` is stable; ties keep their original order.
private func stableSorted(
  _ entries: [(JSString, SubDirectory)]
) -> [(JSString, SubDirectory)] {
  entries.enumerated().sorted { a, b in
    let order = seqDataComparator(a.element.1.seqData, b.element.1.seqData)
    return order == 0 ? a.offset < b.offset : order < 0
  }.map(\.element)
}

/// Port of `packages/dds/map/src/directory.ts` SubDirectory: one node of the directory tree, with
/// sequenced storage and children plus the local pending overlays over them.
public final class SubDirectory {
  // Pending entries hold their subdirectory strongly, as TS does: runtime metadata can outlive the
  // subdirectory's place in the tree (a resubmit after deletion still reads `subdir.disposed`).
  // The entry/subdirectory cycle breaks when the entry is acknowledged or rolled back.

  /// `directory.ts` PendingKeySet. Its identity is the set's local op metadata.
  public final class PendingKeySet {
    let path: JSString
    let value: JSONValue?
    let subdir: SubDirectory
    init(path: JSString, value: JSONValue?, subdir: SubDirectory) {
      self.path = path
      self.value = value
      self.subdir = subdir
    }
  }

  /// `directory.ts` PendingKeyDelete. Its identity is the delete's local op metadata.
  public final class PendingKeyDelete {
    let path: JSString
    let key: JSString
    let subdir: SubDirectory
    init(path: JSString, key: JSString, subdir: SubDirectory) {
      self.path = path
      self.key = key
      self.subdir = subdir
    }
  }

  /// `directory.ts` PendingClear. Its identity is the clear's local op metadata.
  public final class PendingClear {
    let path: JSString
    let subdir: SubDirectory
    init(path: JSString, subdir: SubDirectory) {
      self.path = path
      self.subdir = subdir
    }
  }

  /// `directory.ts` PendingKeyLifetime: consecutive pending sets of one key; never empty while
  /// in pendingStorageData.
  final class PendingKeyLifetime {
    let key: JSString
    var keySets: [PendingKeySet] = []
    init(key: JSString) {
      self.key = key
    }
  }

  /// `directory.ts` PendingStorageEntry.
  enum PendingStorageEntry {
    case lifetime(PendingKeyLifetime)
    case delete(PendingKeyDelete)
    case clear(PendingClear)

    var isClear: Bool {
      if case .clear = self {
        return true
      }
      return false
    }

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

  /// `directory.ts` PendingSubDirectoryEntry.
  struct PendingSubDirectoryEntry {
    enum Kind {
      case createSubDirectory
      case deleteSubDirectory
    }
    let type: Kind
    let subdirName: JSString
    /// The created subdirectory, or the parent for a delete.
    let subdir: SubDirectory
  }

  /// Tells if the sub directory is deleted or not.
  public private(set) var disposed = false

  /// Sequenced children, independent of pending create/delete operations.
  private var _sequencedSubdirectories = JSMap<JSString, SubDirectory>()

  /// Orders subdirectories created locally but not yet acknowledged.
  var localCreationSeq = 0

  var seqData: SequenceData
  /// Creator client IDs, an insertion-ordered Set.
  private var clientIds: [JSString]
  private unowned let directory: SharedDirectory
  public let absolutePath: JSString

  /// Sequenced values only, in JS Map insertion order.
  private var sequencedStorageData = JSMap<JSString, ILocalValue>()
  /// Local pending storage changes; sets aggregate into lifetimes so iteration order survives
  /// remote operations and rollbacks.
  private var pendingStorageData: [PendingStorageEntry] = []
  /// Local pending subdirectory creates and deletes.
  private var pendingSubDirectoryData: [PendingSubDirectoryEntry] = []

  /// "containedValueChanged", "subDirectoryCreated" and "subDirectoryDeleted" listeners, in
  /// registration order. Registrations are not deduplicated.
  private var containedValueChangedListeners: [(IValueChanged, Bool) -> Void] = []
  private var subDirectoryCreatedListeners: [(JSString, Bool) -> Void] = []
  private var subDirectoryDeletedListeners: [(JSString, Bool) -> Void] = []

  init(
    seqData: SequenceData, clientIds: [JSString], directory: SharedDirectory,
    absolutePath: JSString
  ) {
    self.seqData = seqData
    self.clientIds = []
    self.directory = directory
    self.absolutePath = absolutePath
    for clientId in clientIds {
      addClientId(clientId)
    }
  }

  private func addClientId(_ clientId: JSString) {
    if !clientIds.contains(clientId) {
      clientIds.append(clientId)
    }
  }

  private var runtimeClientId: JSString {
    directory.runtime?.clientId ?? "detached"
  }

  func onContainedValueChanged(_ listener: @escaping (IValueChanged, Bool) -> Void) {
    containedValueChangedListeners.append(listener)
  }

  func onSubDirectoryCreated(_ listener: @escaping (JSString, Bool) -> Void) {
    subDirectoryCreatedListeners.append(listener)
  }

  func onSubDirectoryDeleted(_ listener: @escaping (JSString, Bool) -> Void) {
    subDirectoryDeletedListeners.append(listener)
  }

  private func emitContainedValueChanged(_ changed: IValueChanged, _ local: Bool) {
    for listener in containedValueChangedListeners {
      listener(changed, local)
    }
  }

  private func emitSubDirectoryCreated(_ relativePath: JSString, _ local: Bool) {
    for listener in subDirectoryCreatedListeners {
      listener(relativePath, local)
    }
  }

  private func emitSubDirectoryDeleted(_ relativePath: JSString, _ local: Bool) {
    for listener in subDirectoryDeletedListeners {
      listener(relativePath, local)
    }
  }

  /// The channel "valueChanged" then the subdirectory "containedValueChanged".
  private func emitValueChangedPair(_ key: JSString, _ previousValue: JSONValue?, _ local: Bool) {
    directory.emitValueChanged(
      IDirectoryValueChanged(key: key, path: absolutePath, previousValue: previousValue), local)
    emitContainedValueChanged(IValueChanged(key: key, previousValue: previousValue), local)
  }

  // The "disposed"/"undisposed" events have no Swift listeners, so dispose, undispose and
  // emitDisposeForSubdirTree only maintain the flag.
  func dispose() {
    disposed = true
  }

  private func undispose() {
    disposed = false
  }

  private func throwIfDisposed() throws {
    if disposed {
      throw SharedObjectError("Cannot access Disposed subDirectory")
    }
  }

  public func has(_ key: JSString) throws -> Bool {
    try throwIfDisposed()
    return optimisticallyHas(key)
  }

  public func get(_ key: JSString) -> JSONValue? {
    getOptimisticValue(key)
  }

  public func set(_ key: JSString, _ value: JSONValue?) throws {
    try throwIfDisposed()
    let previousOptimisticLocalValue = getOptimisticValue(key)

    // If we are not attached, don't submit the op.
    if !directory.isAttached {
      sequencedStorageData.set(key, ILocalValue(value: value))
      emitValueChangedPair(key, previousOptimisticLocalValue, true)
      return
    }

    // A new lifetime starts unless the latest pending entry for the key is a lifetime.
    let lifetime: PendingKeyLifetime
    if case .lifetime(let latest) = pendingStorageData.last(where: { $0.isClearOrKey(key) }) {
      lifetime = latest
    } else {
      lifetime = PendingKeyLifetime(key: key)
      pendingStorageData.append(.lifetime(lifetime))
    }
    let pendingKeySet = PendingKeySet(path: absolutePath, value: value, subdir: self)
    lifetime.keySets.append(pendingKeySet)

    var op = JSObject<JSONValue>()
    op["key"] = .string(key)
    op["path"] = .string(absolutePath)
    op["type"] = .string("set")
    op["value"] = serializableValue(value)
    try submitKeyMessage(.object(op), .set(pendingKeySet))
    emitValueChangedPair(key, previousOptimisticLocalValue, true)
  }

  public func countSubDirectory() throws -> Int {
    try subdirectories().count
  }

  @discardableResult
  public func createSubDirectory(_ subdirName: JSString) throws -> SubDirectory {
    try throwIfDisposed()
    if subdirName.utf16.contains(0x2F) {
      throw SharedObjectError("SubDirectory name may not contain \(PosixPath.sep)")
    }

    var subDir = getOptimisticSubDirectory(subdirName, getIfDisposed: true)
    let seqData = getLocalSeq()
    let clientId = runtimeClientId
    let isNewSubDirectory = subDir == nil

    let target: SubDirectory
    if let existing = subDir {
      if existing.disposed {
        // Reuse the disposed instance so its pending changes survive.
        undisposeSubdirectoryTree(existing)
      }
      existing.addClientId(clientId)
      target = existing
    } else {
      target = SubDirectory(
        seqData: seqData, clientIds: [clientId], directory: directory,
        absolutePath: PosixPath.join(absolutePath, subdirName))
      subDir = target
    }

    registerEventsOnSubDirectory(target, subdirName)

    // Only submit the op and emit the event when a new subdirectory was created.
    if isNewSubDirectory {
      if directory.isAttached {
        pendingSubDirectoryData.append(
          PendingSubDirectoryEntry(
            type: .createSubDirectory, subdirName: subdirName, subdir: target))
        var op = JSObject<JSONValue>()
        op["subdirName"] = .string(subdirName)
        op["path"] = .string(absolutePath)
        op["type"] = .string("createSubDirectory")
        try submitCreateSubDirectoryMessage(.object(op))
      } else {
        _sequencedSubdirectories.set(subdirName, target)
      }
      emitSubDirectoryCreated(subdirName, true)
    }
    return target
  }

  /// `getLocalSeq`: detached creations use seq 0 (universally known); attached ones -1. The
  /// clientSeq counter increments on every call, even when no subdirectory is created.
  private func getLocalSeq() -> SequenceData {
    localCreationSeq += 1
    return SequenceData(seq: directory.isAttached ? -1 : 0, clientSeq: localCreationSeq)
  }

  public func getSubDirectory(_ subdirName: JSString) throws -> SubDirectory? {
    try throwIfDisposed()
    return getOptimisticSubDirectory(subdirName)
  }

  public func hasSubDirectory(_ subdirName: JSString) throws -> Bool {
    try throwIfDisposed()
    return getOptimisticSubDirectory(subdirName) != nil
  }

  @discardableResult
  public func deleteSubDirectory(_ subdirName: JSString) throws -> Bool {
    try throwIfDisposed()

    if !directory.isAttached {
      let previousValue = _sequencedSubdirectories.get(subdirName)
      let successfullyRemoved = _sequencedSubdirectories.delete(subdirName)
      if successfullyRemoved {
        try disposeSubDirectoryTree(previousValue)
        emitSubDirectoryDeleted(subdirName, true)
      }
      return successfullyRemoved
    }

    guard let previousOptimisticSubDirectory = getOptimisticSubDirectory(subdirName) else {
      return false
    }
    pendingSubDirectoryData.append(
      PendingSubDirectoryEntry(type: .deleteSubDirectory, subdirName: subdirName, subdir: self))
    var op = JSObject<JSONValue>()
    op["subdirName"] = .string(subdirName)
    op["type"] = .string("deleteSubDirectory")
    op["path"] = .string(absolutePath)
    try submitDeleteSubDirectoryMessage(.object(op), previousOptimisticSubDirectory)
    emitSubDirectoryDeleted(subdirName, true)
    // A pending delete only emits "disposed" for the tree (emitDisposeForSubdirTree); it is not
    // disposed until sequenced.
    return true
  }

  /// The optimistic children: sequenced and pending ones without a pending delete, in creation
  /// order (seqDataComparator).
  public func subdirectories() throws -> [(JSString, SubDirectory)] {
    try throwIfDisposed()
    return optimisticSubdirectories(getIfDisposed: false)
  }

  /// `subdirectories` without the disposed check, or `getSubdirectoriesEvenIfDisposed`.
  private func optimisticSubdirectories(getIfDisposed: Bool) -> [(JSString, SubDirectory)] {
    var sequencedSubdirs: [(JSString, SubDirectory)] = []
    let sequencedSubdirNames = _sequencedSubdirectories.keys
    for subdirName in sequencedSubdirNames {
      if let optimisticSubdir = getOptimisticSubDirectory(
        subdirName, getIfDisposed: getIfDisposed)
      {
        sequencedSubdirs.append((subdirName, optimisticSubdir))
      }
    }
    var pendingSubdirNames: [JSString] = []
    for entry in pendingSubDirectoryData {
      let name = entry.subdirName
      if !sequencedSubdirNames.contains(name) && !pendingSubdirNames.contains(name) {
        pendingSubdirNames.append(name)
      }
    }
    var pendingSubdirs: [(JSString, SubDirectory)] = []
    for subdirName in pendingSubdirNames {
      if let optimisticSubdir = getOptimisticSubDirectory(
        subdirName, getIfDisposed: getIfDisposed)
      {
        pendingSubdirs.append((subdirName, optimisticSubdir))
      }
    }
    return stableSorted(sequencedSubdirs + pendingSubdirs)
  }

  public func getWorkingDirectory(_ relativePath: JSString) throws -> SubDirectory? {
    try throwIfDisposed()
    return try directory.getWorkingDirectory(makeAbsolute(relativePath))
  }

  /// Whether a local delete of the child is pending.
  public func isSubDirectoryDeletePending(_ subDirName: JSString) -> Bool {
    pendingSubDirectoryData.contains {
      $0.subdirName == subDirName && $0.type == .deleteSubDirectory
    }
  }

  @discardableResult
  public func delete(_ key: JSString) throws -> Bool {
    try throwIfDisposed()
    let previousOptimisticLocalValue = getOptimisticValue(key)

    if !directory.isAttached {
      let successfullyRemoved = sequencedStorageData.delete(key)
      // Only emit if we actually deleted something.
      if try isNotDisposedAndReachable() && previousOptimisticLocalValue != nil
        && successfullyRemoved
      {
        emitValueChangedPair(key, previousOptimisticLocalValue, true)
      }
      return successfullyRemoved
    }

    let pendingKeyDelete = PendingKeyDelete(path: absolutePath, key: key, subdir: self)
    pendingStorageData.append(.delete(pendingKeyDelete))
    var op = JSObject<JSONValue>()
    op["key"] = .string(key)
    op["type"] = .string("delete")
    op["path"] = .string(absolutePath)
    try submitKeyMessage(.object(op), .delete(pendingKeyDelete))
    // Speculative deletes submit regardless; emit only when a defined value was visible. Unlike
    // SharedMap, deleting a present undefined value emits nothing.
    if try isNotDisposedAndReachable() && previousOptimisticLocalValue != nil {
      emitValueChangedPair(key, previousOptimisticLocalValue, true)
    }
    return true
  }

  public func clear() throws {
    try throwIfDisposed()

    if !directory.isAttached {
      sequencedStorageData.clear()
      directory.emitClear(true)
      directory.emitCleared(absolutePath, true)
      return
    }

    let pendingClear = PendingClear(path: absolutePath, subdir: self)
    pendingStorageData.append(.clear(pendingClear))
    // The events precede the submit here, unlike set and delete.
    directory.emitClear(true)
    directory.emitCleared(absolutePath, true)
    var op = JSObject<JSONValue>()
    op["type"] = .string("clear")
    op["path"] = .string(absolutePath)
    try submitClearMessage(.object(op), pendingClear)
  }

  public func size() throws -> Int {
    try throwIfDisposed()
    return try internalIterator().count
  }

  public func entries() throws -> [(JSString, JSONValue?)] {
    try throwIfDisposed()
    return try internalIterator()
  }

  public func keys() throws -> [JSString] {
    try throwIfDisposed()
    return try internalIterator().map { $0.0 }
  }

  /// `internalIterator`: sequenced keys not optimistically deleted or cleared, then pending
  /// lifetimes not later deleted or cleared, giving initial insertion order like a native Map.
  private func internalIterator() throws -> [(JSString, JSONValue?)] {
    var result: [(JSString, JSONValue?)] = []
    for key in sequencedStorageData.keys {
      let hidden = pendingStorageData.contains { $0.isClearOrDelete(key) }
      if hidden {
        continue
      }
      // 0xc03: key should exist in sequenced or pending data.
      guard try has(key) else {
        throw SharedObjectError("0xc03: key should exist in sequenced or pending data")
      }
      result.append((key, getOptimisticValue(key)))
    }
    for (index, entry) in pendingStorageData.enumerated() {
      guard case .lifetime(let lifetime) = entry else {
        continue
      }
      let mostRecentDeleteOrClearIndex =
        pendingStorageData.lastIndex { $0.isClearOrDelete(lifetime.key) } ?? -1
      if index <= mostRecentDeleteOrClearIndex {
        continue
      }
      guard let latestPendingValue = lifetime.keySets.last else {
        throw SharedObjectError("pending lifetime without key sets")
      }
      // Skip keys already iterated as part of the sequenced data.
      if !sequencedStorageData.has(lifetime.key) || mostRecentDeleteOrClearIndex != -1 {
        result.append((lifetime.key, latestPendingValue.value))
      }
    }
    return result
  }

  /// `getOptimisticValue`: the last pending set, undefined after a pending delete or clear,
  /// otherwise the sequenced value.
  private func getOptimisticValue(_ key: JSString) -> JSONValue? {
    guard let latestPendingEntry = pendingStorageData.last(where: { $0.isClearOrKey(key) }) else {
      return sequencedStorageData.get(key)?.value
    }
    guard case .lifetime(let lifetime) = latestPendingEntry else {
      return nil
    }
    return lifetime.keySets.last?.value
  }

  /// True even when the value is undefined.
  private func optimisticallyHas(_ key: JSString) -> Bool {
    guard let latestPendingEntry = pendingStorageData.last(where: { $0.isClearOrKey(key) }) else {
      return sequencedStorageData.has(key)
    }
    if case .lifetime = latestPendingEntry {
      return true
    }
    return false
  }

  /// `getOptimisticSubDirectory`: disposed subdirectories count as absent unless `getIfDisposed`.
  private func getOptimisticSubDirectory(
    _ subdirName: JSString, getIfDisposed: Bool = false
  ) -> SubDirectory? {
    let subdir: SubDirectory?
    if let latestPendingEntry = pendingSubDirectoryData.last(where: {
      $0.subdirName == subdirName
    }) {
      guard latestPendingEntry.type == .createSubDirectory else {
        // Pending delete.
        return nil
      }
      subdir = latestPendingEntry.subdir
    } else {
      subdir = _sequencedSubdirectories.get(subdirName)
    }
    if let subdir, subdir.disposed, !getIfDisposed {
      return nil
    }
    return subdir
  }

  /// Not disposed and reachable through getWorkingDirectory (which respects pending deletes):
  /// events from remote ops are only emitted for directories visible optimistically.
  private func isNotDisposedAndReachable() throws -> Bool {
    if disposed {
      return false
    }
    return try directory.getWorkingDirectory(absolutePath) != nil
  }

  func sequencedSubdirectories() throws -> JSMap<JSString, SubDirectory> {
    try throwIfDisposed()
    return _sequencedSubdirectories
  }

  func processClearMessage(
    _ msgEnvelope: SequencedMessage, local: Bool, localOpMetadata: PendingClear?
  ) throws {
    try throwIfDisposed()
    guard isMessageForCurrentInstanceOfSubDirectory(msgEnvelope, localOpMetadata?.subdir) else {
      return
    }

    if local {
      sequencedStorageData.clear()
      guard case .clear(let pendingClear) = pendingStorageData.first,
        let localOpMetadata, pendingClear === localOpMetadata
      else {
        throw SharedObjectError("0xc04: Got a local clear message we weren't expecting")
      }
      pendingStorageData.removeFirst()
      return
    }

    // Collect previous values of pending sets before clearing sequenced data. Every lifetime gets
    // an event, in pending order, even when a later delete or clear supersedes it.
    var pendingSets: [(JSString, JSONValue?)] = []
    for entry in pendingStorageData {
      if case .lifetime(let lifetime) = entry {
        pendingSets.append((lifetime.key, sequencedStorageData.get(lifetime.key)?.value))
      }
    }
    sequencedStorageData.clear()

    // Only emit when no optimistically-applied local clear supersedes this remote clear.
    if !pendingStorageData.contains(where: { $0.isClear }) {
      directory.emitClear(local)
      directory.emitCleared(absolutePath, local)
    }
    for (key, previousValue) in pendingSets {
      if try !isNotDisposedAndReachable() {
        break
      }
      directory.emitValueChanged(
        IDirectoryValueChanged(key: key, path: absolutePath, previousValue: previousValue), local)
    }
  }

  func processDeleteMessage(
    _ msgEnvelope: SequencedMessage, key: JSString, local: Bool,
    localOpMetadata: DirectoryLocalOpMetadata?
  ) throws {
    try throwIfDisposed()
    guard isMessageForCurrentInstanceOfSubDirectory(msgEnvelope, localOpMetadata?.editSubdir)
    else {
      return
    }
    if local {
      // Matches the first key entry by type and key only, not by metadata identity.
      guard
        let pendingEntryIndex = pendingStorageData.firstIndex(where: {
          !$0.isClear && $0.key == key
        }),
        case .delete = pendingStorageData[pendingEntryIndex]
      else {
        throw SharedObjectError("0xc05: Got a local delete message we weren't expecting")
      }
      pendingStorageData.remove(at: pendingEntryIndex)
      sequencedStorageData.delete(key)
      return
    }
    let previousValue = sequencedStorageData.get(key)?.value
    sequencedStorageData.delete(key)
    // Suppress the event if local changes would hide the incoming change optimistically.
    if try isNotDisposedAndReachable()
      && !pendingStorageData.contains(where: { $0.isClearOrKey(key) })
    {
      emitValueChangedPair(key, previousValue, local)
    }
  }

  func processSetMessage(
    _ msgEnvelope: SequencedMessage, key: JSString, value: JSONValue?, local: Bool,
    localOpMetadata: DirectoryLocalOpMetadata?
  ) throws {
    try throwIfDisposed()
    guard isMessageForCurrentInstanceOfSubDirectory(msgEnvelope, localOpMetadata?.editSubdir)
    else {
      return
    }
    if local {
      guard
        let pendingEntryIndex = pendingStorageData.firstIndex(where: {
          !$0.isClear && $0.key == key
        }),
        case .lifetime(let lifetime) = pendingStorageData[pendingEntryIndex]
      else {
        throw SharedObjectError("0xc06: Couldn't match local set message to pending lifetime")
      }
      guard let pendingKeySet = lifetime.keySets.first,
        case .set(let metadata) = localOpMetadata, pendingKeySet === metadata
      else {
        throw SharedObjectError("0xc07: Got a local set message we weren't expecting")
      }
      lifetime.keySets.removeFirst()
      if lifetime.keySets.isEmpty {
        pendingStorageData.remove(at: pendingEntryIndex)
      }
      sequencedStorageData.set(key, ILocalValue(value: pendingKeySet.value))
      return
    }
    let previousValue = sequencedStorageData.get(key)?.value
    sequencedStorageData.set(key, ILocalValue(value: value))
    // Suppress the event if local changes would hide the incoming change optimistically.
    if try isNotDisposedAndReachable()
      && !pendingStorageData.contains(where: { $0.isClearOrKey(key) })
    {
      emitValueChangedPair(key, previousValue, local)
    }
  }

  func processCreateSubDirectoryMessage(
    _ msgEnvelope: SequencedMessage, subdirName: JSString, local: Bool,
    localOpMetadata: DirectoryLocalOpMetadata?, clientSequenceNumber: Int
  ) throws {
    try throwIfDisposed()
    guard
      isMessageForCurrentInstanceOfSubDirectory(msgEnvelope, localOpMetadata?.parentSubdir)
    else {
      return
    }

    let subDir: SubDirectory
    if local {
      guard
        let pendingEntryIndex = pendingSubDirectoryData.firstIndex(where: {
          $0.subdirName == subdirName
        }),
        pendingSubDirectoryData[pendingEntryIndex].type == .createSubDirectory
      else {
        throw SharedObjectError("0xc30: Got a local subdir create message we weren't expecting")
      }
      subDir = pendingSubDirectoryData[pendingEntryIndex].subdir
      pendingSubDirectoryData.remove(at: pendingEntryIndex)

      // A remote create of the same name may already have been processed.
      if _sequencedSubdirectories.has(subdirName) {
        return
      }
      if subDir.disposed {
        undisposeSubdirectoryTree(subDir)
      }
      _sequencedSubdirectories.set(subdirName, subDir)
    } else {
      if let existing = getOptimisticSubDirectory(subdirName, getIfDisposed: true) {
        // Remote clients may have created the same subdirectory too.
        if existing.disposed {
          undisposeSubdirectoryTree(existing)
        }
        existing.addClientId(msgEnvelope.clientId)
        subDir = existing
      } else {
        subDir = SubDirectory(
          seqData: SequenceData(
            seq: msgEnvelope.sequenceNumber, clientSeq: clientSequenceNumber),
          clientIds: [msgEnvelope.clientId], directory: directory,
          absolutePath: PosixPath.join(absolutePath, subdirName))
      }
      registerEventsOnSubDirectory(subDir, subdirName)
      _sequencedSubdirectories.set(subdirName, subDir)

      // Suppress the event if local changes would hide the incoming change optimistically.
      if !pendingSubDirectoryData.contains(where: { $0.subdirName == subdirName }),
        try subDir.isNotDisposedAndReachable()
      {
        emitSubDirectoryCreated(subdirName, local)
      }
    }

    // Repair seqData when a subdirectory was created, deleted and later recreated.
    if seqData.seq != -1 && seqData.seq <= msgEnvelope.sequenceNumber && subDir.seqData.seq == -1 {
      subDir.seqData.seq = msgEnvelope.sequenceNumber
      subDir.seqData.clientSeq = clientSequenceNumber
    }
  }

  func processDeleteSubDirectoryMessage(
    _ msgEnvelope: SequencedMessage, subdirName: JSString, local: Bool,
    localOpMetadata: DirectoryLocalOpMetadata?
  ) throws {
    try throwIfDisposed()
    guard
      isMessageForCurrentInstanceOfSubDirectory(msgEnvelope, localOpMetadata?.parentSubdir)
    else {
      return
    }

    guard let previousValue = _sequencedSubdirectories.get(subdirName) else {
      // Already deleted, e.g. by a remote delete processed first: retire a local pending delete.
      if local {
        try removeFirstPendingDelete(subdirName, assertCode: "0xc31")
      }
      return
    }

    _sequencedSubdirectories.delete(subdirName)
    try disposeSubDirectoryTree(previousValue)

    if local {
      try removeFirstPendingDelete(subdirName, assertCode: "0xc32")
    } else if !isSubDirectoryDeletePending(subdirName) {
      // Suppress the event if local changes would hide the incoming change optimistically.
      emitSubDirectoryDeleted(subdirName, local)
    }
  }

  private func removeFirstPendingDelete(_ subdirName: JSString, assertCode: String) throws {
    guard
      let pendingEntryIndex = pendingSubDirectoryData.firstIndex(where: {
        $0.subdirName == subdirName
      }),
      pendingSubDirectoryData[pendingEntryIndex].type == .deleteSubDirectory
    else {
      throw SharedObjectError(
        "\(assertCode): Got a local deleteSubDirectory message we weren't expecting")
    }
    pendingSubDirectoryData.remove(at: pendingEntryIndex)
  }

  private func submitClearMessage(_ op: JSONValue, _ localOpMetadata: PendingClear) throws {
    try throwIfDisposed()
    try directory.submitDirectoryMessage(op, .clear(localOpMetadata))
  }

  /// Resubmits only if this instance still has a pending clear; an older deleted instance has none.
  func resubmitClearMessage(_ op: JSONValue, _ localOpMetadata: PendingClear) throws {
    if pendingStorageData.contains(where: { $0.isClear }) {
      try submitClearMessage(op, localOpMetadata)
    }
  }

  private func submitKeyMessage(_ op: JSONValue, _ localOpMetadata: DirectoryLocalOpMetadata)
    throws
  {
    try throwIfDisposed()
    try directory.submitDirectoryMessage(op, localOpMetadata)
  }

  /// Resubmits only if the pending entry still exists; for sets, its lifetime must still hold this
  /// exact key set.
  func resubmitKeyMessage(_ op: JSONValue, _ localOpMetadata: DirectoryLocalOpMetadata) throws {
    let type = try op.member("type").asString()
    let key = try op.member("key").asString()
    let found = pendingStorageData.contains { entry in
      if type == "set" {
        guard case .lifetime(let lifetime) = entry, lifetime.key == key,
          case .set(let pendingKeySet) = localOpMetadata
        else {
          return false
        }
        return lifetime.keySets.contains { $0 === pendingKeySet }
      }
      guard case .delete(let delete) = entry else {
        return false
      }
      return delete.key == key
    }
    if found {
      try submitKeyMessage(op, localOpMetadata)
    }
  }

  private func submitCreateSubDirectoryMessage(_ op: JSONValue) throws {
    try directory.submitDirectoryMessage(op, .createSubDir(parentSubdir: self))
  }

  private func submitDeleteSubDirectoryMessage(_ op: JSONValue, _ subDir: SubDirectory) throws {
    try directory.submitDirectoryMessage(
      op, .deleteSubDir(subDirectory: subDir, parentSubdir: self))
  }

  /// Resubmits a subdirectory op with fresh metadata, if its pending entry still exists.
  func resubmitSubDirectoryMessage(_ op: JSONValue, _ localOpMetadata: DirectoryLocalOpMetadata)
    throws
  {
    let subdirName = try op.member("subdirName").asString()
    switch localOpMetadata {
    case .createSubDir:
      guard
        let pendingEntry = pendingSubDirectoryData.last(where: {
          $0.subdirName == subdirName && $0.type == .createSubDirectory
        })
      else {
        return
      }
      // Reconnecting can change the client ID.
      pendingEntry.subdir.addClientId(runtimeClientId)
      undisposeSubdirectoryTree(pendingEntry.subdir)
      try submitCreateSubDirectoryMessage(op)
    case .deleteSubDir(let subDirectory, _):
      if isSubDirectoryDeletePending(subdirName) {
        try submitDeleteSubDirectoryMessage(op, subDirectory)
      }
    case .set, .delete, .clear:
      throw SharedObjectError("unexpected subdirectory op metadata")
    }
  }

  /// Sequenced storage only, in Map order.
  func getSerializedStorage() throws -> [(JSString, ISerializedValue)] {
    try throwIfDisposed()
    return sequencedStorageData.entries.map { ($0.key, serializeValue($0.value.value)) }
  }

  func getSerializableCreateInfo() throws -> ICreateInfo {
    try throwIfDisposed()
    return ICreateInfo(csn: seqData.seq, ccIds: clientIds)
  }

  /// Loading from a snapshot: no events.
  func populateStorage(_ key: JSString, _ value: JSONValue?) throws {
    try throwIfDisposed()
    sequencedStorageData.set(key, ILocalValue(value: value))
  }

  func populateSubDirectory(_ subdirName: JSString, _ newSubDir: SubDirectory) throws {
    try throwIfDisposed()
    registerEventsOnSubDirectory(newSubDir, subdirName)
    _sequencedSubdirectories.set(subdirName, newSubDir)
  }

  func rollback(_ op: JSONValue, _ localOpMetadata: DirectoryLocalOpMetadata) throws {
    let type = try op.member("type").asString()
    switch (type, localOpMetadata) {
    case ("clear", .clear):
      // A pending clear is last, since it terminates all prior lifetimes. None means a remote
      // subdirectory delete already discarded the pending data.
      guard let pendingClear = pendingStorageData.popLast() else {
        return
      }
      guard pendingClear.isClear else {
        throw SharedObjectError("0xc35: Unexpected clear rollback")
      }
      for (key, _) in try internalIterator() {
        emitValueChangedPair(key, nil, true)
      }
    case ("set", .set), ("set", .delete), ("delete", .set), ("delete", .delete):
      let key = try op.member("key").asString()
      // Lifetimes are ordered by creation, so the entry need not be last.
      guard
        let pendingEntryIndex = pendingStorageData.lastIndex(where: {
          !$0.isClear && $0.key == key
        })
      else {
        return
      }
      switch pendingStorageData[pendingEntryIndex] {
      case .delete(let pendingDelete):
        guard case .delete(let metadata) = localOpMetadata, pendingDelete === metadata else {
          throw SharedObjectError("0xc0b: Unexpected delete rollback")
        }
        pendingStorageData.remove(at: pendingEntryIndex)
        // Only emit if rolling back the delete makes a value visible.
        if getOptimisticValue(key) != nil {
          emitValueChangedPair(key, nil, true)
        }
      case .lifetime(let lifetime):
        guard let pendingKeySet = lifetime.keySets.popLast(),
          case .set(let metadata) = localOpMetadata, pendingKeySet === metadata
        else {
          throw SharedObjectError("0xc0c: Unexpected set rollback")
        }
        if lifetime.keySets.isEmpty {
          pendingStorageData.remove(at: pendingEntryIndex)
        }
        emitValueChangedPair(key, pendingKeySet.value, true)
      case .clear:
        throw SharedObjectError("0xc36: Unexpected pending data for set/delete op")
      }
    case ("createSubDirectory", .createSubDir):
      let subdirName = try op.member("subdirName").asString()
      guard
        let pendingEntryIndex = pendingSubDirectoryData.lastIndex(where: {
          $0.type == .createSubDirectory && $0.subdirName == subdirName
        })
      else {
        // A remote delete may have discarded this pending data already.
        return
      }
      pendingSubDirectoryData.remove(at: pendingEntryIndex)
      emitSubDirectoryDeleted(subdirName, true)
    case ("deleteSubDirectory", .deleteSubDir(let subDirectoryToRestore, _)):
      let subdirName = try op.member("subdirName").asString()
      guard
        let pendingEntryIndex = pendingSubDirectoryData.lastIndex(where: {
          $0.type == .deleteSubDirectory && $0.subdirName == subdirName
        })
      else {
        return
      }
      pendingSubDirectoryData.remove(at: pendingEntryIndex)
      undisposeSubdirectoryTree(subDirectoryToRestore)
      registerEventsOnSubDirectory(subDirectoryToRestore, subdirName)
      emitSubDirectoryCreated(subdirName, true)
    default:
      throw SharedObjectError("Unsupported op for rollback")
    }
  }

  private func makeAbsolute(_ relativePath: JSString) -> JSString {
    PosixPath.resolve(absolutePath, relativePath)
  }

  /// The message targets this instance (for a local op) AND was sent by a creator, or this was
  /// created detached, or this was already live when the op was created.
  private func isMessageForCurrentInstanceOfSubDirectory(
    _ msgEnvelope: SequencedMessage, _ targetSubdir: SubDirectory?
  ) -> Bool {
    let isTarget = targetSubdir == nil || targetSubdir === self
    let fromCreator = clientIds.contains(msgEnvelope.clientId)
    let detached = clientIds.contains("detached")
    let live = seqData.seq != -1 && seqData.seq <= msgEnvelope.referenceSequenceNumber
    return isTarget && (fromCreator || detached || live)
  }

  /// Adds bubbling listeners on every call, even for an already-registered child.
  private func registerEventsOnSubDirectory(_ subDirectory: SubDirectory, _ subDirName: JSString) {
    subDirectory.onSubDirectoryCreated { [weak self] relativePath, local in
      self?.emitSubDirectoryCreated(PosixPath.join(subDirName, relativePath), local)
    }
    subDirectory.onSubDirectoryDeleted { [weak self] relativePath, local in
      self?.emitSubDirectoryDeleted(PosixPath.join(subDirName, relativePath), local)
    }
  }

  /// Disposes bottom-up, clearing sequenced data (pending data survives for a re-create).
  private func disposeSubDirectoryTree(_ directory: SubDirectory?) throws {
    guard let directory else {
      return
    }
    for (_, subDirectory) in try directory.subdirectories() {
      try disposeSubDirectoryTree(subDirectory)
    }
    directory.clearSubDirectorySequencedData()
    directory.dispose()
  }

  /// Un-disposes bottom-up, including already-disposed descendants.
  private func undisposeSubdirectoryTree(_ directory: SubDirectory) {
    for (_, subDirectory) in directory.optimisticSubdirectories(getIfDisposed: true) {
      undisposeSubdirectoryTree(subDirectory)
    }
    directory.undispose()
  }

  /// Clears sequenced data but keeps pending storage data, so a re-create keeps pending ops.
  private func clearSubDirectorySequencedData() {
    seqData.seq = -1
    seqData.clientSeq = -1
    sequencedStorageData.clear()
    _sequencedSubdirectories.clear()
    clientIds.removeAll()
    addClientId(runtimeClientId)
  }
}

extension DirectoryLocalOpMetadata {
  /// EditLocalOpMetadata.subdir.
  var editSubdir: SubDirectory? {
    switch self {
    case .set(let set):
      return set.subdir
    case .delete(let delete):
      return delete.subdir
    case .clear(let clear):
      return clear.subdir
    case .createSubDir, .deleteSubDir:
      return nil
    }
  }

  /// SubDirLocalOpMetadata.parentSubdir.
  var parentSubdir: SubDirectory? {
    switch self {
    case .createSubDir(let parentSubdir):
      return parentSubdir
    case .deleteSubDir(_, let parentSubdir):
      return parentSubdir
    case .set, .delete, .clear:
      return nil
    }
  }
}
