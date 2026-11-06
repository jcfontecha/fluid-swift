import FluidDriverDefinitions
import FluidJS

/// Synchronous TypedEventEmitter subset. Listeners run inline on Container's executor.
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

public enum QuorumEvent {
    case addMember(JSString, ISequencedClient)
    case removeMember(JSString)
    case addProposal(ISequencedProposal)
    case approveProposal(ICommittedProposal)
}

public enum AudienceEvent {
    case addMember(JSString, IClient)
    case removeMember(JSString, IClient)
}

public enum DeltaManagerEvent {
    case op(ISequencedDocumentMessage, duration: Double)
    case connect(IConnected, opsBehind: Int?)
    case disconnect(String, error: (any Error)?)
}
