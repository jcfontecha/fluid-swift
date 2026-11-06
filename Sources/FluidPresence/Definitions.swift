import FluidJS

/// FluidPresence ports three TS packages as one target: `@fluidframework/presence` (public facade),
/// `@fluid-internal/presence-definitions` (attendee, workspace and value-manager interfaces) and
/// `@fluid-internal/presence-runtime` (session mapping, replicated state, batching, notifications).
/// They are one feature with one wire protocol and no independent consumers in the Swift port, so
/// splitting them would only add targets that cannot be used apart. Each file's doc comment names
/// the TS file it ports.
///
/// Not ported: telemetry events (`PresenceInstantiated`, `JoinRequested`, `JoinResponse`,
/// `JoinResponseWhenAlone`), because the Swift port has no telemetry layer yet, and the
/// data-store-context `getPresenceFromDataStoreContext`. fluid-static `getPresence` is
/// `Container.withPresence` in `FluidContainerLoader`, which hosts presence as a container extension.

/// Ports presence-definitions/src/baseTypes.ts `ClientConnectionId`.
public typealias ClientConnectionId = JSString

/// Ports presence-definitions/src/presence.ts `AttendeeId`.
public typealias AttendeeId = JSString

/// Ports presence-definitions/src/types.ts `WorkspaceAddress`.
public typealias WorkspaceAddress = JSString

/// Ports presence-definitions/src/presence.ts `AttendeeStatus`.
public enum AttendeeStatus: String, Sendable {
  case connected = "Connected"
  case disconnected = "Disconnected"
}

/// Ports presence-definitions/src/presence.ts `Attendee`.
public protocol Attendee: AnyObject {
  var attendeeId: AttendeeId { get }

  /// Throws `Client has never been connected` until a connection is known.
  func getConnectionId() throws -> ClientConnectionId

  func getConnectionStatus() -> AttendeeStatus
}

/// Ports presence-definitions/src/presence.ts `AttendeesEvents`.
public enum AttendeesEvent {
  case attendeeConnected(any Attendee)
  case attendeeDisconnected(any Attendee)
}

/// Ports presence-definitions/src/presence.ts `PresenceEvents`.
public enum PresenceEvent {
  case workspaceActivated(WorkspaceAddress, InternalWorkspaceType)
}

/// The `type` argument of `workspaceActivated`: `"States" | "Notifications" | "Unknown"`.
public enum InternalWorkspaceType: String, Sendable {
  case states = "States"
  case notifications = "Notifications"
  case unknown = "Unknown"
}

/// Ports the `Presence["attendees"]` object of presence-definitions/src/presence.ts.
public protocol Attendees: AnyObject {
  var events: Emitter<AttendeesEvent> { get }

  /// A fresh deduplicated set of attendees, in attendee map insertion order.
  func getAttendees() -> [any Attendee]

  /// Looks up by attendee ID or connection ID. Throws `Attendee not found`.
  func getAttendee(_ clientId: JSString) throws -> any Attendee

  func getMyself() -> any Attendee
}

/// Ports presence-definitions/src/presence.ts `Presence` and `PresenceWithNotifications`.
public protocol Presence: AnyObject {
  var events: Emitter<PresenceEvent> { get }
  var attendees: any Attendees { get }
  var states: StatesAccess { get }
  var notifications: NotificationsAccess { get }
}

/// Assertion and misuse failures. The TS `assert(cond, 0x...)` calls become
/// `PresenceError.assertionFailed("0x...")`; plain `throw new Error(message)` becomes `.failed`.
public enum PresenceError: Error, Equatable, CustomStringConvertible {
  case assertionFailed(String)
  case failed(String)

  public var description: String {
    switch self {
    case .assertionFailed(let code): return "Assert failed (\(code))"
    case .failed(let message): return message
    }
  }
}

func assertPresence(_ condition: Bool, _ code: String) throws {
  guard condition else {
    throw PresenceError.assertionFailed(code)
  }
}
