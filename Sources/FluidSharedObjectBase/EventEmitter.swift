/// One event name of a DDS's Node `EventEmitter` (shared-object-base's `EventEmitterWithErrorHandling`
/// base): any number of listeners, called synchronously in registration order. As in Node's
/// `emit`, the listeners are those registered when the emit starts: one added during an emit runs
/// from the next emit on, and one removed during an emit still runs for that emit.
///
/// Listener errors cannot occur: listeners do not throw, so the TS error handling that closes the
/// DDS on a listener exception has nothing to catch here.
public final class EventEmitter<Payload> {
  private var listeners: [(token: Int, listener: (Payload) -> Void)] = []
  private var nextToken = 0

  public init() {}

  /// No listener is registered, so an emitter can skip building a payload.
  public var isEmpty: Bool { listeners.isEmpty }

  /// `on(event, listener)`. The token removes this listener with `off`.
  @discardableResult
  public func on(_ listener: @escaping (Payload) -> Void) -> Int {
    nextToken += 1
    listeners.append((nextToken, listener))
    return nextToken
  }

  /// `off(event, listener)`.
  public func off(_ token: Int) {
    listeners.removeAll { $0.token == token }
  }

  public func emit(_ payload: Payload) {
    for (_, listener) in listeners {
      listener(payload)
    }
  }
}
