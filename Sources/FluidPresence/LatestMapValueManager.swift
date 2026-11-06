import FluidJS

/// Ports `LatestMapClientData`: one attendee's remote map items.
public struct LatestMapClientData {
  public let attendee: any Attendee
  public let items: JSMap<JSString, LatestData>
}

/// Ports `LatestMapItemUpdatedClientData`.
public struct LatestMapItemUpdatedClientData {
  public let attendee: any Attendee
  public let key: JSString
  public let value: ValueAccessor
  public let metadata: LatestMetadata
}

/// Ports `LatestMapItemRemovedClientData`.
public struct LatestMapItemRemovedClientData {
  public let attendee: any Attendee
  public let key: JSString
  public let metadata: LatestMetadata
}

/// Ports presence-definitions `LatestMapEvents`.
public enum LatestMapEvent {
  case remoteUpdated(LatestMapClientData)
  case remoteItemUpdated(LatestMapItemUpdatedClientData)
  case remoteItemRemoved(LatestMapItemRemovedClientData)
  case localItemUpdated(key: JSString, value: JSONValue)
  case localItemRemoved(key: JSString)
}

/// Ports `ValueMapImpl` of presence-runtime/src/states/latestMapValueManager.ts: the local view
/// of a latestMap (`StateMap`). Deleted keys stay in `value.items` as tombstones.
public final class ValueMapImpl {
  private var countDefined: Int
  private let value: ValueDirectory
  private let emitter: Emitter<LatestMapEvent>
  private let clock: any PresenceClock
  private let localUpdate: (ValueDirectory) throws -> Void

  init(
    value: ValueDirectory, emitter: Emitter<LatestMapEvent>, clock: any PresenceClock,
    localUpdate: @escaping (ValueDirectory) throws -> Void
  ) {
    self.value = value
    self.emitter = emitter
    self.clock = clock
    self.localUpdate = localUpdate
    // All initial items are expected to be defined.
    countDefined = value.items.count
  }

  /// The caller must ensure `key` exists in `value.items`.
  private func updateItem(_ key: JSString, _ newValue: JSONValue?) throws {
    value.rev += 1
    guard case .state(let item) = value.items[key] else {
      throw PresenceError.failed("latestMap item \(key) is not a state")
    }
    item.rev += 1
    item.timestamp = clock.now()
    item.value = newValue
    let update = ValueDirectory(rev: value.rev)
    update.items[key] = .state(item)
    try localUpdate(update)
  }

  public func clear() throws {
    throw PresenceError.failed("Method not implemented.")
  }

  @discardableResult
  public func delete(_ key: JSString) throws -> Bool {
    let hasKey = itemValue(key) != nil
    if hasKey {
      countDefined -= 1
      try updateItem(key, nil)
      try emitter.emit(.localItemRemoved(key: key))
    }
    return hasKey
  }

  public func forEach(_ callback: (_ value: JSONValue, _ key: JSString) -> Void) {
    for (key, item) in value.items.entries {
      if case .state(let state) = item, let itemValue = state.value {
        callback(itemValue, key)
      }
    }
  }

  public func get(_ key: JSString) -> JSONValue? {
    itemValue(key)
  }

  public func has(_ key: JSString) -> Bool {
    itemValue(key) != nil
  }

  public func set(_ key: JSString, _ newValue: JSONValue) throws {
    if value.items[key] == nil {
      countDefined += 1
      value.items[key] = .state(ValueState(rev: 0, timestamp: 0, value: newValue))
    }
    try updateItem(key, newValue)
    try emitter.emit(.localItemUpdated(key: key, value: newValue))
  }

  /// `countDefined`, which undercounts after a key is set again following a delete: the tombstone
  /// keeps the key in `items`, so the re-set does not increment it. Preserved from the oracle.
  public var size: Int {
    countDefined
  }

  public func keys() -> [JSString] {
    var keys: [JSString] = []
    forEach { _, key in keys.append(key) }
    return keys
  }

