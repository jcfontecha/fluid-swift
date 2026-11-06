import FluidContainerDefinitions
import FluidDatastoreDefinitions
import FluidDriverBase
import FluidDriverDefinitions
import FluidJS

/// Ports container-loader/src/deltaManager.ts: inbound queue, validation and storage gap ranges.
/// Storage fetching is performed by Container only after this synchronous queue has drained.
public final class DeltaManager: IDeltaManager {
    public struct Pending {
        public let message: ISequencedDocumentMessage
        public let source: String
    }
    public let events = ListenerList<DeltaManagerEvent>()
    public private(set) var pending: [Pending] = []
    public private(set) var log: [ISequencedDocumentMessage] = []
    public private(set) var opSources: [String] = []
    public var noopHeuristic = NoopHeuristic()
    private var clientSequences: [JSString: Int] = [:]
    private var lastClientSequence = 0
    private var noopCountInFlight = 0
    private var clientSequence = 0
    private var heuristicConfigured = false

    /// `lastProcessedSequenceNumber`: set to the snapshot's sequence number at load, then to each message
    /// before it is processed.
    public var lastSequenceNumber = 0
    public var minimumSequenceNumber = 0

    /// Connected in write mode and in the quorum (container.ts `activeConnection`).
    public var active: Bool { activeConnection() }

    /// The loader connects in write mode only, so it never reports read-only.
    public var readOnlyInfo: ReadOnlyInfo { ReadOnlyInfo(readonly: false) }

    private let activeConnection: () -> Bool

    public init(active: @escaping () -> Bool) {
        activeConnection = active
    }

    public func connect(_ details: IConnected, lastSequenceNumber: Int) {
        clientSequence = 0
        lastClientSequence = 0
        noopCountInFlight = 0
        // container.ts retains the first connection's heuristic settings across reconnects.
        if !heuristicConfigured {
            noopHeuristic.noopCountFrequency = details.serviceConfiguration.noopCountFrequency ?? 50
            noopHeuristic.noopTimeFrequency = details.serviceConfiguration.noopTimeFrequency ?? 2000
            heuristicConfigured = true
        }
        let checkpoint =
            ([details.checkpointSequenceNumber]
            + details.initialMessages.map { Optional($0.sequenceNumber) }).compactMap { $0 }.max()
        events.emit(.connect(details, opsBehind: checkpoint.map { $0 - lastSequenceNumber }))
    }

    public func disconnect(_ reason: String, error: (any Error)? = nil) {
        noopHeuristic.notifyDisconnect()
        events.emit(.disconnect(reason, error: error))
    }

    public func enqueueMessages(_ messages: [ISequencedDocumentMessage], source: String = "socket")
    {
        pending.append(contentsOf: messages.map { Pending(message: $0, source: source) })
        pending.sort { $0.message.sequenceNumber < $1.message.sequenceNumber }
    }

    /// deltaManager.ts compares only this fingerprint, not contents or transport-specific traces.
    public func nextMessage(sequenceNumber: Int) throws -> Pending? {
        while let entry = pending.first {
            let message = entry.message
            if message.sequenceNumber <= sequenceNumber {
                if let previous = log.last, message.sequenceNumber == sequenceNumber {
                    for key: JSString in [
                        "clientId", "type", "minimumSequenceNumber", "referenceSequenceNumber",
                        "timestamp",
                    ] {
                        guard try message.json.member(key) == previous.json.member(key) else {
                            throw DriverError(
                                "fileOverwrittenInStorage", message.json, canRetry: false)
                        }
                    }
                }
                pending.removeFirst()
                continue
            }
            guard message.sequenceNumber == sequenceNumber + 1 else { return nil }
            return pending.removeFirst()
        }
        return nil
    }

    /// deltaManager.ts validates remote CSNs monotonically, allowing legacy gaps. Own-client
    /// gaps are allowed only when explained by unsequenced noops coalesced by the service.
    public func validate(
        _ message: ISequencedDocumentMessage, protocolHandler: ProtocolOpHandler,
        clientId: JSString?
    ) throws {
        if message.type == "leave" {
            clientSequences[try systemData(message).asString()] = nil
        }
        if let sender = message.clientId {
            if let previous = clientSequences[sender], message.clientSequenceNumber <= previous {
                throw JSONDecodingError("DeltaManager.validateClientSequenceNumberConsistency")
            }
            clientSequences[sender] = message.clientSequenceNumber
            guard message.type == "join" || protocolHandler.quorum.getMember(sender) != nil
            else {
                throw JSONDecodingError("Remote message's clientId is missing from the quorum")
            }
        } else if ["op", "propose", "reject", "accept", "summarize"].contains(message.type) {
            throw JSONDecodingError("Mismatch in clientId")
        }
        if let clientId, message.clientId == clientId {
            if message.type == "noop" { noopCountInFlight -= 1 }
            let gap = message.clientSequenceNumber - lastClientSequence - 1
            noopCountInFlight -= gap
            guard noopCountInFlight >= 0 else {
                throw JSONDecodingError("gap in client sequence number: \(gap)")
            }
            lastClientSequence = message.clientSequenceNumber
        }
        guard message.minimumSequenceNumber >= protocolHandler.minimumSequenceNumber else {
            throw JSONDecodingError(
                "Invalid MinimumSequenceNumber from service - document may have been restored to previous state"
            )
        }
        guard
            message.minimumSequenceNumber < message.sequenceNumber
                || (message.minimumSequenceNumber == message.sequenceNumber
                    && message.clientId == nil)
        else {
            throw JSONDecodingError("MSN has to be lower than sequence #")
        }
        guard message.sequenceNumber == protocolHandler.sequenceNumber + 1 else {
            throw JSONDecodingError("Found a non-Sequential sequenceNumber")
        }
    }

    public func recordProcessed(_ entry: Pending, duration: Double = 0) {
        log.append(entry.message)
        opSources.append(entry.source)
        events.emit(.op(entry.message, duration: duration))
    }

    public func prepareMessage(type: String, contents: JSONValue?, referenceSequenceNumber: Int)
        throws -> IDocumentMessage
    {
        clientSequence += 1
        noopHeuristic.notifyMessageSent()
        if type == "noop" { noopCountInFlight += 1 }
        var message = JSObject<JSONValue>()
        message["contents"] = contents
        message["referenceSequenceNumber"] = .number(Double(referenceSequenceNumber))
        message["type"] = .string(JSString(type))
        message["clientSequenceNumber"] = .number(Double(clientSequence))
        return try IDocumentMessage(json: .object(message))
    }

    /// deltaManager.ts fetchMissingDeltasCore: refetch the prior op deliberately to detect an
    /// overwritten file (specs/container-loader/delta.md), up to the first queued op, exclusive, or
    /// to the end when nothing is queued. The driver splits the range into batches.
    public func fetchRange(sequenceNumber: Int) -> (from: Int, to: Int?) {
        (max(1, sequenceNumber), pending.first?.message.sequenceNumber)
    }
}
