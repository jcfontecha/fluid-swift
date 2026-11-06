import FluidContainerRuntime
import FluidDatastore
import FluidMap
import FluidStatic
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
    private final class Outbound {
        var messages: [IDocumentMessage] = []
    }
    private let outbound = Outbound()
    private var runtime: ContainerRuntime?
    private var rootDataObject: RootDataObject?
    private let loadRuntime: Bool
    private let service: DocumentService
    private var protocolHandler: ProtocolOpHandler?
    private let deltaManager: DeltaManager
    private let connectionManager: ConnectionManager
    private let quorumEvents = ListenerList<QuorumEvent>()
    private let audienceEvents = ListenerList<AudienceEvent>()
    private var snapshotSequenceNumber = 0
    private var signals: [ISignalMessage] = []
    private var failure: String?
    private var reader: Task<Void, Never>?
    private var noopTimer: Task<Void, Never>?
    private var fetching = false

    public init(endpoint: String, document: String, loadRuntime: Bool = false) {
        self.loadRuntime = loadRuntime
        let connectionManager = ConnectionManager()
        self.connectionManager = connectionManager
        deltaManager = DeltaManager(active: { connectionManager.connected })
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
            let snapshot = try await service.storage.snapshot()
            let loaded = try ProtocolOpHandler(state: DocumentStorageService.protocolState(snapshot))
            deltaManager.lastSequenceNumber = loaded.sequenceNumber
            deltaManager.minimumSequenceNumber = loaded.minimumSequenceNumber
            if loadRuntime {
                let runtime = try ContainerRuntime(sessionId: UUID().uuidString.lowercased(), clientId: "",
                    deltaManager: deltaManager, quorum: QuorumClientsView(loaded.quorum.clients))
                try runtime.loadSnapshot(snapshot, factories: [
                    ChannelFactory(SharedMap.self, snapshotFormatVersion: "0.2"),
                    ChannelFactory(SharedDirectory.self, snapshotFormatVersion: "0.1"),
                ])
                runtime.referenceSequenceNumber = loaded.sequenceNumber
                rootDataObject = try RootDataObject(runtime: runtime)
                runtime.onSubmitBatch = { [deltaManager, outbound] messages in
                    var last = 0
                    for message in messages {
                        let prepared = try deltaManager.prepareMessage(
                            type: "op", contents: message.member("contents"),
                            referenceSequenceNumber: message.member("referenceSequenceNumber").asInt())
                        var fields = try prepared.json.asObject()
                        for (key, value) in try message.asObject().entries { fields[key] = value }
                        let wire = try IDocumentMessage(json: .object(fields))
                        outbound.messages.append(wire)
                        last = wire.clientSequenceNumber
                    }
                    return last
                }
                self.runtime = runtime
            }
            loaded.quorum.events.on { [quorumEvents] in quorumEvents.emit($0) }
            loaded.audience.events.on { [audienceEvents] in audienceEvents.emit($0) }
            snapshotSequenceNumber = loaded.sequenceNumber
            deltaManager.lastSequenceNumber = loaded.sequenceNumber
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
        while let entry = try deltaManager.nextMessage(
            sequenceNumber: protocolHandler.sequenceNumber)
        {
            let started = Date().timeIntervalSince1970
            let message = entry.message
            try deltaManager.validate(
                message, protocolHandler: protocolHandler, clientId: connectionManager.clientId)
            deltaManager.lastSequenceNumber = message.sequenceNumber
            deltaManager.minimumSequenceNumber = message.minimumSequenceNumber
            let result = try protocolHandler.processMessage(message)
            let wasConnected = connectionManager.connected
            try connectionManager.receivedJoin(message)
            try runtime?.recordSummaryMessage(message.json)
            if message.type == "op" { _ = try runtime?.process(message.json) }
            runtime?.referenceSequenceNumber = message.sequenceNumber
            if !wasConnected && connectionManager.connected, let id = connectionManager.clientId {
                try runtime?.reconnect(clientId: id.description)
            }
            if connectionManager.connected {
                if result.immediateNoOp == true {
                    outbound.messages.append(
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
            outbound.messages.append(
                try deltaManager.prepareMessage(
                    type: "noop", contents: nil,
                    referenceSequenceNumber: protocolHandler.sequenceNumber))
        }
        let messages = outbound.messages
        outbound.messages.removeAll(keepingCapacity: true)
        return messages
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
        if let runtime {
            var state = JSObject<JSONValue>()
            state["referenceSequenceNumber"] = .number(Double(runtime.referenceSequenceNumber))
            state["pendingMessages"] = .number(Double(runtime.pendingStateManager.pendingMessagesCount))
            state["datastores"] = .array(try runtime.channelCollection.datastoreIds.map { id in
                let store = try runtime.channelCollection.getDatastore(id)
                var entry = JSObject<JSONValue>()
                entry["id"] = .string(id)
                entry["channels"] = .array(store.contexts.keys.sorted { $0.description < $1.description }.map(JSONValue.string))
                entry["pendingOps"] = .number(Double(store.pendingOpCount))
                return .object(entry)
            })
            view["runtime"] = .object(state)
        }
        view["connected"] = .bool(connectionManager.connected)
        return .object(view)
    }

    /// Opens an existing fluid-static container. All object edits stay on this actor.
    public static func open(endpoint: String, document: String) async throws -> Container {
        let container = Container(endpoint: endpoint, document: document, loadRuntime: true)
        try await container.connect()
        return container
    }

    public func mapEntries(_ name: JSString = "map") throws -> JSONValue {
        if let failure { throw JSONDecodingError(failure) }
        guard let map = rootDataObject?.initialObjects[name] as? SharedMap else {
            throw JSONDecodingError("initialObject is not a SharedMap")
        }
        var values = JSObject<JSONValue>()
        for (key, value) in map.entries() { values[key] = value ?? .null }
        return .object(values)
    }

    public func withMap<Result: Sendable>(
        _ name: JSString = "map", _ edit: @Sendable (SharedMap) throws -> Result
    ) async throws -> Result {
        if let failure { throw JSONDecodingError(failure) }
        guard let map = rootDataObject?.initialObjects[name] as? SharedMap, let runtime else {
            throw JSONDecodingError("initialObject is not a SharedMap")
        }
        let result = try edit(map)
        try runtime.flush()
        let messages = outbound.messages
        outbound.messages.removeAll(keepingCapacity: true)
        try await sendMessages(messages)
        return result
    }

    public func disconnect() async {
        runtime?.connected = false
        if let runtime {
            for id in runtime.channelCollection.datastoreIds {
                do { try runtime.channelCollection.getDatastore(id).setConnectionState(false, clientId: nil) }
                catch { failure = String(describing: error) }
            }
        }
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
