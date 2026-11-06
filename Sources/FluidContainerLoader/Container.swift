import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import FluidRouterliciousDriver
import FluidSocketIO
import FluidTinyliciousDriver
import Foundation

/// Ports container-loader/src/container.ts. One actor owns all synchronous protocol, delta,
/// connection and listener state. Suspension occurs only at socket/REST/timer boundaries.
public actor Container {
    private let service: DocumentService
    private var protocolHandler: ProtocolOpHandler?
    private let deltaManager = DeltaManager()
    private let connectionManager = ConnectionManager()
    private let quorumEvents = ListenerList<QuorumEvent>()
    private let audienceEvents = ListenerList<AudienceEvent>()
    private var snapshotSequenceNumber = 0
    private var signals: [ISignalMessage] = []
    private var failure: String?
    private var reader: Task<Void, Never>?
    private var noopTimer: Task<Void, Never>?
    private var fetching = false

    public init(endpoint: String, document: String) {
        service = DocumentService(
            endpoint: endpoint, document: document, tokens: InsecureTinyliciousTokenProvider())
    }

    public func onDelta(_ listener: @escaping @Sendable (DeltaManagerEvent) -> Void) {
        deltaManager.events.on(listener)
    }

    public func onQuorum(_ listener: @escaping @Sendable (QuorumEvent) -> Void) {
        quorumEvents.on(listener)
    }

    public func onAudience(_ listener: @escaping @Sendable (AudienceEvent) -> Void) {
        audienceEvents.on(listener)
    }

    public func connect() async throws {
        if protocolHandler == nil {
            let loaded = try ProtocolOpHandler(state: await service.storage.protocolSnapshot())
            loaded.quorum.events.on { [quorumEvents] in quorumEvents.emit($0) }
            loaded.audience.events.on { [audienceEvents] in audienceEvents.emit($0) }
            snapshotSequenceNumber = loaded.sequenceNumber
            protocolHandler = loaded
        }
        let details = try await connectionManager.connect(service)
        deltaManager.connect(
            details, lastSequenceNumber: protocolHandler?.sequenceNumber ?? snapshotSequenceNumber)
        try protocolHandler?.initialClients(details.initialClients)
        deltaManager.enqueueMessages(details.initialMessages)
        for signal in details.initialSignals { try processSignal(signal) }
        guard let connection = connectionManager.connection else {
            throw JSONDecodingError("disconnected")
        }
        reader = Task {
            do {
                for try await event in connection.events { try await self.receive(event) }
            } catch {
                if !Task.isCancelled {
                    self.failure = String(describing: error)
                    self.connectionManager.connectionFailed()
                    self.deltaManager.disconnect(String(describing: error), error: error)
                }
            }
        }
        try await catchUp(fetchUnbounded: true)
    }

    private func receive(_ event: SocketEvent) async throws {
        switch event.name {
        case "op":
            guard event.arguments.count == 2 else {
                throw JSONDecodingError("invalid op arguments")
            }
            deltaManager.enqueueMessages(
                try event.arguments[1].asArray().map { try ISequencedDocumentMessage(json: $0) })
            try await catchUp()
        case "signal":
            guard let value = event.arguments.first else {
                throw JSONDecodingError("missing signal")
            }
            let batch: [JSONValue]
            if case .array(let values) = value { batch = values } else { batch = [value] }
            for value in batch { try processSignal(ISignalMessage(json: value)) }
        case "nack": throw DriverError("nack", .array(event.arguments))
        default: break
        }
    }

    private func processSignal(_ signal: ISignalMessage) throws {
        signals.append(signal)
        try protocolHandler?.processSignal(signal)
    }

    private func drain() throws -> [IDocumentMessage] {
        guard let protocolHandler else { throw JSONDecodingError("no protocol state") }
        var outgoing: [IDocumentMessage] = []
        while let entry = try deltaManager.nextMessage(
            sequenceNumber: protocolHandler.sequenceNumber)
        {
            let started = Date().timeIntervalSince1970
            let message = entry.message
            try deltaManager.validate(
                message, protocolHandler: protocolHandler, clientId: connectionManager.clientId)
            let result = try protocolHandler.processMessage(message)
            try connectionManager.receivedJoin(message)
            if connectionManager.connected {
                if result.immediateNoOp == true {
                    outgoing.append(
                        try deltaManager.prepareMessage(
                            type: "accept", contents: nil,
                            referenceSequenceNumber: protocolHandler.sequenceNumber))
                }
                deltaManager.noopHeuristic.notifyMessageProcessed(message)
                if message.type == "op" && deltaManager.noopHeuristic.opsProcessedSinceOpSent == 1 {
                    restartNoopTimer()
                }
            }
            deltaManager.recordProcessed(
                entry, duration: (Date().timeIntervalSince1970 - started) * 1000)
        }
        if connectionManager.connected && deltaManager.noopHeuristic.takeWantsNoop() {
            outgoing.append(
                try deltaManager.prepareMessage(
                    type: "noop", contents: nil,
                    referenceSequenceNumber: protocolHandler.sequenceNumber))
        }
        return outgoing
    }
    private func catchUp(fetchUnbounded: Bool = false) async throws {
        try await sendMessages(drain())
        if !fetching && (fetchUnbounded || !deltaManager.pending.isEmpty) {
            fetching = true
            defer { fetching = false }
            var unbounded = fetchUnbounded
            while let current = protocolHandler, unbounded || !deltaManager.pending.isEmpty {
                let previousSequenceNumber = current.sequenceNumber
                // Refetch the prior op deliberately: DeltaManager detects a replaced file by its
                // sender/type/MSN/reference/timestamp fingerprint, not by comparing contents.
                let (from, to) = deltaManager.fetchRange(sequenceNumber: current.sequenceNumber)
                let messages = try await service.deltaStorage.fetchMessages(
                    from: from, to: to, reason: unbounded ? "DocumentOpen" : "Gap")
                deltaManager.enqueueMessages(messages, source: "storage")
                try await sendMessages(drain())
                let last = messages.last?.sequenceNumber ?? 0
                unbounded = unbounded && last == to - 1
                if let next = deltaManager.pending.first, let updated = protocolHandler,
                    next.message.sequenceNumber > updated.sequenceNumber + 1,
                    updated.sequenceNumber == previousSequenceNumber
                {
                    throw JSONDecodingError("delta storage did not fill the sequence gap")
                }
            }
        }
    }

    /// noopHeuristic.ts restarts its timer whenever debt becomes one, even when an older timer
    /// still exists. Merely retaining that timer can acknowledge a new batch prematurely.
    private func restartNoopTimer() {
        noopTimer?.cancel()
        let delay = deltaManager.noopHeuristic.noopTimeFrequency
        guard delay.isFinite else {
            noopTimer = nil
            return
        }
        noopTimer = Task {
            do {
                try await Task.sleep(for: .milliseconds(delay))
                try await self.timerFired()
            } catch is CancellationError {} catch { self.failure = String(describing: error) }
        }
    }

    private func sendMessages(_ messages: [IDocumentMessage]) async throws {
        guard !messages.isEmpty else { return }
        guard let connection = connectionManager.connection else {
            throw JSONDecodingError("disconnected")
        }
        for message in messages { try await connection.submit([message]) }
    }

    private func timerFired() async throws {
        noopTimer = nil
        if connectionManager.connected && deltaManager.noopHeuristic.opsProcessedSinceOpSent > 0 {
            try await submit(type: "noop")
        }
    }

    public func submit(type: String, contents: JSONValue? = nil) async throws {
        guard connectionManager.connected, let connection = connectionManager.connection,
            let protocolHandler
        else { throw JSONDecodingError("not connected to own join") }
        let message = try deltaManager.prepareMessage(
            type: type, contents: contents, referenceSequenceNumber: protocolHandler.sequenceNumber)
        try await connection.submit([message])
    }

    public func signal(_ text: String) async throws {
        guard let connection = connectionManager.connection else {
            throw JSONDecodingError("disconnected")
        }
        try await connection.submitSignal(text)
    }

    public func view() throws -> JSONValue {
        if let failure { throw JSONDecodingError(failure) }
        guard let protocolHandler else { throw JSONDecodingError("unloaded") }
        var view = try protocolHandler.view.asObject()
        view["snapshotSequenceNumber"] = .number(Double(snapshotSequenceNumber))
        view["ops"] = .array(deltaManager.log.map(\.json))
        view["opSources"] = .array(deltaManager.opSources.map { .string(JSString($0)) })
        view["signals"] = .array(signals.map(\.json))
        view["clientId"] = connectionManager.clientId.map { .string($0) } ?? .null
        view["connected"] = .bool(connectionManager.connected)
        return .object(view)
    }

    public func disconnect() async {
        let hadConnection = connectionManager.connection != nil
        connectionManager.connectionFailed()
        if hadConnection { deltaManager.disconnect("Client disconnect") }
        noopTimer?.cancel()
        noopTimer = nil
        reader?.cancel()
        reader = nil
        await connectionManager.disconnect()
    }
}