  private func itemValue(_ key: JSString) -> JSONValue? {
    guard case .state(let state) = value.items[key] else {
      return nil
    }
    return state.value
  }
}

/// Ports `LatestMapValueManagerImpl`.
public final class LatestMapValueManagerImpl: ValueManager {
  public let events = Emitter<LatestMapEvent>()
  public let controls: OptionalBroadcastControl
  public let local: ValueMapImpl
  private let key: JSString
  private let datastore: any StateDatastore
  private let validator: StateSchemaValidator?
  private let isValidKey: KeySchemaValidator

  init(
    key: JSString, datastore: any StateDatastore, value: ValueDirectory,
    controlSettings: BroadcastControlSettings?, validator: StateSchemaValidator?,
    isValidKey: @escaping KeySchemaValidator
  ) {
    self.key = key
    self.datastore = datastore
    self.validator = validator
    self.isValidKey = isValidKey
    let controls = OptionalBroadcastControl(settings: controlSettings)
    self.controls = controls
    local = ValueMapImpl(
      value: value, emitter: events, clock: datastore.clock,
      localUpdate: { updates in
        try datastore.localUpdate(
          key, value: .directory(updates),
          options: LocalStateUpdateOptions(allowableUpdateLatencyMs: controls.allowableUpdateLatencyMs))
      })
  }

  public var presence: any Presence {
    datastore.presence
  }

  public func getRemotes() throws -> [LatestMapClientData] {
    let allKnownStates = datastore.knownValues(key)
    var remotes: [LatestMapClientData] = []
    for attendeeId in allKnownStates.states.values.keys {
      if attendeeId != allKnownStates.selfAttendeeId {
        let attendee = try datastore.presence.attendees.getAttendee(attendeeId)
        let items = try getRemote(attendee)
        remotes.append(LatestMapClientData(attendee: attendee, items: items))
      }
    }
    return remotes
  }

  public func getStateAttendees() throws -> [any Attendee] {
    let allKnownStates = datastore.knownValues(key)
    return try allKnownStates.states.values.keys
      .filter { $0 != allKnownStates.selfAttendeeId }
      .map { try datastore.presence.attendees.getAttendee($0) }
  }

  /// The valid, defined items of one attendee. Throws `No entry for attendee`.
  public func getRemote(_ attendee: any Attendee) throws -> JSMap<JSString, LatestData> {
    let allKnownStates = datastore.knownValues(key)
    guard let node = allKnownStates.states.values[attendee.attendeeId] else {
      throw PresenceError.failed("No entry for attendee")
    }
    guard case .directory(let clientStateMap) = node else {
      throw PresenceError.failed("latestMap state \(attendee.attendeeId) is not a directory")
    }
    var items = JSMap<JSString, LatestData>()
    for (itemKey, itemNode) in clientStateMap.items.entries {
      if case .state(let item) = itemNode, isValidKey(itemKey), item.value != nil {
        items.set(
          itemKey,
          LatestData(
            value: createValidatedGetter(clientState: item, validator: validator),
            metadata: LatestMetadata(revision: item.rev, timestamp: item.timestamp)))
      }
    }
    return items
  }

