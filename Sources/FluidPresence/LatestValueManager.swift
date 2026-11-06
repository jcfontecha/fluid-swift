import FluidJS

/// Ports presence-definitions `LatestMetadata`: the revision and timestamp of a remote value.
public struct LatestMetadata {
  public let revision: Double
  public let timestamp: Double?
}

/// Ports `LatestData`.
public struct LatestData {
  public let value: ValueAccessor
  public let metadata: LatestMetadata
}

/// Ports `LatestClientData`.
public struct LatestClientData {
  public let attendee: any Attendee
  public let value: ValueAccessor
  public let metadata: LatestMetadata
}

/// Ports presence-definitions `LatestEvents`.
public enum LatestEvent {
  case remoteUpdated(LatestClientData)
  case localUpdated(value: JSONValue)
}

/// Ports `LatestValueManagerImpl` of presence-runtime/src/states/latestValueManager.ts.
public final class LatestValueManagerImpl: ValueManager {
  public let events = Emitter<LatestEvent>()
  public let controls: OptionalBroadcastControl
  private let key: JSString
  private let datastore: any StateDatastore
  private let value: ValueState
  private let validator: StateSchemaValidator?

  init(
    key: JSString, datastore: any StateDatastore, value: ValueState,
    controlSettings: BroadcastControlSettings?, validator: StateSchemaValidator?
  ) {
    self.key = key
    self.datastore = datastore
    self.value = value
    self.validator = validator
    controls = OptionalBroadcastControl(settings: controlSettings)
  }

  public var presence: any Presence {
    datastore.presence
  }

  public var local: JSONValue? {
    value.value
  }

  /// `local = value`: no equality check and no deep clone. Updates the local state, queues the
  /// broadcast, then emits `localUpdated`.
  public func setLocal(_ newValue: JSONValue) throws {
    value.rev += 1
    value.timestamp = datastore.clock.now()
    value.value = newValue
    try datastore.localUpdate(
      key, value: .state(value),
      options: LocalStateUpdateOptions(allowableUpdateLatencyMs: controls.allowableUpdateLatencyMs))

    try events.emit(.localUpdated(value: newValue))
  }

  /// Remote values of every known attendee except self (disconnected attendees included).
  public func getRemotes() throws -> [LatestClientData] {
    let allKnownStates = datastore.knownValues(key)
    var remotes: [LatestClientData] = []
    for (attendeeId, node) in allKnownStates.states.values.entries {
      if attendeeId != allKnownStates.selfAttendeeId {
        guard case .state(let clientState) = node else {
          throw PresenceError.failed("latest state \(attendeeId) is a directory")
        }
        remotes.append(
          LatestClientData(
            attendee: try datastore.presence.attendees.getAttendee(attendeeId),
            value: createValidatedGetter(clientState: clientState, validator: validator),
            metadata: LatestMetadata(revision: clientState.rev, timestamp: clientState.timestamp)))
      }
    }
    return remotes
  }

  public func getStateAttendees() throws -> [any Attendee] {
    let allKnownStates = datastore.knownValues(key)
    return try allKnownStates.states.values.entries
      .map(\.key)
      .filter { $0 != allKnownStates.selfAttendeeId }
      .map { try datastore.presence.attendees.getAttendee($0) }
  }

  /// Throws `No entry for attendee`. The metadata timestamp here is `Date.now()`, unlike
  /// `getRemotes` and events, which report the stored timestamp.
  public func getRemote(_ attendee: any Attendee) throws -> LatestData {
    let allKnownStates = datastore.knownValues(key)
    guard let node = allKnownStates.states.values[attendee.attendeeId] else {
      throw PresenceError.failed("No entry for attendee")
    }
    guard case .state(let clientState) = node else {
      throw PresenceError.failed("latest state \(attendee.attendeeId) is a directory")
    }
    return LatestData(
      value: createValidatedGetter(clientState: clientState, validator: validator),
      metadata: LatestMetadata(revision: clientState.rev, timestamp: datastore.clock.now()))
  }

  public func update(
    attendee: any Attendee, received: Double, value: ValueDirectoryOrState
  ) throws -> [PostUpdateAction] {
    guard case .state(let valueState) = value else {
      throw PresenceError.failed("latest manager received a directory")
    }
    let allKnownStates = datastore.knownValues(key)
    let attendeeId = attendee.attendeeId
    if let currentState = allKnownStates.states.values[attendeeId], currentState.rev >= valueState.rev {
      return []
    }
    datastore.update(key, clientId: attendeeId, value: value)
    return [
      { [events, validator] in
        try events.emit(
          .remoteUpdated(
            LatestClientData(
              attendee: attendee,
              value: createValidatedGetter(clientState: valueState, validator: validator),
              metadata: LatestMetadata(revision: valueState.rev, timestamp: valueState.timestamp))))
      }
    ]
  }
}

/// Ports the `latest` factory (a `LatestFactory` that creates `Latest` / `LatestRaw`): the initial
/// state, `{rev: 0, timestamp: Date.now(), value: shallowClone(local)}`, is captured once when the
/// factory is created and reused by every workspace that registers the factory.
public final class LatestFactory: ManagerFactory {
  private let value: ValueState
  private let settings: BroadcastControlSettings?
  private let validator: StateSchemaValidator?

  /// `local` is an object or `null`. Values are immutable here, so the TS shallow clone has no
  /// Swift equivalent to perform.
  public init(
    local: JSONValue, settings: BroadcastControlSettings? = nil,
    validator: StateSchemaValidator? = nil, clock: any PresenceClock
  ) {
    value = ValueState(rev: 0, timestamp: clock.now(), value: local)
    self.settings = settings
    self.validator = validator
  }

  public func instantiate(key: JSString, datastore: any StateDatastore) -> ManagerInstantiation {
    ManagerInstantiation(
      initialData: .init(
        value: .state(value), allowableUpdateLatencyMs: settings?.allowableUpdateLatencyMs),
      manager: LatestValueManagerImpl(
        key: key, datastore: datastore, value: value, controlSettings: settings,
        validator: validator))
  }

  public func isInstance(_ manager: any ValueManager) -> Bool {
    manager is LatestValueManagerImpl
  }
}
