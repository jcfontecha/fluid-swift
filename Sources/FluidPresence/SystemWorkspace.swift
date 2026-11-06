import FluidJS

/// Ports `SessionClient` of presence-runtime/src/runtime/systemWorkspace.ts.
final class SessionClient: Attendee {
  private var connectionStatus: AttendeeStatus = .disconnected
  let attendeeId: AttendeeId

  /// Used to track the most recent client connection during a session.
  var order: Double

  var connectionId: ClientConnectionId?

  init(attendeeId: AttendeeId, order: Double = 0, connectionId: ClientConnectionId? = nil) {
    self.attendeeId = attendeeId
    self.order = order
    self.connectionId = connectionId
  }

  func getConnectionId() throws -> ClientConnectionId {
    guard let connectionId else {
      throw PresenceError.failed("Client has never been connected")
    }
    return connectionId
  }

  func getConnectionStatus() -> AttendeeStatus {
    connectionStatus
  }

  func setConnected() {
    connectionStatus = .connected
  }

  func setDisconnected() {
    connectionStatus = .disconnected
  }
}

/// Ports the `SystemWorkspace` interface: the attendee portion of `Presence`, plus the two calls
/// the presence manager makes on connection changes.
protocol SystemWorkspace: Attendees {
  /// Must be called when the current client acquires a new connection. When `audienceOutOfDate`,
  /// the audience cannot be used as authoritative.
  func onConnectionAdded(_ clientConnectionId: ClientConnectionId, audienceOutOfDate: Bool) throws

  func removeClientConnectionId(_ clientConnectionId: ClientConnectionId) throws
}

/// Ports `SystemWorkspaceImpl`: internal workspace that manages metadata for session attendees.
final class SystemWorkspaceImpl: PresenceStatesInternal, SystemWorkspace {
  private let selfAttendee: SessionClient

  /// This client's understanding of the attendees in the session. The map covers entries for both
  /// session IDs and connection IDs, which are never expected to collide.
  private var attendees = JSMap<JSString, SessionClient>()

  /// When the local client disconnects it loses connectivity updates for remote attendees. On
  /// reconnect all of them are marked stale and become disconnected after 30 seconds of silence.
  private var staleConnectionClients: [SessionClient] = []

  private let staleConnectionTimer: TimerManager
  private let datastore: SystemWorkspaceDatastore
  let events: Emitter<AttendeesEvent>
  private let audience: any IAudience
  private let clock: any PresenceClock

  init(
    attendeeId: AttendeeId,
    datastore: SystemWorkspaceDatastore,
    events: Emitter<AttendeesEvent>,
    audience: any IAudience,
    clock: any PresenceClock
  ) {
    self.datastore = datastore
    self.events = events
    self.audience = audience
    self.clock = clock
    staleConnectionTimer = TimerManager(clock: clock)
    selfAttendee = SessionClient(attendeeId: attendeeId)
    attendees.set(attendeeId, selfAttendee)
  }

  func ensureContent(_ content: WorkspaceSchema, controls: BroadcastControlSettings?) throws
    -> PresenceStatesImpl
  {
    throw PresenceError.failed("Method not implemented.")
  }

  /// `remoteDatastore` is `{clientToSessionId: {[connectionId]: {rev, timestamp, value}}}`.
  func processUpdate(
    received: Double, timeModifier: Double, remoteDatastore: JSONValue,
    senderConnectionId: ClientConnectionId
  ) throws -> [PostUpdateAction] {
    let audienceMembers = audience.getMembers()
    var postUpdateActions: [PostUpdateAction] = []
    let mappings = try remoteDatastore.member("clientToSessionId").asObject()
    for (clientConnectionId, mappingJSON) in mappings.entries {
      let value = try ConnectionValueState(json: mappingJSON)
      let attendeeId = value.value
      let (attendee, isJoining) = ensureAttendee(
        attendeeId: attendeeId,
        clientConnectionId: clientConnectionId,
        order: value.rev,
        isSender: senderConnectionId == clientConnectionId,
        isInAudience: audienceMembers.has(clientConnectionId))
      // If the attendee is joining the session, announce it after all workspaces are updated.
      if isJoining {
        postUpdateActions.append { [events] in
          try events.emit(.attendeeConnected(attendee))
        }
      }

      if let knownSessionId = datastore.clientToSessionId[clientConnectionId] {
        try assertPresence(knownSessionId.value == value.value, "0xa5a")
      } else {
        datastore.clientToSessionId[clientConnectionId] = value
      }
    }
    return postUpdateActions
  }

  func onConnectionAdded(_ clientConnectionId: ClientConnectionId, audienceOutOfDate: Bool) throws {
    try assertPresence(selfAttendee.getConnectionStatus() == .disconnected, "0xaad")

    let selfInAudience = audience.getMember(clientConnectionId) != nil
    try assertPresence(selfInAudience || audienceOutOfDate, "0xcc0")

    if datastore.clientToSessionId[clientConnectionId] == nil {
      datastore.clientToSessionId[clientConnectionId] = ConnectionValueState(
        rev: selfAttendee.order,
        timestamp: clock.now(),
        value: selfAttendee.attendeeId)
      selfAttendee.order += 1
    }

    // Update the self attendee connection information, but not connection status yet. Status is
    // updated once self is in the audience, which is when the audience can be used to track other
    // attendees' connection statuses.
    selfAttendee.connectionId = clientConnectionId
    attendees.set(clientConnectionId, selfAttendee)

    if selfInAudience {
      // Mark 'Connected' remote attendees' connections as stale. The attendee map has attendee ID
      // and connection ID entries that point at the same attendee; duplicates are ignored.
      staleConnectionClients.removeAll()
      for (_, staleConnectionClient) in attendees.entries {
        if staleConnectionClient.getConnectionStatus() == .connected {
          addStale(staleConnectionClient)
        }
      }

      staleConnectionTimer.setTimeout(
        { [unowned self] in try self.resolveStaleConnections() }, delay: 30_000)

      selfAttendee.setConnected()
      try events.emit(.attendeeConnected(selfAttendee))
    }
  }

