import FluidDriverDefinitions
import FluidJS

/// Synchronous TypedEventEmitter subset. Listeners run inline on the owning container's executor.
public final class ListenerList<Event> {
    private var listeners: [(Int, (Event) -> Void)] = []
    private var nextID = 0

    public init() {}

    @discardableResult
    public func on(_ listener: @escaping (Event) -> Void) -> Int {
        nextID += 1
        listeners.append((nextID, listener))
        return nextID
    }

    public func off(_ id: Int) {
        listeners.removeAll { $0.0 == id }
    }

    public func emit(_ event: Event) {
        for (_, listener) in listeners { listener(event) }
    }
}

/// Ports audience.ts IAudienceEvents.
public enum AudienceEvent {
    case addMember(JSString, IClient)
    case removeMember(JSString, IClient)
    case selfChanged(old: ISelf?, new: ISelf)
}
