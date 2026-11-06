/// Ports the semantics of client-utils `createEmitter` (events/emitter.ts) for one event enum:
/// listeners run synchronously in registration order; emit iterates a snapshot and skips any
/// listener removed by an earlier listener. A listener's exception propagates to the caller of
/// `emit`, as in TS, so listeners and `emit` throw.
public final class Emitter<Event> {
  private final class Registration {
    let listener: (Event) throws -> Void

    init(_ listener: @escaping (Event) throws -> Void) {
      self.listener = listener
    }
  }

  private var registrations: [Registration] = []

  public init() {}

  public var hasListeners: Bool {
    !registrations.isEmpty
  }

  /// Returns the function that removes the listener.
  @discardableResult
  public func on(_ listener: @escaping (Event) throws -> Void) -> () -> Void {
    let registration = Registration(listener)
    registrations.append(registration)
    return { [weak self] in
      self?.registrations.removeAll { $0 === registration }
    }
  }

  public func emit(_ event: Event) throws {
    let snapshot = registrations
    for registration in snapshot {
      if registrations.contains(where: { $0 === registration }) {
        try registration.listener(event)
      }
    }
  }
}