  public func update(
    attendee: any Attendee, received: Double, value: ValueDirectoryOrState
  ) throws -> [PostUpdateAction] {
    guard case .directory(let valueDirectory) = value else {
      throw PresenceError.failed("latestMap manager received a state")
    }
    let allKnownStates = datastore.knownValues(key)
    let attendeeId = attendee.attendeeId
    let currentState: ValueDirectory
    if let existing = allKnownStates.states.values[attendeeId] {
      guard case .directory(let directory) = existing else {
        throw PresenceError.failed("latestMap state \(attendeeId) is not a directory")
      }
      currentState = directory
    } else {
      // New attendee: prepare the new attendee state directory.
      currentState = ValueDirectory(rev: valueDirectory.rev)
      allKnownStates.states.values[attendeeId] = .directory(currentState)
    }

    // Accumulate individual update keys: absent or with a larger revision, independently of the
    // directory revision.
    var updatedKeyItemPairs: [(JSString, ValueState)] = []
    for (itemKey, itemNode) in valueDirectory.items.entries {
      guard case .state(let item) = itemNode else {
        throw PresenceError.failed("latestMap item \(itemKey) is not a state")
      }
      if let currentItem = currentState.items[itemKey] {
        if currentItem.rev < item.rev {
          updatedKeyItemPairs.append((itemKey, item))
        }
      } else {
        updatedKeyItemPairs.append((itemKey, item))
      }
    }

    if updatedKeyItemPairs.isEmpty {
      return []
    }

    // Store updates.
    if valueDirectory.rev > currentState.rev {
      currentState.rev = valueDirectory.rev
    }
    var allUpdateItems = JSMap<JSString, LatestData>()
    var postUpdateActions: [PostUpdateAction] = []
    for (itemKey, item) in updatedKeyItemPairs {
      var hadPriorValue: JSONValue?
      if case .state(let prior) = currentState.items[itemKey] {
        hadPriorValue = prior.value
      }
      currentState.items[itemKey] = .state(item)

      // Prepare update events, but only for valid keys.
      if !isValidKey(itemKey) {
        continue
      }
      let metadata = LatestMetadata(revision: item.rev, timestamp: item.timestamp)
      if item.value != nil {
        let itemValue = createValidatedGetter(clientState: item, validator: validator)
        let updatedItem = LatestMapItemUpdatedClientData(
          attendee: attendee, key: itemKey, value: itemValue, metadata: metadata)
        postUpdateActions.append { [events] in
          try events.emit(.remoteItemUpdated(updatedItem))
        }
        allUpdateItems.set(itemKey, LatestData(value: itemValue, metadata: metadata))
      } else if hadPriorValue != nil {
        postUpdateActions.append { [events] in
          try events.emit(
            .remoteItemRemoved(
              LatestMapItemRemovedClientData(attendee: attendee, key: itemKey, metadata: metadata)))
        }
      }
    }
    datastore.update(key, clientId: attendeeId, value: .directory(currentState))
    // Only emit remoteUpdated if there are any individual updates, which accounts for the case
    // where all updates were for invalid keys.
    if !postUpdateActions.isEmpty {
      let allUpdates = LatestMapClientData(attendee: attendee, items: allUpdateItems)
      postUpdateActions.append { [events] in
        try events.emit(.remoteUpdated(allUpdates))
      }
    }
    return postUpdateActions
  }
}

/// Ports the `latestMap` factory. The initial directory is captured once when the factory is
/// created, every initial item with the same captured timestamp.
public final class LatestMapFactory: ManagerFactory {
  private let value = ValueDirectory(rev: 0)
  private let settings: BroadcastControlSettings?
  private let validator: StateSchemaValidator?
  private let isKeyValid: KeySchemaValidator

  public init(
    local: JSObject<JSONValue>? = nil, settings: BroadcastControlSettings? = nil,
    validator: StateSchemaValidator? = nil, keyValidator: KeySchemaValidator? = nil,
    clock: any PresenceClock
  ) {
    self.settings = settings
    self.validator = validator
    isKeyValid = keyValidator ?? { _ in true }
    let timestamp = clock.now()
    if let local {
      for (key, item) in local.entries {
        value.items[key] = .state(ValueState(rev: 0, timestamp: timestamp, value: item))
      }
    }
  }

  public func instantiate(key: JSString, datastore: any StateDatastore) -> ManagerInstantiation {
    ManagerInstantiation(
      initialData: .init(
        value: .directory(value), allowableUpdateLatencyMs: settings?.allowableUpdateLatencyMs),
      manager: LatestMapValueManagerImpl(
        key: key, datastore: datastore, value: value, controlSettings: settings,
        validator: validator, isValidKey: isKeyValid))
  }

  public func isInstance(_ manager: any ValueManager) -> Bool {
    manager is LatestMapValueManagerImpl
  }
}
