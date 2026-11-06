import FluidContainerRuntime
import FluidDatastore
import FluidMap
import FluidPresence
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
        var signals: [(content: String, target: String?)] = []
    }
    /// Presence is a container extension (containerRuntime.ts `acquireExtension`). These live on
    /// this actor's executor; closures capture the holder so they never capture the actor.
    private final class PresenceState {
        var manager: ContainerPresenceManager?
        var host: ContainerExtensionHost?
        var clock: ContainerPresenceClock?
        var failure: (any Error)?
    }
    private let presence = PresenceState()
    /// container.ts `signalAudience`: every client the service reports through join/leave/clear
    /// signals, read and write, unlike `ProtocolOpHandler.audience`, which writers join by op.
    private let signalAudience = Audience()
    private var flushingSignals = false
    private let outbound = Outbound()
    private var runtime: ContainerRuntime?
    private var rootDataObject: RootDataObject?
    private let loadRuntime: Bool
    private let isSummarizer: Bool
    private let wholeSummary: Bool
    private let summaryMode: SummaryManager.Mode
    private var election: SummarizerClientElection?
    private var summaryGenerator: SummaryGenerator?
    private var summaryPaused = false
    private var pausedSignals: [ISignalMessage] = []
    private var summarizerChild: Container?
    private let summaryManager = SummaryManager()
    private var summarizer: Summarizer?
    private var summaryTimer: Task<Void, Never>?
    private var automaticSummaries = false
    private var summaryRequested = false
    private var summaryWorkRunning = false
    private var summaryWaiter: CheckedContinuation<Void, Error>?
    private var summaryAckTimer: Task<Void, Never>?
    private var summarizerHost: Container?
    private var summarizerGeneration: Int?
    private var summarizerParentId: JSString?
    private var summaryActive = false
    private var summaryCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var summaryFailure: String?
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

    public init(endpoint: String, document: String, loadRuntime: Bool = false, summarizer: Bool = false, wholeSummary: Bool = false, summaryMode: SummaryManager.Mode = .enabled) {
        self.loadRuntime = loadRuntime
        isSummarizer = summarizer
        self.wholeSummary = wholeSummary
        self.summaryMode = summaryMode
        automaticSummaries = loadRuntime && !summarizer && (summaryMode == .enabled || summaryMode == .disableHeuristics)
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
            let loadedVersion = try await service.storage.latestVersion()
            let snapshot = try await service.storage.snapshot(version: loadedVersion)
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
                runtime.onSubmitSignal = { [outbound] envelope, target in
                    outbound.signals.append((JSON.stringify(envelope), target?.description))
                }
                runtime.onRuntimeDispatch = { [presence] name, arguments in
                    guard name == "extension", let manager = presence.manager else { return }
                    let parts = try arguments.asArray()
                    guard parts.count == 3 else { throw JSONDecodingError("invalid extension dispatch") }
                    try manager.processSignal(
                        addressChain: parts[0].asArray().map { try $0.asString() },
                        message: InboundExtensionMessage(json: parts[1]), local: parts[2] == .bool(true))
                }
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
                election = try SummarizerClientElection(members: loaded.quorum.getMembers(), sequenceNumber: loaded.sequenceNumber, initialState: runtime.electedSummarizerData)
                summaryGenerator = SummaryGenerator(ackHandle: loadedVersion)
                if let summarizerParentId {
                    summarizer = Summarizer(parentClientId: summarizerParentId, sequenceNumber: loaded.sequenceNumber,
                        now: Date().timeIntervalSince1970 * 1000)
                }
            }
            loaded.quorum.events.on { [quorumEvents] in quorumEvents.emit($0) }
            loaded.audience.events.on { [audienceEvents] in audienceEvents.emit($0) }
            snapshotSequenceNumber = loaded.sequenceNumber
            deltaManager.lastSequenceNumber = loaded.sequenceNumber
            protocolHandler = loaded
        }
        let details = try await connectionManager.connect(service, summarizer: isSummarizer)
        deltaManager.connect(
            details, lastSequenceNumber: protocolHandler?.sequenceNumber ?? snapshotSequenceNumber)
        try protocolHandler?.initialClients(details.initialClients)
        try resetSignalAudience(details.initialClients)
        deltaManager.enqueueMessages(details.initialMessages)
        for signal in details.initialSignals { try processSignal(signal) }
        try await flushSignals()
        guard let connection = connectionManager.connection else {
            throw JSONDecodingError("disconnected")
        }
        reader = Task {
            do {
                for try await event in connection.events { try await self.receive(event) }
            } catch {
                if !Task.isCancelled {
                    self.failure = String(describing: error)
                    self.finishSummaryWait(error: error)
                    self.connectionManager.connectionFailed()
                    self.deltaManager.disconnect(String(describing: error), error: error)
                    self.raisePresenceDisconnected()
                }
            }
        }
        try await catchUp(fetchUnbounded: true)
        scheduleSummaryWork()
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
            scheduleSummaryWork()
        case "signal":
            guard let value = event.arguments.first else {
                throw JSONDecodingError("missing signal")
            }
            let batch: [JSONValue]
            if case .array(let values) = value { batch = values } else { batch = [value] }
            for value in batch { try processSignal(ISignalMessage(json: value)) }
            try await flushSignals()
        case "nack": throw DriverError("nack", .array(event.arguments))
        default: break
        }
    }

    private func processSignal(_ signal: ISignalMessage) throws {
        if summaryPaused {
            pausedSignals.append(signal)
            return
        }
        signals.append(signal)
        guard let content = try signalContent(signal) else {
            try protocolHandler?.processSignal(signal)
            return
        }
        // container.ts processSignal: only the service's clear/join/leave signals are audience
        // signals; everything else, including other system signals, goes to the runtime.
        if signal.clientId == nil, case .string(let type) = try content.member("type"),
            ["clear", "join", "leave"].contains(type.description)
        {
            try processAudienceSignal(type: type.description, content: content)
            try protocolHandler?.processSignal(signal)
        } else if let runtime {
            var message = try signal.json.asObject()
            message["content"] = content
            try runtime.processSignal(.object(message), local: signal.clientId == connectionManager.clientId)
        }
    }

    /// Signal contents arrive as JSON text from the driver.
    private func signalContent(_ signal: ISignalMessage) throws -> JSONValue? {
        guard let content = signal.content else { return nil }
        if case .string(let text) = content { return try JSON.parse(text.description) }
        return content
    }

    /// protocol.ts `wrapProtocolHandlerBuilder`: the signal audience takes every client, whatever its mode.
    private func processAudienceSignal(type: String, content: JSONValue) throws {
        switch type {
        case "clear": removeAllSignalAudienceMembers()
        case "join":
            let entry = try ISignalClient(json: content.member("content"))
            try signalAudience.addMember(entry.clientId, entry.client)
        default: signalAudience.removeMember(try content.member("content").asString())
        }
    }

    private func removeAllSignalAudienceMembers() {
        for member in signalAudience.getMembers() { signalAudience.removeMember(member.clientId) }
    }

    /// connectionManager.ts: a new connection synthesizes a `clear` signal, then a `join` per initial client.
    private func resetSignalAudience(_ clients: [ISignalClient]) throws {
        removeAllSignalAudienceMembers()
        for entry in clients { try signalAudience.addMember(entry.clientId, entry.client) }
    }

    /// Sends queued runtime signals in order. Signals are queued by synchronous runtime code and leave here,
    /// the I/O edge; only one flush runs at a time so concurrent callers can not reorder them.
    private func flushSignals() async throws {
        guard !flushingSignals else { return }
        flushingSignals = true
        defer { flushingSignals = false }
        while !outbound.signals.isEmpty {
            guard let connection = connectionManager.connection else {
                throw JSONDecodingError("disconnected")
            }
            let signal = outbound.signals.removeFirst()
            try await connection.submitSignal(signal.content, target: signal.target)
        }
    }

    private func raisePresenceDisconnected() {
        do { try presence.host?.raiseDisconnected() } catch { presence.failure = error }
    }

    private func firePresenceTimer(_ handle: Int) async {
        guard let callback = presence.clock?.takeCallback(handle) else { return }
        do {
            try callback()
            try await flushSignals()
        } catch { presence.failure = error }
    }

    /// Native equivalent of fluid-static `getPresence(container)`: acquires the presence container
    /// extension (containerRuntime.ts `acquireExtensionInternal`) and runs `body` against it
    /// synchronously on this container's executor, then sends the signals presence queued. `clock`
    /// is the container's timer-backed `PresenceClock`, which the state factories read (`Date.now`).
    public func withPresence<Result: Sendable>(
        _ body: @Sendable (_ presence: any Presence, _ clock: any PresenceClock) throws -> Result
    ) async throws -> Result {
        if let failure = presence.failure { throw failure }
        let manager = try acquirePresence()
        guard let clock = presence.clock else { throw JSONDecodingError("presence clock missing") }
        let outcome = Swift.Result { try body(manager.interface, clock) }
        try await flushSignals()
        if let failure = presence.failure { throw failure }
        return try outcome.get()
    }

    private func acquirePresence() throws -> ContainerPresenceManager {
        if let manager = presence.manager {
            manager.onNewUse()
            return manager
        }
        guard let runtime else { throw JSONDecodingError("presence requires a loaded runtime") }
        let clock = ContainerPresenceClock { [weak self] handle in await self?.firePresenceTimer(handle) }
        let adapter = PresenceAudienceAdapter(audience: signalAudience) { [presence] in presence.failure = $0 }
        let host = ContainerExtensionHost(
            runtime: runtime, connectionManager: connectionManager, audience: adapter, clock: clock)
        presence.clock = clock
        presence.host = host
        let manager = try ContainerPresenceFactory.instantiateExtension(host: host)
        presence.manager = manager
        runtime.extensions.insert(presenceExtensionId)
        return manager
    }

    private func drain() throws -> [IDocumentMessage] {
        guard let protocolHandler else { throw JSONDecodingError("no protocol state") }
        if summaryPaused { return [] }
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
            if message.type == "join" {
                let join = try IClientJoin(json: systemData(message))
                if let member = protocolHandler.quorum.getMembers().first(where: { $0.clientId == join.clientId }) {
                    election?.addMember(member, sequenceNumber: message.sequenceNumber)
                }
            } else if message.type == "leave" {
                election?.removeMember(try systemData(message).asString(), sequenceNumber: message.sequenceNumber)
            }
            election?.process(type: message.type, sequenceNumber: message.sequenceNumber)
            runtime?.electedSummarizerData = election?.serialize()
            if try summaryGenerator?.process(message) == true {
                runtime?.refreshLatestSummary()
                summarizer?.runningSummarizer.complete(acknowledged: true)
                finishSummaryWait(error: nil)
            } else if let nack = summaryGenerator?.lastNack {
                summarizer?.runningSummarizer.complete(acknowledged: false)
                finishSummaryWait(error: try SummaryNackError(nack))
            }
            if summarizer?.runningSummarizer.process(message, now: Date().timeIntervalSince1970 * 1000) != nil {
                summaryRequested = true
            }
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
        if summaryPaused { return }
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
        view["election"] = election?.serialize()
        view["summaryFailure"] = summaryFailure.map { .string(JSString($0)) }
        view["summaryAckCount"] = .number(Double(summaryGenerator?.acknowledgedCount ?? 0))
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

    public func generateSummary() throws -> JSONValue {
        guard let runtime else { throw JSONDecodingError("runtime not loaded") }
        return try runtime.summarize(fullTree: true, trackState: false).summary.json
    }

    public func submitSummarizerMessage(_ contents: JSONValue) async throws {
        guard let summarizerChild else { throw JSONDecodingError("no running summarizer") }
        try await summarizerChild.submit(type: "summarize", contents: contents)
    }

    private var loaded: Bool { protocolHandler != nil }

    public func summarizerView() async throws -> JSONValue {
        guard let summarizerChild, await summarizerChild.loaded else { return .null }
        return try await summarizerChild.view()
    }
    public func stopSummarizer() async {
        automaticSummaries = false
        summaryTimer?.cancel()
        summaryTimer = nil
        await summarizerChild?.disconnect()
        summarizerChild = nil
        _ = summaryManager.cleanup(generation: summaryManager.generation)
    }

    public func enableSummaries() {
        automaticSummaries = true
        scheduleSummaryWork()
    }

    private func scheduleSummaryWork(immediate: Bool = true) {
        guard automaticSummaries, !summaryWorkRunning else { return }
        let now = Date().timeIntervalSince1970 * 1000
        let deadline: Double
        if immediate || summaryRequested { deadline = now }
        else if isSummarizer, let idle = summarizer?.runningSummarizer.heuristicRunner.idleDeadline { deadline = idle }
        else if let start = summaryManager.startDeadline { deadline = start }
        else { return }
        summaryTimer?.cancel()
        summaryTimer = Task {
            do {
                try await Task.sleep(for: .milliseconds(max(0, deadline - now)))
                try Task.checkCancellation()
                try await self.runSummaryWork()
            } catch is CancellationError {} catch {
                self.failure = String(describing: error)
                await self.disconnect()
            }
        }
    }

    private func runSummaryWork() async throws {
        summaryTimer = nil
        summaryWorkRunning = true
        defer {
            summaryWorkRunning = false
            scheduleSummaryWork(immediate: false)
        }
        guard automaticSummaries, connectionManager.connected, let election else { return }
        let now = Date().timeIntervalSince1970 * 1000
        if isSummarizer {
            guard election.electedClientId == connectionManager.clientId else {
                try await stopGracefully(reason: "notElectedClient")
                return
            }
            guard summaryMode != .disableHeuristics, let running = summarizer?.runningSummarizer else { return }
            if !running.summarizing && (summaryRequested || running.heuristicRunner.timerFired(now: now) != nil) {
                summaryRequested = false
                var attempt = 0
                while true {
                    attempt += 1
                    do {
                        _ = try await summarize()
                        break
                    } catch let error as SummaryNackError {
                        guard attempt < 2, let retryAfter = error.nack.retryAfter else { throw error }
                        if retryAfter > 0 { try await Task.sleep(for: .seconds(retryAfter)) }
                    }
                }
            }
        } else {
            summaryManager.refresh(clientId: connectionManager.clientId, connected: connectionManager.connected,
                election: election, now: now, opsSinceLastAck: deltaManager.lastSequenceNumber - snapshotSequenceNumber)
            if let generation = summaryManager.beginCreation(now: now) {
                guard summaryManager.shouldSummarize(clientId: connectionManager.clientId, connected: connectionManager.connected, election: election) else {
                    _ = summaryManager.cleanup(generation: generation)
                    return
                }
                guard let parentId = connectionManager.clientId else { throw JSONDecodingError("missing parent id") }
                let child = Container(endpoint: service.storage.endpoint, document: service.storage.document,
                    loadRuntime: true, summarizer: true, wholeSummary: wholeSummary, summaryMode: summaryMode)
                summarizerChild = child
                do {
                    await child.startSummarizer(parentClientId: parentId, host: self, generation: generation)
                    try await child.connect()
                    guard generation == summaryManager.generation else {
                        await child.disconnect()
                        return
                    }
                    summaryManager.refresh(clientId: connectionManager.clientId, connected: connectionManager.connected,
                        election: election, now: Date().timeIntervalSince1970 * 1000,
                        opsSinceLastAck: deltaManager.lastSequenceNumber - snapshotSequenceNumber)
                } catch {
                    await child.disconnect()
                    if summaryManager.cleanup(generation: generation) { summarizerChild = nil }
                    throw error
                }
            }
            if summaryManager.state == .stopping {
                let generation = summaryManager.generation
                if let child = summarizerChild {
                    try await stopChild(child, reason: summaryManager.pendingStopReason ?? "notElectedParent")
                }
                if summaryManager.cleanup(generation: generation) { summarizerChild = nil }
            }
        }
    }

    private func startSummarizer(parentClientId: JSString, host: Container, generation: Int) {
        summarizerHost = host
        summarizerGeneration = generation
        summarizerParentId = parentClientId
        enableSummaries()
    }

    /// The interactive host owns a separate non-interactive summarizer container, as in
    /// summaryManager.ts/createSummarizer.ts. Its runtime has no local application edits.
    public func summarize() async throws -> JSONValue {
        if !isSummarizer {
            if summarizerChild == nil {
                let child = Container(endpoint: service.storage.endpoint, document: service.storage.document,
                    loadRuntime: true, summarizer: true, wholeSummary: wholeSummary, summaryMode: summaryMode)
                summarizerChild = child
                try await child.connect()
            }
            guard let summarizerChild else { throw JSONDecodingError("missing summarizer child") }
            return try await summarizerChild.summarize()
        }
        guard let runtime, let summaryGenerator, let protocolHandler,
            connectionManager.connected, runtime.pendingStateManager.pendingMessagesCount == 0,
            outbound.messages.isEmpty, !summaryActive, summaryGenerator.pendingHandle == nil
        else { throw JSONDecodingError("summary preconditions failed") }
        summaryActive = true
        defer {
            summaryActive = false
            let waiters = summaryCompletionWaiters
            summaryCompletionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if summarizer?.runningSummarizer.runAfterSummary(now: Date().timeIntervalSince1970 * 1000) != nil {
                summaryRequested = true
            }
            scheduleSummaryWork(immediate: false)
        }
        summaryPaused = true
        let reference = protocolHandler.sequenceNumber
        let minimum = protocolHandler.minimumSequenceNumber
        let before = summaryGenerator.acknowledgedCount
        do {
            try summarizer?.runningSummarizer.begin(now: Date().timeIntervalSince1970 * 1000, referenceSequenceNumber: reference)
            let summary = try runtime.summarize()
            let handle = try await service.storage.uploadSummaryWithContext(summary.summary,
                context: summaryGenerator.context(referenceSequenceNumber: reference), wholeSummary: wholeSummary)
            let contents = try summaryGenerator.submitted(handle: handle,
                referenceSequenceNumber: reference, minimumSequenceNumber: minimum)
            try await submit(type: "summarize", contents: .string(JSString(JSON.stringify(contents))))
        } catch {
            summaryPaused = false
            summaryGenerator.failAttempt()
            summarizer?.runningSummarizer.complete(acknowledged: false)
            try await catchUp()
            throw error
        }
        summaryPaused = false
        let signals = pausedSignals
        pausedSignals.removeAll(keepingCapacity: true)
        for signal in signals { try processSignal(signal) }
        try await catchUp()
        if let nack = summaryGenerator.lastNack { throw try SummaryNackError(nack) }
        if let failure { throw JSONDecodingError(failure) }
        if summaryGenerator.acknowledgedCount == before {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                summaryWaiter = continuation
                summaryAckTimer = Task {
                    do {
                        try await Task.sleep(for: .milliseconds(180000))
                        self.finishSummaryWait(error: JSONDecodingError("summary ack timeout"))
                    } catch is CancellationError {} catch { self.finishSummaryWait(error: error) }
                }
            }
        }
        return .string(summaryGenerator.ackHandle ?? "")
    }

    private func stopChild(_ child: Container, reason: String) async throws {
        let timeout = Task {
            do {
                try await Task.sleep(for: .milliseconds(120000))
                await child.disconnect()
            } catch is CancellationError {} catch { self.summaryFailure = String(describing: error) }
        }
        defer { timeout.cancel() }
        do { try await child.stopGracefully(reason: reason) }
        catch {
            await child.disconnect()
            throw error
        }
    }

    private func stopGracefully(reason: String) async throws {
        automaticSummaries = false
        summaryTimer?.cancel()
        summaryTimer = nil
        _ = summarizer?.stop(reason)
        if summaryActive {
            await withCheckedContinuation { summaryCompletionWaiters.append($0) }
        }
        if reason == "parentNotConnected", connectionManager.connected,
            summarizer?.runningSummarizer.heuristicRunner.shouldRunLastSummary() == true {
            _ = try await summarize()
        }
        await disconnect()
    }

    private func summarizerStopped(generation: Int) {
        guard summaryManager.cleanup(generation: generation) else { return }
        summarizerChild = nil
        scheduleSummaryWork()
    }

    private func finishSummaryWait(error: Error?) {
        let waiter = summaryWaiter
        summaryWaiter = nil
        summaryAckTimer?.cancel()
        summaryAckTimer = nil
        if let error {
            summaryGenerator?.failAttempt()
            summarizer?.runningSummarizer.complete(acknowledged: false)
            waiter?.resume(throwing: error)
        }
        else { waiter?.resume() }
    }

    public func disconnect() async {
        let resumeAutomaticSummaries = automaticSummaries
        automaticSummaries = false
        if !isSummarizer, let child = summarizerChild, summaryManager.state == .running {
            summaryManager.stop(reason: "parentNotConnected", now: Date().timeIntervalSince1970 * 1000)
            do { try await stopChild(child, reason: "parentNotConnected") }
            catch { summaryFailure = String(describing: error) }
        }
        _ = summaryManager.cleanup(generation: summaryManager.generation)
        finishSummaryWait(error: JSONDecodingError("summarizer disconnected"))
        summaryTimer?.cancel()
        summaryTimer = nil
        await summarizerChild?.disconnect()
        summarizerChild = nil
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
        raisePresenceDisconnected()
        automaticSummaries = resumeAutomaticSummaries
        if let summarizerHost, let summarizerGeneration {
            self.summarizerHost = nil
            self.summarizerGeneration = nil
            await summarizerHost.summarizerStopped(generation: summarizerGeneration)
        }
    }
}