  private func addStale(_ client: SessionClient) {
    if !staleConnectionClients.contains(where: { $0 === client }) {
      staleConnectionClients.append(client)
    }
  }

  private func resolveStaleConnections() throws {
    var consideredDisconnected: [SessionClient] = []
    for client in staleConnectionClients {
      // Confirm that the audience no longer has the connection. It is possible but unlikely that
      // no one mentioned the attendee in this period and that they were never disconnected.
      if try audience.getMember(client.getConnectionId()) == nil {
        consideredDisconnected.append(client)
        client.setDisconnected()
      }
    }
    for client in consideredDisconnected {
      try events.emit(.attendeeDisconnected(client))
    }
    staleConnectionClients.removeAll()
  }

  func removeClientConnectionId(_ clientConnectionId: ClientConnectionId) throws {
    guard let attendee = attendees.get(clientConnectionId) else {
      return
    }

    // If the local connection is being removed, clear the stale connection timer.
    if attendee === selfAttendee {
      staleConnectionTimer.clearTimeout()
    } else if selfAttendee.getConnectionStatus() != .connected {
      // When self is not connected, the audience may go through a refresh that removes members
      // and adds them back. Defer any removals until self is connected.
      return
    }

    // If the last known connection ID differs from the one being removed, the attendee has
    // reconnected: no status change and no disconnect event.
    let attendeeReconnected = try attendee.getConnectionId() != clientConnectionId
    let connected = attendee.getConnectionStatus() == .connected
    if !attendeeReconnected && connected {
      attendee.setDisconnected()
      try events.emit(.attendeeDisconnected(attendee))
      staleConnectionClients.removeAll { $0 === attendee }
    }
  }

  func getAttendees() -> [any Attendee] {
    var seen: [ObjectIdentifier] = []
    var result: [any Attendee] = []
    for (_, attendee) in attendees.entries {
      let identifier = ObjectIdentifier(attendee)
      if !seen.contains(identifier) {
        seen.append(identifier)
        result.append(attendee)
      }
    }
    return result
  }

  func getAttendee(_ clientId: JSString) throws -> any Attendee {
    if let attendee = attendees.get(clientId) {
      return attendee
    }
    // There are no resiliency mechanisms for a missed ClientJoin.
    throw PresenceError.failed("Attendee not found")
  }

  func getMyself() -> any Attendee {
    selfAttendee
  }

  /// Makes sure the given client session and connection ID pair are represented in the attendee
  /// map, creating the `SessionClient` or updating its current connection ID.
  private func ensureAttendee(
    attendeeId: AttendeeId,
    clientConnectionId: ClientConnectionId,
    order: Double,
    isSender: Bool,
    isInAudience: Bool
  ) -> (attendee: SessionClient, isJoining: Bool) {
    var isConnected = false
    var isJoining = false
    let attendee: SessionClient

    if let known = attendees.get(attendeeId) {
      attendee = known
      // A known attendee is considered connected if this information is at least up to date with
      // current knowledge AND the attendee is in the audience, OR is not in the audience but is
      // the sender with newer information (assume the audience is out of date).
      isConnected = order >= attendee.order && (isInAudience || (isSender && order > attendee.order))

      if order > attendee.order {
        // The given association is newer than the one we have.
        attendee.order = order
        attendee.connectionId = clientConnectionId
      }

      // A known attendee is joining the session if they are currently disconnected.
      if isConnected && attendee.getConnectionStatus() == .disconnected {
        attendee.setConnected()
        isJoining = true
      }
    } else {
      // New attendee: create the `SessionClient` with an attendee-ID-based entry.
      attendee = SessionClient(
        attendeeId: attendeeId, order: order, connectionId: clientConnectionId)
      attendees.set(attendeeId, attendee)
      // If the update is from the sending remote client itself OR the attendee is in the
      // audience, the attendee is connected. Otherwise it stays disconnected (the default).
      if isSender || isInAudience {
        isConnected = true
        attendee.setConnected()
        isJoining = true
      }
    }

    if isConnected {
      staleConnectionClients.removeAll { $0 === attendee }
    }

    // Always update the entry for the connection ID. (Okay if already set.)
    attendees.set(clientConnectionId, attendee)

    return (attendee, isJoining)
  }
}

/// Ports `createSystemWorkspace`.
func createSystemWorkspace(
  attendeeId: AttendeeId,
  datastore: SystemWorkspaceDatastore,
  events: Emitter<AttendeesEvent>,
  audience: any IAudience,
  clock: any PresenceClock
) -> (workspace: any SystemWorkspace, statesEntry: AnyWorkspaceEntry) {
  let workspace = SystemWorkspaceImpl(
    attendeeId: attendeeId, datastore: datastore, events: events, audience: audience, clock: clock)
  return (workspace, AnyWorkspaceEntry(publicWorkspace: nil, internal: workspace))
}
