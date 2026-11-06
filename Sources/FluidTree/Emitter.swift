/// @fluid-internal/client-utils events/emitter.ts: the listeners of one event name.
/// Listeners run synchronously in registration order. `emit` iterates a snapshot, so listeners
/// added during an emit miss it, and skips any listener removed by an earlier listener. A
/// listener's error propagates to the caller of `emit`, as in TS.
/// (FluidPresence carries the same port; FluidTree cannot depend on that target.)
public final class Emitter<Event> {
    private final class Registration {
        let listener: (Event) throws -> Void

        init(_ listener: @escaping (Event) throws -> Void) {
            self.listener = listener
        }
    }

    private var registrations: [Registration] = []

    public init() {}

    /// Registers a listener and returns the function that removes it.
    @discardableResult
    public func on(_ listener: @escaping (Event) throws -> Void) -> () -> Void {
        let registration = Registration(listener)
        registrations.append(registration)
        return { [weak self] in
            self?.registrations.removeAll { $0 === registration }
        }
    }

    func emit(_ event: Event) throws {
        let snapshot = registrations
        for registration in snapshot {
            if registrations.contains(where: { $0 === registration }) {
                try registration.listener(event)
            }
        }
    }
}
