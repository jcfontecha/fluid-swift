import FluidJS

/// Ports presence-definitions `NotificationsManagerEvents`.
public enum NotificationsManagerEvent {
  /// A notification no named listener was registered for: `(name, sender, ...content)`.
  case unattendedNotification(name: JSString, sender: any Attendee, content: [JSONValue])
}

/// A named notification listener: `(attendee, ...args)`.
public typealias NotificationListener = (_ sender: any Attendee, _ args: [JSONValue]) throws -> Void

/// Ports `NotificationListenable`: named listeners with the semantics of `createEmitter`.
public final class NotificationListenable {
  private final class Registration {
    let listener: NotificationListener

    init(_ listener: @escaping NotificationListener) {
      self.listener = listener
    }
  }

  private var registrations: [JSString: [Registration]] = [:]

  init() {}

  /// Returns the function that removes the listener.
  @discardableResult
  public func on(_ name: JSString, _ listener: @escaping NotificationListener) -> () -> Void {
    let registration = Registration(listener)
    registrations[name, default: []].append(registration)
    return { [weak self] in
      self?.off(name, registration)
    }
  }

  private func off(_ name: JSString, _ registration: Registration) {
    registrations[name]?.removeAll { $0 === registration }
    if registrations[name]?.isEmpty == true {
      registrations[name] = nil
    }
  }

  func hasListeners(_ name: JSString) -> Bool {
    registrations[name] != nil
  }

  func emit(_ name: JSString, _ sender: any Attendee, _ args: [JSONValue]) throws {
    guard let snapshot = registrations[name] else {
      return
    }
    for registration in snapshot {
      if registrations[name]?.contains(where: { $0 === registration }) == true {
        try registration.listener(sender, args)
      }
    }
  }
}

/// Ports `NotificationEmitter`: `broadcast` and `unicast`. Both build the same wire entry
/// (`rev: 0, timestamp: 0, value: {name, args}, ignoreUnmonitored: true`) and ask for immediate
/// sending. `unicast` passes the target connection ID as an option, which the queue layer does not
/// forward: in this snapshot a "unicast" notification is broadcast.
public final class NotificationEmitter {
  private let key: JSString
  private let datastore: any StateDatastore

  init(key: JSString, datastore: any StateDatastore) {
    self.key = key
    self.datastore = datastore
  }

  private func notification(_ name: JSString, _ args: [JSONValue]) -> ValueDirectoryOrState {
    var value = JSObject<JSONValue>()
    value["name"] = .string(name)
    value["args"] = .array(args)
    return .state(
      ValueState(rev: 0, timestamp: 0, value: .object(value), ignoreUnmonitored: .bool(true)))
  }

  public func broadcast(_ name: JSString, _ args: [JSONValue] = []) throws {
    // This is a notification, so we want to send it immediately.
    try datastore.localUpdate(
      key, value: notification(name, args), options: LocalStateUpdateOptions(allowableUpdateLatencyMs: 0))
  }

  /// Throws `Client has never been connected` if the target has no connection ID.
  public func unicast(_ name: JSString, _ targetAttendee: any Attendee, _ args: [JSONValue] = []) throws {
    let targetClientId = try targetAttendee.getConnectionId()
    try datastore.localUpdate(
      key, value: notification(name, args),
      options: LocalStateUpdateOptions(allowableUpdateLatencyMs: 0, targetClientId: targetClientId))
  }
}

/// Ports `NotificationsManagerImpl` of presence-runtime/src/states/notificationsManager.ts.
public final class NotificationsManagerImpl: ValueManager {
  public let events = Emitter<NotificationsManagerEvent>()
  public let notifications = NotificationListenable()
  public let emit: NotificationEmitter

  init(
    key: JSString, datastore: any StateDatastore,
    initialSubscriptions: [(name: JSString, listener: NotificationListener)]
  ) {
    emit = NotificationEmitter(key: key, datastore: datastore)
    self.datastore = datastore
    // Add event listeners provided at instantiation.
    for subscription in initialSubscriptions {
      notifications.on(subscription.name, subscription.listener)
    }
  }

  private let datastore: any StateDatastore

  public var presence: any Presence {
    datastore.presence
  }

  /// A received notification always queues the named listener `(attendee, ...args)` if one
  /// exists, otherwise `unattendedNotification`. There is no revision deduplication.
  public func update(
    attendee: any Attendee, received: Double, value updateValue: ValueDirectoryOrState
  ) throws -> [PostUpdateAction] {
    guard case .state(let state) = updateValue, let notification = state.value else {
      throw PresenceError.failed("notification manager received a non-notification value")
    }
    let eventName = try notification.member("name").asString()
    let args = try notification.member("args").asArray()
    if notifications.hasListeners(eventName) {
      return [
        { [notifications] in
          try notifications.emit(eventName, attendee, args)
        }
      ]
    }
    return [
      { [events] in
        try events.emit(.unattendedNotification(name: eventName, sender: attendee, content: args))
      }
    ]
  }
}

/// Ports the `Notifications(initialSubscriptions)` factory. It has no initial data.
public final class NotificationsFactory: ManagerFactory {
  private let initialSubscriptions: [(name: JSString, listener: NotificationListener)]

  public init(initialSubscriptions: [(name: JSString, listener: NotificationListener)]) {
    self.initialSubscriptions = initialSubscriptions
  }

  public func instantiate(key: JSString, datastore: any StateDatastore) -> ManagerInstantiation {
    ManagerInstantiation(
      initialData: nil,
      manager: NotificationsManagerImpl(
        key: key, datastore: datastore, initialSubscriptions: initialSubscriptions))
  }

  public func isInstance(_ manager: any ValueManager) -> Bool {
    manager is NotificationsManagerImpl
  }
}
