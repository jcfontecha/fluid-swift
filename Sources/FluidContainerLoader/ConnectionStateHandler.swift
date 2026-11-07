import FluidDriverDefinitions
import FluidJS

/// Ports connectionStateHandler.ts: wait for the previous writer to leave, the new self to join,
/// and the handshake checkpoint to be processed before exposing Connected to the runtime.
public final class ConnectionStateHandler {
    public private(set) var connected = false
    public private(set) var clientId: JSString?
    public private(set) var waitingForLeave: JSString?
    private var pendingClientId: JSString?
    private var selfJoined = false
    private var checkpoint = 0
    private var sequenceNumber = 0
    private var mode = ConnectionMode.write

    public init() {}

    public func receivedConnectEvent(_ details: IConnected, sequenceNumber: Int, selfAlreadyJoined: Bool = false) {
        connected = false
        pendingClientId = details.clientId
        mode = details.mode
        selfJoined = selfAlreadyJoined || (details.mode == .read && details.initialClients.contains { $0.clientId == details.clientId })
        checkpoint = max(details.checkpointSequenceNumber ?? 0, details.initialMessages.map(\.sequenceNumber).max() ?? 0)
        self.sequenceNumber = sequenceNumber
        applyForConnectedState()
    }

    public func receivedDisconnectEvent(hasPendingOps: Bool, currentClientInQuorum: Bool) {
        if waitingForLeave == nil, hasPendingOps, currentClientInQuorum {
            waitingForLeave = clientId
        }
        connected = false
        pendingClientId = nil
    }

    public func receivedMessage(_ message: ISequencedDocumentMessage, hasPendingOps: Bool) throws {
        sequenceNumber = message.sequenceNumber
        if message.type == "join", mode == .write {
            if try IClientJoin(json: systemData(message)).clientId == pendingClientId { selfJoined = true }
        }
        if message.type == "leave", try systemData(message).asString() == waitingForLeave {
            waitingForLeave = nil
        }
        if !hasPendingOps { waitingForLeave = nil }
        applyForConnectedState()
    }

    public func receivedReadJoin(_ clientId: JSString) {
        if mode == .read, clientId == pendingClientId {
            selfJoined = true
            applyForConnectedState()
        }
    }

    public func leaveTimerExpired() {
        waitingForLeave = nil
        applyForConnectedState()
    }

    private func applyForConnectedState() {
        if pendingClientId != nil, selfJoined, waitingForLeave == nil, sequenceNumber >= checkpoint {
            connected = true
            clientId = pendingClientId
        }
    }
}
