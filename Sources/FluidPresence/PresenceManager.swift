import FluidJS

/// Ports presence-runtime/src/runtime/presenceManager.ts.

/// `StatesWorkspace` access: `presence.states.getWorkspace(address, schema, settings?)`. The
/// workspace address is prefixed `s:` internally.
public struct StatesAccess {
  fileprivate let datastoreManager: () -> any PresenceDatastoreManager

  public func getWorkspace(
    _ workspaceAddress: WorkspaceAddress, _ requestedContent: WorkspaceSchema,
    settings: BroadcastControlSettings? = nil
  ) throws -> PresenceStatesImpl {
    try datastoreManager().getWorkspace(
      JSString("s:") + workspaceAddress, requestedContent: requestedContent, controls: settings)
  }
}

/// `NotificationsWorkspace` access: `presence.notifications.getWorkspace(address, schema)`. The
/// workspace address is prefixed `n:` internally.
public struct NotificationsAccess {
  fileprivate let datastoreManager: () -> any PresenceDatastoreManager

  public func getWorkspace(_ workspaceAddress: WorkspaceAddress, _ requestedContent: WorkspaceSchema)
    throws -> PresenceStatesImpl
  {
    try datastoreManager().getWorkspace(
      JSString("n:") + workspaceAddress, requestedContent: requestedContent, controls: nil)
  }
}

extension JSString {
  /// String concatenation (`a + b`) over UTF-16 code units.
  static func + (lhs: JSString, rhs: JSString) -> JSString {
    JSString(utf16: lhs.utf16 + rhs.utf16)
  }
}

/// Ports `PresenceManager`: the outermost layer of the presence system, with two main
/// sub-components. `PresenceDatastoreManagerImpl` manages the unified general data for states and
/// the registry of workspaces. `SystemWorkspaceImpl` is a custom internal workspace for system
/// states, including attendee management, registered with the datastore manager.
public final class PresenceManager: Presence {
  private var joined = false

  // Both are set once in `init`, after `self` can be passed as the `Presence` they serve.
  private var datastoreManager: (any PresenceDatastoreManager)!
  private var systemWorkspace: (any SystemWorkspace)!

  public let events = Emitter<PresenceEvent>()
  private let attendeesEvents = Emitter<AttendeesEvent>()
  private let runtime: any IEphemeralRuntime

  public var attendees: any Attendees {
    systemWorkspace
  }

  public var states: StatesAccess {
    StatesAccess(datastoreManager: { [unowned self] in self.datastoreManager })
  }

  public var notifications: NotificationsAccess {
    NotificationsAccess(datastoreManager: { [unowned self] in self.datastoreManager })
  }

  public init(runtime: any IEphemeralRuntime, attendeeId: AttendeeId) throws {
    self.runtime = runtime

    let systemWorkspaceDatastore = SystemWorkspaceDatastore()
    let systemWorkspaceConfig = createSystemWorkspace(
      attendeeId: attendeeId,
      datastore: systemWorkspaceDatastore,
      events: attendeesEvents,
      audience: runtime.getAudience(),
      clock: runtime.clock)
    datastoreManager = PresenceDatastoreManagerImpl(
      attendeeId: attendeeId,
      runtime: runtime,
      events: events,
      presence: self,
      systemWorkspaceDatastore: systemWorkspaceDatastore,
      systemWorkspace: systemWorkspaceConfig.statesEntry)
    systemWorkspace = systemWorkspaceConfig.workspace

    runtime.onDisconnected { [unowned self] in
      try self.onDisconnected()
    }

    let audience = runtime.getAudience()
    // Listen for self add to the audience to indicate join (with a stable audience population).
    audience.onAddMember { [unowned self] clientConnectionId, _ in
      try self.addClientConnectionId(clientConnectionId)
    }
    audience.onRemoveMember { [unowned self] clientConnectionId in
      try self.systemWorkspace.removeClientConnectionId(clientConnectionId)
    }

    // Check if already connected (can send signals and complete audience) at the time of construction.
    if let clientId = runtime.getClientId(),
      runtime.getJoinedStatus() != .disconnected,
      audience.getMember(clientId) != nil
    {
      try onJoin(clientId, alternateUpdateProvider: nil)
    }
  }

  private func addClientConnectionId(_ clientConnectionId: ClientConnectionId) throws {
    // Check specifically for self join that indicates a stable audience and is the preferred
    // trigger for presence join.
    if clientConnectionId == runtime.getClientId() {
      try onJoin(clientConnectionId, alternateUpdateProvider: nil)
    }
  }

  private func onJoin(
    _ clientConnectionId: ClientConnectionId, alternateUpdateProvider: ClientConnectionId?
  ) throws {
    // The system workspace is notified even if already "joined", to handle the audience ->
    // attendee status updates. `audienceOutOfDate` is set when the join is forced by receiving a
    // signal (which calls with an alternateUpdateProvider).
    try systemWorkspace.onConnectionAdded(
      clientConnectionId, audienceOutOfDate: alternateUpdateProvider != nil)
    if !joined {
      try datastoreManager.joinSession(clientConnectionId, alternateProvider: alternateUpdateProvider)
      joined = true
    }
  }

  private func onDisconnected() throws {
    joined = false
    if let currentClientId = runtime.getClientId() {
      try systemWorkspace.removeClientConnectionId(currentClientId)
    }
    datastoreManager.onDisconnected()
  }

  /// Checks for a presence message and processes it. `addressChain` is the address chain of the
  /// message (`["?"]` marks an optional message), `local` whether it originated locally.
  public func processSignal(
    addressChain: [JSString], message: InboundExtensionMessage, local: Bool
  ) throws {
    // Confirms that the message is from a client rather than from the system, which specifies
    // `null` for clientId.
    try assertPresence(message.clientId != nil, "0xa3a")
    guard let clientId = message.clientId else {
      return
    }

    // Check for the undesired case of receiving a remote presence signal without having been
    // alerted to the self audience join that is the preferred trigger for join. Local signals are
    // commonly returned ahead of the audience join notification; one remote signal is enough to
    // get things rolling.
    if !local && !joined {
      let selfClientId = runtime.getClientId()
      try assertPresence(selfClientId != nil, "0xcbf")
      guard let selfClientId else {
        return
      }
      try onJoin(selfClientId, alternateUpdateProvider: clientId)
    }

    try datastoreManager.processSignal(
      message, clientId: clientId, local: local, optional: addressChain.first == "?")
  }
}

/// Ports `createPresenceManager`.
public func createPresenceManager(runtime: any IEphemeralRuntime, attendeeId: AttendeeId) throws
  -> PresenceManager
{
  try PresenceManager(runtime: runtime, attendeeId: attendeeId)
}
