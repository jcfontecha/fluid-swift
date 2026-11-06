import FluidContainerDefinitions
import FluidContainerRuntime
import FluidDatastore
import FluidDatastoreDefinitions
import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import FluidPresence
import Foundation

/// container.ts `summarizerClientType`.
private let summarizerClientType: JSString = "summarizer"

/// summaryHelpers.ts formCreateSummarizerFn: the summarizer's client details override.
private let summarizerClientDetails: JSONValue = .object({
    var capabilities = JSObject<JSONValue>()
    capabilities["interactive"] = .bool(false)
    var details = JSObject<JSONValue>()
    details["capabilities"] = .object(capabilities)
    details["type"] = .string(summarizerClientType)
    return details
}())

/// Ports container-loader/src/container.ts. One actor owns all synchronous protocol, delta,
/// connection and listener state. Suspension occurs only at socket/REST/timer boundaries. The
/// container reaches its service only through the driver interfaces it was loaded with.
public actor Container: IContainer {
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
    private var entryPoint: AnyObject?
    private let loadRuntime: Bool
    private let isSummarizer: Bool
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
    private let resolvedUrl: IResolvedUrl
    private let urlResolver: any IUrlResolver
    private let serviceFactory: any IDocumentServiceFactory
    private let runtimeFactory: any IRuntimeFactory<ContainerRuntime>
    private let configProvider: (any IConfigProviderBase)?
    private let specifiedVersion: JSString?
    private let client: IClient
    private var service: (any IDocumentService)?
    private var storage: (any IDocumentStorageService)?
    private var deltaStorage: (any IDocumentDeltaStorageService)?
    /// The protocol handler's audience (container.ts `audience`), created before the handler.
    private let protocolAudience = Audience()
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
    private var establishing = false
    /// Between a delta connection's handshake and its loss: CatchingUp or Connected.
    private var deltaStreamOpen = false
    private var dirty = false
    public private(set) var closed = false
    public let events = ListenerList<ContainerEvent>()
    /// container.ts `containerMetadata`: no Swift driver emits `metadataUpdate`, so it stays empty.
    public private(set) var containerMetadata = JSObject<JSString>()

    /// container.ts `setupClient`: the interactive write client, with the request's client
    /// details override spread over its details.
    init(
        resolvedUrl: IResolvedUrl, urlResolver: any IUrlResolver, documentServiceFactory: any IDocumentServiceFactory,
        runtimeFactory: any IRuntimeFactory<ContainerRuntime>, configProvider: (any IConfigProviderBase)?,
        specifiedVersion: JSString?, clientDetailsOverride: JSONValue?, loadRuntime: Bool, summaryMode: SummaryManager.Mode
    ) throws {
        var fields = try JSON.parse(#"{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"scopes":[],"user":{"id":""}}"#).asObject()
        if let clientDetailsOverride {
            var details = try fields["details"]?.asObject() ?? JSObject()
            for (key, value) in try clientDetailsOverride.asObject().entries { details[key] = value }
            fields["details"] = .object(details)
        }
        let client = try IClient(json: .object(fields))
        let isSummarizer = client.details.type == summarizerClientType
        self.client = client
        self.resolvedUrl = resolvedUrl
        self.urlResolver = urlResolver
        serviceFactory = documentServiceFactory
        self.runtimeFactory = runtimeFactory
        self.configProvider = configProvider
        self.specifiedVersion = specifiedVersion
        self.loadRuntime = loadRuntime
        self.isSummarizer = isSummarizer
        self.summaryMode = summaryMode
        automaticSummaries = loadRuntime && !isSummarizer && (summaryMode == .enabled || summaryMode == .disableHeuristics)
        let connectionManager = ConnectionManager()
        self.connectionManager = connectionManager
        deltaManager = DeltaManager(active: { connectionManager.connected })
    }

    /// loader.ts RelativeLoader with container.ts `clone`: the summarizer loads the same resolved
    /// URL through the same services, as a summarizer client, at the latest version.
    private func cloneForSummarizer() throws -> Container {
        try Container(
            resolvedUrl: resolvedUrl, urlResolver: urlResolver, documentServiceFactory: serviceFactory,
            runtimeFactory: runtimeFactory, configProvider: configProvider, specifiedVersion: nil,
            clientDetailsOverride: summarizerClientDetails, loadRuntime: true, summaryMode: summaryMode)
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
        establishing = true
        defer { establishing = false }
        if protocolHandler == nil {
            try await load()
        }
        guard let service else { throw JSONDecodingError("no document service") }
        let details = try await connectionManager.connect(service, client: client)
        deltaStreamOpen = true
        // container.ts propagateConnectionState: the signal audience learns the client id while catching up.
        signalAudience.setCurrentClientId(details.clientId)
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
                    self.deltaStreamLost()
                    self.raisePresenceDisconnected()
                }
            }
        }
        try await catchUp(fetchUnbounded: true)
        scheduleSummaryWork()
    }

    /// The load half of container.ts `load`: document service, storage, snapshot, protocol state,
    /// then the runtime from the runtime factory.
    private func load() async throws {
        let service = try await serviceFactory.createDocumentService(
            resolvedUrl, clientIsSummarizer: client.details.type == summarizerClientType)
        self.service = service
        let storage = try await service.connectToStorage()
        self.storage = storage
        let (snapshot, version) = try await getSnapshot(
            storage, supportGetSnapshotApi: supportGetSnapshotApi(), specifiedVersion: specifiedVersion)
        let baseSnapshotTree = snapshot.snapshotTree
        let attributes = try await getDocumentAttributes(storage, baseSnapshotTree)
        let loaded = try await initializeProtocolStateFromSnapshot(attributes, storage, baseSnapshotTree)
        deltaManager.lastSequenceNumber = loaded.sequenceNumber
        deltaManager.minimumSequenceNumber = loaded.minimumSequenceNumber
        if loadRuntime {
            let blobContents = try await getBlobContentsFromTree(snapshot, storage: storage)
            let context = IContainerContext(
                clientId: nil, clientDetails: client.details,
                baseSnapshot: try summaryTreeFromSnapshot(baseSnapshotTree, blobContents: blobContents),
                deltaManager: deltaManager, quorum: QuorumClientsView(loaded.quorum.clients), attachState: .attached)
            let (runtime, entryPoint) = try runtimeFactory.instantiateRuntime(context, existing: true)
            runtime.referenceSequenceNumber = loaded.sequenceNumber
            self.entryPoint = entryPoint
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
            summaryGenerator = SummaryGenerator(ackHandle: version?.id)
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

    /// telemetry-utils config `getBoolean`: a boolean, or the string form of one.
    private func configBoolean(_ name: String) -> Bool? {
        switch configProvider?.getRawConfig(name) {
        case .bool(let value): value
        case .string("true"): true
        case .string("false"): false
        default: nil
        }
    }

    /// container.ts `supportGetSnapshotApi`: the service must support getSnapshot and the
    /// `Fluid.Container.UseLoadingGroupIdForSnapshotFetch2` feature gate must be on.
    private func supportGetSnapshotApi() -> Bool {
        configBoolean("Fluid.Container.UseLoadingGroupIdForSnapshotFetch2") == true
            && service?.policies?.supportGetSnapshotApi == true
    }

    /// containerStorageAdapter.ts: the service policy wins over the `summarizeProtocolTree2` gate.
    private func shouldSummarizeProtocolTree() -> Bool {
        service?.policies?.summarizeProtocolTree ?? configBoolean("Fluid.Container.summarizeProtocolTree2") ?? false
    }

    /// container.ts `initializeProtocolStateFromSnapshot`: the quorum blobs, read through storage.
    private func initializeProtocolStateFromSnapshot(
        _ attributes: IDocumentAttributes, _ storage: any IDocumentStorageService, _ snapshot: ISnapshotTree
    ) async throws -> ProtocolOpHandler {
        let baseTree = getProtocolSnapshotTree(snapshot)
        var state = JSObject<JSONValue>()
        state["sequenceNumber"] = .number(Double(attributes.sequenceNumber))
        state["minimumSequenceNumber"] = .number(Double(attributes.minimumSequenceNumber))
        state["members"] = try await readAndParse(storage, baseTree.blobs["quorumMembers"])
        state["proposals"] = try await readAndParse(storage, baseTree.blobs["quorumProposals"])
        state["values"] = try await readAndParse(storage, baseTree.blobs["quorumValues"])
        return try ProtocolOpHandler(state: IProtocolState(json: .object(state)), audience: protocolAudience)
    }

    private func connectToDeltaStorage() async throws -> any IDocumentDeltaStorageService {
        if let deltaStorage { return deltaStorage }
        guard let service else { throw JSONDecodingError("no document service") }
        let connected = try await service.connectToDeltaStorage()
        deltaStorage = connected
        return connected
    }

    private func receive(_ event: DocumentDeltaConnectionEvent) async throws {
        switch event {
        case .op(_, let messages):
            deltaManager.enqueueMessages(messages)
            try await catchUp()
            scheduleSummaryWork()
        case .signal(let batch):
            for signal in batch { try processSignal(signal) }
            try await flushSignals()
        case .nack(let documentId, let nacks):
            throw DriverError("nack", .array([.string(documentId), .array(nacks.map(\.json))]))
        case .disconnect(let reason):
            throw reason
        case .pong:
            break
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
        for clientId in signalAudience.getMembers().keys { signalAudience.removeMember(clientId) }
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
            try await connection.submitSignal(signal.content, targetClientId: signal.target)
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
                protocolHandler.audience.setCurrentClientId(id)
                events.emit(.connected(clientId: id))
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
        updateDirtyContainerState()
        return messages
    }

    /// container.ts `updateDirtyContainerState`, from the runtime's pending messages: emits
    /// `dirty` or `saved` on a change.
    private func updateDirtyContainerState() {
        let dirty = (runtime?.pendingStateManager.pendingMessagesCount ?? 0) > 0
        guard self.dirty != dirty else { return }
        self.dirty = dirty
        events.emit(dirty ? .dirty : .saved)
    }

    private func catchUp(fetchUnbounded: Bool = false) async throws {
        try await sendMessages(drain())
        if summaryPaused { return }
        if !fetching && (fetchUnbounded || !deltaManager.pending.isEmpty) {
            fetching = true
            defer { fetching = false }
            var unbounded = fetchUnbounded
            while let current = protocolHandler, unbounded || !deltaManager.pending.isEmpty {
                // Refetch the prior op deliberately: DeltaManager detects a replaced file by its
                // sender/type/MSN/reference/timestamp fingerprint, not by comparing contents. The
                // driver batches the range and, bounded, fetches all of it (requestOps 0x270).
                let (from, to) = deltaManager.fetchRange(sequenceNumber: current.sequenceNumber)
                let reason = unbounded ? "DocumentOpen" : "Gap"
                unbounded = false
                let deltaStorage = try await connectToDeltaStorage()
                for try await messages in deltaStorage.fetchMessages(from, to: to, cachedOnly: false, fetchReason: reason) {
                    deltaManager.enqueueMessages(messages, source: "storage")
                    try await sendMessages(drain())
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
        try await connection.submitSignal(text, targetClientId: nil)
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

    /// Runs `body` against the runtime's entry point on this container's executor, then flushes the
    /// runtime's batch and sends it: the end of the JS turn, where containerRuntime.ts flushes.
    public func withEntryPoint<Result: Sendable>(_ body: @Sendable (AnyObject) throws -> Result) async throws -> Result {
        if let failure { throw JSONDecodingError(failure) }
        guard let entryPoint, let runtime else { throw JSONDecodingError("container has no runtime") }
        let result = try body(entryPoint)
        try runtime.flush()
        let messages = outbound.messages
        outbound.messages.removeAll(keepingCapacity: true)
        try await sendMessages(messages)
        updateDirtyContainerState()
        return result
    }

    public var connectionState: ConnectionState {
        if deltaStreamOpen { return connectionManager.connected ? .connected : .catchingUp }
        return establishing ? .establishingConnection : .disconnected
    }

    /// container.ts propagateConnectionState: one `disconnected` per transition to Disconnected.
    private func deltaStreamLost() {
        guard deltaStreamOpen else { return }
        deltaStreamOpen = false
        events.emit(.disconnected)
    }

    public var isDirty: Bool { dirty }

    public var attachState: AttachState { .attached }

    /// container.ts `clientId`: the audience's self, set once this client's join is processed.
    public var clientId: JSString? { protocolAudience.getSelf()?.clientId }

    public var audience: any FluidContainerDefinitions.IAudience { protocolAudience }

    public var readOnlyInfo: ReadOnlyInfo { deltaManager.readOnlyInfo }

    public func getEntryPoint() async throws -> AnyObject {
        if closed { throw JSONDecodingError("The context is already disposed") }
        guard let entryPoint else { throw JSONDecodingError("container has no runtime") }
        return entryPoint
    }

    /// container.ts `close`: disconnect for good, then emit `closed`.
    public func close(_ error: (any Error)?) async {
        guard !closed else { return }
        closed = true
        await disconnect()
        events.emit(.closed(error: error))
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
                let child = try cloneForSummarizer()
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
                let child = try cloneForSummarizer()
                summarizerChild = child
                try await child.connect()
            }
            guard let summarizerChild else { throw JSONDecodingError("missing summarizer child") }
            return try await summarizerChild.summarize()
        }
        guard let runtime, let summaryGenerator, let protocolHandler, let storage,
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
            // protocolTreeDocumentStorageService.ts uploadSummaryWithContext.
            let upload = shouldSummarizeProtocolTree()
                ? try addProtocolSummaryIfMissing(summary.summary, protocolHandler) : summary.summary
            let handle = try await storage.uploadSummaryWithContext(upload,
                context: summaryGenerator.context(referenceSequenceNumber: reference))
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
        if hadConnection {
            deltaManager.disconnect("Client disconnect")
            deltaStreamLost()
        }
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

/// container.ts `captureProtocolSummary`: the protocol handler's attributes and quorum, in TS's
/// literal property order (`tree` before `type`, `content` before `type`).
func captureProtocolSummary(_ protocolHandler: ProtocolOpHandler) throws -> ISummaryTree {
    func blob(_ value: JSONValue) -> JSONValue {
        var object = JSObject<JSONValue>()
        object["content"] = .string(JSString(JSON.stringify(value)))
        object["type"] = .number(Double(SummaryType.blob.rawValue))
        return .object(object)
    }
    var attributes = JSObject<JSONValue>()
    attributes["minimumSequenceNumber"] = .number(Double(protocolHandler.minimumSequenceNumber))
    attributes["sequenceNumber"] = .number(Double(protocolHandler.sequenceNumber))
    let quorum = protocolHandler.quorum
    var tree = JSObject<JSONValue>()
    tree["attributes"] = blob(.object(attributes))
    tree["quorumMembers"] = blob(.array(quorum.getMembers().map(\.json)))
    tree["quorumProposals"] = blob(.array(quorum.proposals.getProposals().map(\.json)))
    tree["quorumValues"] = blob(.array(quorum.proposals.getValues().map(\.json)))
    var summary = JSObject<JSONValue>()
    summary["tree"] = .object(tree)
    summary["type"] = .number(Double(SummaryType.tree.rawValue))
    return try ISummaryTree(json: .object(summary))
}

/// container.ts `addProtocolSummaryIfMissing`: a combined summary is uploaded as is.
func addProtocolSummaryIfMissing(_ summaryTree: SummaryTree, _ protocolHandler: ProtocolOpHandler) throws -> SummaryTree {
    guard case .tree(let tree) = summaryTree, !isCombinedAppAndProtocolSummary(tree) else { return summaryTree }
    return .tree(try combineAppAndProtocolSummary(tree, captureProtocolSummary(protocolHandler)))
}
