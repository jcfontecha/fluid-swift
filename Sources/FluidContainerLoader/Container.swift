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

/// Ports container-loader/src/container.ts. The container, its runtime, datastores and DDSes are
/// one plain, synchronous, non-Sendable graph that belongs to exactly one owner actor
/// (ARCHITECTURE.md section 2). `loadExistingContainer(_:isolation:)` prepares the graph off the
/// owner, and the owner adopts it with `start(on:)`. That starts the container's one event loop on
/// the owner's executor, the analogue of the JS event loop. Socket events, the turn-based flush,
/// timers and summarizer notices arrive there as jobs. The container awaits only where TS awaits
/// (delta stream, storage, timers), and after each await it re-checks the state TS re-checks.
/// It reaches its service only through the driver interfaces it was loaded with.
public final class Container: IContainer {
    /// Work for the event loop. Anything may produce a job (socket forwarders, timers, the
    /// summarizer child); only the loop runs them, on the owner.
    enum Job: Sendable {
        /// An event from the delta connection of attempt `attempt`.
        case connection(attempt: Int, DocumentDeltaConnectionEvent)
        /// That connection's event stream threw.
        case connectionFailed(attempt: Int, any Error)
        /// connectionManager.ts connectCore after its synchronous start: the awaited half.
        case connect(attempt: Int)
        /// containerRuntime.ts scheduleFlush, TurnBased: the flush at the end of the turn.
        case flush
        /// deltaScheduler.ts paused the inbound queue; resume it on a later turn.
        case inboundPaused
        /// deltaScheduler.ts `setTimeout(() => inbound.resume())`.
        case resumeInbound
        case noopTimer(Int)
        case summaryTimer(Int)
        case summaryAckTimeout(Int)
        case presenceTimer(Int)
        /// The summarizer child of `generation` disconnected.
        case summarizerStopped(generation: Int)
        /// The summarizer child failed to stop.
        case summaryFailure(String)
        /// `endTurn`: every job queued before this one has run.
        case turnEnd(CheckedContinuation<Void, Never>)
    }
    /// Presence is a container extension (containerRuntime.ts `acquireExtension`). Closures capture
    /// this holder, so they never capture the container.
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
    private var runtime: ContainerRuntime?
    private var entryPoint: AnyObject?
    private let loadRuntime: Bool
    private let isSummarizer: Bool
    private let summaryMode: SummaryManager.Mode
    private var election: SummarizerClientElection?
    private var summaryGenerator: SummaryGenerator?
    private var summaryPaused = false
    private var pausedSignals: [ISignalMessage] = []
    private var summarizerChild: SummarizerHost?
    private let summaryManager = SummaryManager()
    private var summarizer: Summarizer?
    private var summaryTimer: Task<Void, Never>?
    private var summaryTimerToken = 0
    private var automaticSummaries = false
    private var summaryRequested = false
    private var summaryWorkRunning = false
    private var summaryWaiter: CheckedContinuation<Void, Error>?
    private var summaryAckTimer: Task<Void, Never>?
    private var summaryAckToken = 0
    /// A summarizer child's notice to its parent, with the child's generation.
    private var summarizerStopped: (@Sendable (Int) -> Void)?
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
    private var noopTimer: Task<Void, Never>?
    private var noopTimerToken = 0
    private var fetching = false
    private var establishing = false
    /// Between a delta connection's handshake and its loss: CatchingUp or Connected.
    private var deltaStreamOpen = false
    private var dirty = false
    private var disposed = false
    /// The owner tasks running a connection attempt and a storage fetch, cancelled on close.
    private var connectTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private let jobs: AsyncStream<Job>
    private let jobSink: AsyncStream<Job>.Continuation
    private var loop: Task<Void, Never>?
    /// Created when the owner adopts the container: catch-up before that runs off the owner and
    /// never yields.
    private var deltaScheduler: DeltaScheduler?
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
        (jobs, jobSink) = AsyncStream.makeStream()
    }

    /// loader.ts RelativeLoader with container.ts `clone`: the summarizer loads the same resolved
    /// URL through the same services, as a summarizer client, at the latest version. The clone
    /// shares nothing with this container, so it can go to its own owner.
    private func cloneForSummarizer() throws -> sending Container {
        try Container(
            resolvedUrl: resolvedUrl, urlResolver: urlResolver, documentServiceFactory: serviceFactory,
            runtimeFactory: runtimeFactory, configProvider: configProvider, specifiedVersion: nil,
            clientDetailsOverride: summarizerClientDetails, loadRuntime: true, summaryMode: summaryMode)
    }

    public func onDelta(_ listener: @escaping (DeltaManagerEvent) -> Void) {
        deltaManager.events.on(listener)
    }

    public func onQuorum(_ listener: @escaping (QuorumEvent) -> Void) {
        quorumEvents.on(listener)
    }

    public func onAudience(_ listener: @escaping (AudienceEvent) -> Void) {
        audienceEvents.on(listener)
    }

    /// container.ts load, then connect: the snapshot, protocol state and runtime, then the delta
    /// stream and the ops storage has after the snapshot. Runs before an owner adopts the container,
    /// on whatever isolation the caller has (off the owner for `loadExistingContainer`).
    nonisolated(nonsending) func open() async throws {
        try await load()
        try Task.checkCancellation()
        guard let attempt = connectionManager.beginConnection() else { return }
        establishing = true
        try await connectToDeltaStream(attempt)
    }

    /// Adopts the container on `owner` and starts its event loop there. Adoption is once-only.
    /// `owner` is a non-optional isolated parameter (ARCHITECTURE.md section 2): capturing it
    /// isolates the loop task to the owner, and `for await` stays on it (SE-0421), so no job ever
    /// runs elsewhere.
    func start(on owner: isolated any Actor) {
        precondition(loop == nil, "Container.start(on:) adopts a container once")
        let scheduler = DeltaScheduler(inboundLength: { [deltaManager] in deltaManager.pending.count })
        deltaScheduler = scheduler
        runtime?.onEvent = { name, _ in
            if name == "batchBegin" {
                scheduler.batchBegin()
            } else if name == "batchEnd" {
                scheduler.batchEnd()
            }
        }
        loop = Task { [weak self, jobs] in
            _ = owner
            for await job in jobs {
                guard let self else { return }
                self.run(job, on: owner)
            }
        }
    }

    /// One job, synchronously. Async work (a connection attempt, a gap fetch, summary work) starts
    /// as a task isolated to the owner and re-checks state after each await.
    private func run(_ job: Job, on owner: isolated any Actor) {
        if case .turnEnd(let continuation) = job {
            continuation.resume()
            return
        }
        guard !closed else { return }
        switch job {
        case .connection(let attempt, let event):
            // Events of a connection this container already dropped are stale.
            guard connectionManager.isCurrent(attempt) else { return }
            do {
                try receive(event)
                startGapFetchIfNeeded(on: owner)
            } catch {
                connectionFailed(error)
            }
        case .connectionFailed(let attempt, let error):
            guard connectionManager.isCurrent(attempt) else { return }
            connectionFailed(error)
        case .connect(let attempt):
            guard connectionManager.pendingConnection == attempt else { return }
            connectTask = Task {
                _ = owner
                do {
                    try await self.connectToDeltaStream(attempt)
                } catch {
                    self.connectAttemptFailed(attempt, error)
                }
            }
        case .flush:
            // containerRuntime.ts flush: a failure closes the container.
            do {
                try runtime?.flush()
                updateDirtyContainerState()
            } catch {
                close(error)
            }
        case .inboundPaused:
            Task { [jobSink] in
                _ = owner
                await Task.yield()
                jobSink.yield(.resumeInbound)
            }
        case .resumeInbound:
            deltaScheduler?.resume()
            do {
                try drainInbound()
                startGapFetchIfNeeded(on: owner)
            } catch {
                connectionFailed(error)
            }
        case .noopTimer(let token):
            guard token == noopTimerToken else { return }
            noopTimer = nil
            do { try timerFired() } catch { failure = String(describing: error) }
        case .summaryTimer(let token):
            guard token == summaryTimerToken else { return }
            summaryTimer = nil
            Task {
                _ = owner
                do {
                    try await self.runSummaryWork()
                } catch {
                    self.failure = String(describing: error)
                    if !self.closed { self.disconnect() }
                }
            }
        case .summaryAckTimeout(let token):
            guard token == summaryAckToken else { return }
            finishSummaryWait(error: JSONDecodingError("summary ack timeout"))
        case .presenceTimer(let handle):
            firePresenceTimer(handle)
        case .summarizerStopped(let generation):
            summarizerStopped(generation: generation)
        case .summaryFailure(let description):
            summaryFailure = description
        case .turnEnd:
            break
        }
    }

    /// The end of a turn that the host defines: returns once the loop has run every job queued
    /// before the call, such as the turn-based flush of the edits this turn made. In TS this comes
    /// from the event loop itself, because microtasks run before the next macrotask. A Swift actor
    /// gives no such order between two tasks: a caller's next call can reach the owner before the
    /// loop runs. A host that drives the owner one request at a time, such as the service harness
    /// peer, calls this between requests, so each request's edits leave as their own batch, as they
    /// do from a TS client. It flushes nothing itself and does not change batching within a turn.
    package nonisolated(nonsending) func endTurn() async {
        await withCheckedContinuation { continuation in
            if case .terminated = jobSink.yield(.turnEnd(continuation)) {
                continuation.resume()
            }
        }
    }

    /// TS `connect(): void`: starts a connection when this client has none and none is in flight.
    /// The awaited half runs on the owner's loop; `connected` reports the result.
    public func connect() {
        precondition(!closed, "The Container is closed and cannot be connected")
        guard !connectionManager.connected, let attempt = connectionManager.beginConnection() else { return }
        establishing = true
        jobSink.yield(.connect(attempt: attempt))
    }

    /// The load half of container.ts `load`: document service, storage, snapshot, protocol state,
    /// then the runtime from the runtime factory.
    private nonisolated(nonsending) func load() async throws {
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
            runtime.onSubmitSignal = { [connectionManager] envelope, target in
                try connectionManager.submitSignal(JSON.stringify(envelope), targetClientId: target?.description)
            }
            runtime.onRuntimeDispatch = { [presence] name, arguments in
                guard name == "extension", let manager = presence.manager else { return }
                let parts = try arguments.asArray()
                guard parts.count == 3 else { throw JSONDecodingError("invalid extension dispatch") }
                try manager.processSignal(
                    addressChain: parts[0].asArray().map { try $0.asString() },
                    message: InboundExtensionMessage(json: parts[1]), local: parts[2] == .bool(true))
            }
            // container.ts submitBatch: CSNs are assigned and the batch is enqueued on the
            // connection in one synchronous step, so wire order is CSN order.
            runtime.onSubmitBatch = { [deltaManager, connectionManager] messages in
                var batch: [IDocumentMessage] = []
                for message in messages {
                    let prepared = try deltaManager.prepareMessage(
                        type: "op", contents: message.member("contents"),
                        referenceSequenceNumber: message.member("referenceSequenceNumber").asInt())
                    var fields = try prepared.json.asObject()
                    for (key, value) in try message.asObject().entries { fields[key] = value }
                    batch.append(try IDocumentMessage(json: .object(fields)))
                }
                try connectionManager.sendMessages(batch)
                return batch.last?.clientSequenceNumber ?? 0
            }
            runtime.onScheduleFlush = { [jobSink] in jobSink.yield(.flush) }
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
    private nonisolated(nonsending) func initializeProtocolStateFromSnapshot(
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

    private nonisolated(nonsending) func connectToDeltaStorage() async throws -> any IDocumentDeltaStorageService {
        if let deltaStorage { return deltaStorage }
        guard let service else { throw JSONDecodingError("no document service") }
        let connected = try await service.connectToDeltaStorage()
        deltaStorage = connected
        return connected
    }

    /// connectionManager.ts connectCore and setupNewSuccessfulConnection, then the storage
    /// catch-up of container.ts load. An attempt that disconnect or close cancelled while it
    /// awaited the driver installs nothing.
    private nonisolated(nonsending) func connectToDeltaStream(_ attempt: Int) async throws {
        guard let service else { throw JSONDecodingError("no document service") }
        guard let connection = try await connectionManager.connect(service, client: client, attempt: attempt) else {
            return
        }
        establishing = false
        deltaStreamOpen = true
        let details = connection.details
        // container.ts propagateConnectionState: the signal audience learns the client id while catching up.
        signalAudience.setCurrentClientId(details.clientId)
        deltaManager.connect(
            details, lastSequenceNumber: protocolHandler?.sequenceNumber ?? snapshotSequenceNumber)
        try protocolHandler?.initialClients(details.initialClients)
        try resetSignalAudience(details.initialClients)
        deltaManager.enqueueMessages(details.initialMessages)
        for signal in details.initialSignals { try processSignal(signal) }
        forwardEvents(of: connection, attempt: attempt)
        try await catchUp(fetchUnbounded: true)
        scheduleSummaryWork()
    }

    /// Moves the connection's events into the job queue, in order. Until the owner adopts the
    /// container they wait there, so ops that arrive during an off-owner load are kept.
    private func forwardEvents(of connection: any IDocumentDeltaConnection, attempt: Int) {
        Task { [jobSink] in
            do {
                for try await event in connection.events {
                    jobSink.yield(.connection(attempt: attempt, event))
                }
            } catch {
                jobSink.yield(.connectionFailed(attempt: attempt, error))
            }
        }
    }

    /// The awaited half of a connection attempt failed. Only the attempt in flight, or the
    /// connection it installed, reports it; a cancelled attempt was abandoned.
    private func connectAttemptFailed(_ attempt: Int, _ error: any Error) {
        if connectionManager.pendingConnection == attempt {
            connectionManager.cancelConnection()
            establishing = false
            failure = String(describing: error)
        } else if connectionManager.isCurrent(attempt) {
            connectionFailed(error)
        }
    }

    private func receive(_ event: DocumentDeltaConnectionEvent) throws {
        switch event {
        case .op(_, let messages):
            deltaManager.enqueueMessages(messages)
            try drainInbound()
            scheduleSummaryWork()
        case .signal(let batch):
            for signal in batch { try processSignal(signal) }
        case .nack(let documentId, let nacks):
            throw DriverError("nack", .array([.string(documentId), .array(nacks.map(\.json))]))
        case .disconnect(let reason):
            throw reason
        case .pong:
            break
        }
    }

    /// The delta connection failed: a socket error, a nack, or an error processing its events.
    private func connectionFailed(_ error: any Error) {
        failure = String(describing: error)
        finishSummaryWait(error: error)
        setRuntimeDisconnected()
        let connection = connectionManager.disconnect()
        deltaManager.disconnect(String(describing: error), error: error)
        deltaStreamLost()
        raisePresenceDisconnected()
        if let connection { Task { await connection.dispose() } }
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

    private func raisePresenceDisconnected() {
        do { try presence.host?.raiseDisconnected() } catch { presence.failure = error }
    }

    private func firePresenceTimer(_ handle: Int) {
        guard let callback = presence.clock?.takeCallback(handle) else { return }
        do { try callback() } catch { presence.failure = error }
    }

    /// Native equivalent of fluid-static `getPresence(container)`: acquires the presence container
    /// extension (containerRuntime.ts `acquireExtensionInternal`). `clock` is the container's
    /// timer-backed `PresenceClock`, which the state factories read (`Date.now`). A failure that a
    /// presence listener or timer raised since the last call is thrown here.
    public func getPresence() throws -> (presence: any Presence, clock: any PresenceClock) {
        if let failure = presence.failure { throw failure }
        let manager = try acquirePresence()
        guard let clock = presence.clock else { throw JSONDecodingError("presence clock missing") }
        return (manager.interface, clock)
    }

    private func acquirePresence() throws -> ContainerPresenceManager {
        if let manager = presence.manager {
            manager.onNewUse()
            return manager
        }
        guard let runtime else { throw JSONDecodingError("presence requires a loaded runtime") }
        let clock = ContainerPresenceClock { [jobSink] handle in jobSink.yield(.presenceTimer(handle)) }
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

    /// deltaQueue.ts processDeltas over container.ts processRemoteMessage: applies, in order and
    /// synchronously, every queued op that is next in sequence. Once the owner runs the loop,
    /// deltaScheduler.ts may pause at a runtime batch end; the loop resumes on a later turn.
    private func drainInbound() throws {
        guard let protocolHandler else { throw JSONDecodingError("no protocol state") }
        if summaryPaused || deltaScheduler?.paused == true { return }
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
            if message.type == "op", let runtime {
                _ = try runtime.process(message.json)
            } else {
                // containerRuntime.ts: any other message is a batch of one, and runtime.process
                // flushes the open local batch before it.
                try runtime?.flush()
                deltaScheduler?.batchBegin()
                deltaScheduler?.batchEnd()
            }
            runtime?.referenceSequenceNumber = message.sequenceNumber
            if !wasConnected && connectionManager.connected, let id = connectionManager.clientId {
                try runtime?.reconnect(clientId: id.description)
                protocolHandler.audience.setCurrentClientId(id)
                events.emit(.connected(clientId: id))
            }
            if connectionManager.connected {
                if result.immediateNoOp == true {
                    try connectionManager.sendMessages([
                        try deltaManager.prepareMessage(
                            type: "accept", contents: nil,
                            referenceSequenceNumber: protocolHandler.sequenceNumber)
                    ])
                }
                deltaManager.noopHeuristic.notifyMessageProcessed(message)
                if message.type == "op" && deltaManager.noopHeuristic.opsProcessedSinceOpSent == 1 {
                    restartNoopTimer()
                }
            }
            deltaManager.recordProcessed(
                entry, duration: (Date().timeIntervalSince1970 - started) * 1000)
            // deltaScheduler.ts paused the queue at this message's batch end.
            if deltaScheduler?.paused == true {
                jobSink.yield(.inboundPaused)
                break
            }
        }
        if deltaScheduler?.paused != true {
            deltaScheduler?.inboundQueueIdle()
        }
        if connectionManager.connected && deltaManager.noopHeuristic.takeWantsNoop() {
            try connectionManager.sendMessages([
                try deltaManager.prepareMessage(
                    type: "noop", contents: nil,
                    referenceSequenceNumber: protocolHandler.sequenceNumber)
            ])
        }
        updateDirtyContainerState()
    }

    /// container.ts `updateDirtyContainerState`, from the runtime's pending messages: emits
    /// `dirty` or `saved` on a change.
    private func updateDirtyContainerState() {
        let dirty = (runtime?.pendingStateManager.pendingMessagesCount ?? 0) > 0
        guard self.dirty != dirty else { return }
        self.dirty = dirty
        events.emit(dirty ? .dirty : .saved)
    }

    /// Ops are queued past the next sequence number, and the scheduler has not merely paused.
    private var hasGap: Bool {
        deltaScheduler?.paused != true && !deltaManager.pending.isEmpty
    }

    /// Drains what is queued, then fetches from storage: unbounded at connect (DocumentOpen),
    /// otherwise only a gap.
    private nonisolated(nonsending) func catchUp(fetchUnbounded: Bool = false) async throws {
        try drainInbound()
        if summaryPaused || fetching { return }
        guard fetchUnbounded || hasGap else { return }
        fetching = true
        defer { fetching = false }
        try await fetchMissingDeltas(unbounded: fetchUnbounded)
    }

    /// deltaManager.ts fetchMissingDeltas: a gap in the socket's ops is filled from storage in the
    /// background while the loop keeps running.
    private func startGapFetchIfNeeded(on owner: isolated any Actor) {
        guard !fetching, !summaryPaused, hasGap else { return }
        fetching = true
        fetchTask = Task {
            _ = owner
            defer { self.fetching = false }
            do {
                try await self.fetchMissingDeltas(unbounded: false)
            } catch {
                if !self.closed { self.connectionFailed(error) }
            }
        }
    }

    private nonisolated(nonsending) func fetchMissingDeltas(unbounded fetchUnbounded: Bool) async throws {
        var unbounded = fetchUnbounded
        while let current = protocolHandler, !closed, unbounded || hasGap {
            // Refetch the prior op deliberately: DeltaManager detects a replaced file by its
            // sender/type/MSN/reference/timestamp fingerprint, not by comparing contents. The
            // driver batches the range and, bounded, fetches all of it (requestOps 0x270).
            let (from, to) = deltaManager.fetchRange(sequenceNumber: current.sequenceNumber)
            let reason = unbounded ? "DocumentOpen" : "Gap"
            unbounded = false
            let deltaStorage = try await connectToDeltaStorage()
            for try await messages in deltaStorage.fetchMessages(from, to: to, cachedOnly: false, fetchReason: reason) {
                // deltaManager.ts clearQueues: a closed container drops what storage returns.
                guard !closed else { return }
                deltaManager.enqueueMessages(messages, source: "storage")
                try drainInbound()
            }
        }
    }

    /// noopHeuristic.ts restarts its timer whenever debt becomes one, even when an older timer
    /// still exists. Merely retaining that timer can acknowledge a new batch prematurely.
    private func restartNoopTimer() {
        noopTimer?.cancel()
        noopTimerToken += 1
        let delay = deltaManager.noopHeuristic.noopTimeFrequency
        guard delay.isFinite else {
            noopTimer = nil
            return
        }
        let token = noopTimerToken
        noopTimer = Task { [jobSink] in
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            jobSink.yield(.noopTimer(token))
        }
    }

    private func timerFired() throws {
        if connectionManager.connected && deltaManager.noopHeuristic.opsProcessedSinceOpSent > 0 {
            try submit(type: "noop")
        }
    }

    /// container.ts submitMessage: one protocol message, enqueued on the connection synchronously.
    public func submit(type: String, contents: JSONValue? = nil) throws {
        guard connectionManager.connected, let protocolHandler else {
            throw JSONDecodingError("not connected to own join")
        }
        let message = try deltaManager.prepareMessage(
            type: type, contents: contents, referenceSequenceNumber: protocolHandler.sequenceNumber)
        try connectionManager.sendMessages([message])
    }

    public func signal(_ text: String) throws {
        guard connectionManager.connection != nil else {
            throw JSONDecodingError("disconnected")
        }
        try connectionManager.submitSignal(text, targetClientId: nil)
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

    public nonisolated(nonsending) func getEntryPoint() async throws -> AnyObject {
        if closed { throw JSONDecodingError("The context is already disposed") }
        guard let entryPoint else { throw JSONDecodingError("container has no runtime") }
        return entryPoint
    }

    /// container.ts `close`: disconnects for good, then emits `closed`. Nothing processes after
    /// it, so the event loop ends. A summarizer is disposed too (closeCore: no user disposes it).
    public func close(_ error: (any Error)?) {
        guard !closed else { return }
        closed = true
        tearDown()
        events.emit(.closed(error: error))
        if isSummarizer { dispose(error) }
    }

    /// container.ts `dispose`: closes without `closed`, releases the document service and the
    /// timers, then emits `disposed`.
    public func dispose(_ error: (any Error)?) {
        guard !disposed else { return }
        disposed = true
        if !closed {
            closed = true
            tearDown()
        }
        noopTimer?.cancel()
        noopTimer = nil
        summaryAckTimer?.cancel()
        summaryAckTimer = nil
        presence.clock?.cancelAll()
        service?.dispose(error)
        events.emit(.disposed(error: error))
    }

    /// The terminal half of close and dispose: the connection, any attempt or fetch in flight, the
    /// summarizer and the job queue go away.
    private func tearDown() {
        disconnectCore()
        connectTask?.cancel()
        connectTask = nil
        fetchTask?.cancel()
        fetchTask = nil
        jobSink.finish()
    }

    public func generateSummary() throws -> JSONValue {
        guard let runtime else { throw JSONDecodingError("runtime not loaded") }
        return try runtime.summarize(fullTree: true, trackState: false).summary.json
    }

    public nonisolated(nonsending) func submitSummarizerMessage(_ contents: JSONValue) async throws {
        guard let summarizerChild else { throw JSONDecodingError("no running summarizer") }
        try await summarizerChild.submit(type: "summarize", contents: contents)
    }

    var loaded: Bool { protocolHandler != nil }

    public nonisolated(nonsending) func summarizerView() async throws -> JSONValue {
        guard let summarizerChild else { return .null }
        return try await summarizerChild.view() ?? .null
    }

    public nonisolated(nonsending) func stopSummarizer() async {
        automaticSummaries = false
        summaryTimer?.cancel()
        summaryTimer = nil
        let child = summarizerChild
        summarizerChild = nil
        _ = summaryManager.cleanup(generation: summaryManager.generation)
        await child?.disconnect()
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
        summaryTimerToken += 1
        let token = summaryTimerToken
        summaryTimer = Task { [jobSink] in
            do { try await Task.sleep(for: .milliseconds(max(0, deadline - now))) } catch { return }
            jobSink.yield(.summaryTimer(token))
        }
    }

    private nonisolated(nonsending) func runSummaryWork() async throws {
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
                let child = SummarizerHost(try cloneForSummarizer())
                summarizerChild = child
                do {
                    try await child.open(parentClientId: parentId, generation: generation) { [jobSink] generation in
                        jobSink.yield(.summarizerStopped(generation: generation))
                    }
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
                    try await child.stop(reason: summaryManager.pendingStopReason ?? "notElectedParent")
                }
                if summaryManager.cleanup(generation: generation) { summarizerChild = nil }
            }
        }
    }

    /// A summarizer child: `parentClientId` elects it, and `stopped` tells the parent, on the
    /// parent's loop, that the child of `generation` disconnected.
    func startSummarizer(parentClientId: JSString, generation: Int, stopped: @escaping @Sendable (Int) -> Void) {
        summarizerStopped = stopped
        summarizerGeneration = generation
        summarizerParentId = parentClientId
        enableSummaries()
    }

    /// The interactive host owns a separate non-interactive summarizer container, as in
    /// summaryManager.ts/createSummarizer.ts. Its runtime has no local application edits.
    public nonisolated(nonsending) func summarize() async throws -> JSONValue {
        if !isSummarizer {
            if summarizerChild == nil {
                let child = SummarizerHost(try cloneForSummarizer())
                summarizerChild = child
                try await child.open(parentClientId: nil, generation: nil, stopped: nil)
            }
            guard let summarizerChild else { throw JSONDecodingError("missing summarizer child") }
            return try await summarizerChild.summarize()
        }
        guard let runtime, let summaryGenerator, let protocolHandler, let storage,
            connectionManager.connected, runtime.pendingStateManager.pendingMessagesCount == 0,
            !summaryActive, summaryGenerator.pendingHandle == nil
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
            try submit(type: "summarize", contents: .string(JSString(JSON.stringify(contents))))
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
            summaryAckToken += 1
            let token = summaryAckToken
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                summaryWaiter = continuation
                summaryAckTimer = Task { [jobSink] in
                    do { try await Task.sleep(for: .milliseconds(180000)) } catch { return }
                    jobSink.yield(.summaryAckTimeout(token))
                }
            }
        }
        return .string(summaryGenerator.ackHandle ?? "")
    }

    nonisolated(nonsending) func stopGracefully(reason: String) async throws {
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
        disconnect()
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

    /// TS `disconnect(): void`. A running summarizer child stops in the background, as
    /// summaryManager.ts stops it once the parent is no longer connected; its stop notice cleans
    /// up on this container's loop.
    public func disconnect() {
        precondition(!closed, "The Container is closed and cannot be disconnected")
        disconnectCore()
    }

    private func disconnectCore() {
        if !isSummarizer, let child = summarizerChild, summaryManager.state == .running {
            summaryManager.stop(reason: "parentNotConnected", now: Date().timeIntervalSince1970 * 1000)
            Task { [jobSink] in
                do { try await child.stop(reason: "parentNotConnected") }
                catch { jobSink.yield(.summaryFailure(String(describing: error))) }
            }
        } else {
            _ = summaryManager.cleanup(generation: summaryManager.generation)
            if let child = summarizerChild { Task { await child.disconnect() } }
            summarizerChild = nil
        }
        finishSummaryWait(error: JSONDecodingError("summarizer disconnected"))
        summaryTimer?.cancel()
        summaryTimer = nil
        setRuntimeDisconnected()
        let hadConnection = connectionManager.connection != nil
        establishing = false
        let connection = connectionManager.disconnect()
        if hadConnection {
            deltaManager.disconnect("Client disconnect")
            deltaStreamLost()
        }
        noopTimer?.cancel()
        noopTimer = nil
        if let connection { Task { await connection.dispose() } }
        raisePresenceDisconnected()
        if let summarizerStopped, let summarizerGeneration {
            self.summarizerStopped = nil
            self.summarizerGeneration = nil
            summarizerStopped(summarizerGeneration)
        }
    }

    /// containerRuntime.ts setConnectionState(false): the runtime and its datastores stop sending.
    private func setRuntimeDisconnected() {
        guard let runtime else { return }
        runtime.connected = false
        for id in runtime.channelCollection.datastoreIds {
            do { try runtime.channelCollection.getDatastore(id).setConnectionState(false, clientId: nil) }
            catch { failure = String(describing: error) }
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
