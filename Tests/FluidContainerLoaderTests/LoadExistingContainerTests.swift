import FluidContainerDefinitions
import FluidContainerRuntime
import FluidDatastore
import FluidDriverDefinitions
import FluidJS
import FluidMap
import FluidStatic
import Foundation
import Synchronization
import Testing

@testable import FluidContainerLoader

/// Records every driver call the loader makes, in order, across actors.
private final class CallLog: Sendable {
    private let entries = Mutex<[String]>([])

    func append(_ entry: String) {
        entries.withLock { $0.append(entry) }
    }

    var all: [String] { entries.withLock { $0 } }
}

/// The captured TS summary, re-shaped as driver output: an ISnapshotTree whose blobs are ids
/// into a byte map, as a storage service returns them.
private struct CapturedSnapshot {
    let tree: ISnapshotTree
    let blobs: JSObject<[UInt8]>
    let summary: SummaryTree
    let sequenceNumber: Int

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "m2-summary", withExtension: "json", subdirectory: "Fixtures"))
        let summary = try SummaryTree(json: JSON.parse(String(contentsOf: url, encoding: .utf8)))
        var blobs = JSObject<[UInt8]>()
        var counter = 0
        func convert(_ node: ISummaryTree, id: String) throws -> JSONValue {
            var blobIds = JSObject<JSONValue>()
            var trees = JSObject<JSONValue>()
            for (name, child) in node.tree.entries {
                switch child {
                case .blob(let blob):
                    guard case .text(let text) = blob.content else { throw JSONDecodingError("binary fixture blob") }
                    counter += 1
                    let blobId = JSString("blob-\(counter)")
                    blobs[blobId] = Array(text.description.utf8)
                    blobIds[name] = .string(blobId)
                case .tree(let subtree):
                    trees[name] = try convert(subtree, id: id + "/" + name.description)
                default:
                    throw JSONDecodingError("unexpected fixture entry")
                }
            }
            var object = JSObject<JSONValue>()
            object["id"] = .string(JSString(id))
            object["blobs"] = .object(blobIds)
            object["trees"] = .object(trees)
            return .object(object)
        }
        guard case .tree(let root) = summary else { throw JSONDecodingError("fixture root") }
        tree = try ISnapshotTree(json: convert(root, id: "tree-root"))
        self.blobs = blobs
        self.summary = summary
        sequenceNumber = try summary.readTree(".protocol").readAndParse("attributes").member("sequenceNumber").asInt()
    }
}

extension SummaryTree {
    fileprivate func readTree(_ name: JSString) throws -> SummaryTree {
        guard case .tree(let tree) = self, case .tree(let child) = tree.tree[name] else {
            throw JSONDecodingError("missing summary tree \(name)")
        }
        return .tree(child)
    }
}

private final class FakeStorage: IDocumentStorageService {
    let log: CallLog
    let captured: CapturedSnapshot

    init(log: CallLog, captured: CapturedSnapshot) {
        self.log = log
        self.captured = captured
    }

    func getSnapshotTree(_ version: IVersion?, scenarioName: String?) async throws -> ISnapshotTree? {
        log.append("getSnapshotTree(\(version?.id.description ?? "nil"))")
        return captured.tree
    }

    func getSnapshot(_ options: ISnapshotFetchOptions?) async throws -> ISnapshot {
        log.append("getSnapshot(\(options?.versionId?.description ?? "nil"))")
        return ISnapshot(
            snapshotTree: captured.tree, blobContents: SnapshotBlobContents(buffers: captured.blobs), ops: [],
            sequenceNumber: captured.sequenceNumber, latestSequenceNumber: nil)
    }

    func getVersions(_ versionId: JSString?, count: Int, scenarioName: String?, fetchSource: FetchSource?) async throws
        -> [IVersion]
    {
        log.append("getVersions(\(versionId?.description ?? "nil"),\(count))")
        return [try IVersion(json: JSON.parse(#"{"id":"version-1","treeId":"tree-root"}"#))]
    }

    func createBlob(_ file: [UInt8]) async throws -> ICreateBlobResponse {
        throw JSONDecodingError("unexpected createBlob")
    }

    func readBlob(_ id: JSString) async throws -> [UInt8] {
        log.append("readBlob(\(id))")
        guard let bytes = captured.blobs[id] else { throw JSONDecodingError("missing blob \(id)") }
        return bytes
    }

    func uploadSummaryWithContext(_ summary: SummaryTree, context: ISummaryContext) async throws -> JSString {
        throw JSONDecodingError("unexpected upload")
    }

    func downloadSummary(_ handle: ISummaryHandle) async throws -> SummaryTree {
        throw JSONDecodingError("unexpected download")
    }
}

/// Delta storage: what the ordering service sequenced in [from, to), or nothing without one.
private final class FakeDeltaStorage: IDocumentDeltaStorageService {
    let log: CallLog
    let ordering: Ordering?

    init(log: CallLog, ordering: Ordering?) {
        self.log = log
        self.ordering = ordering
    }

    func fetchMessages(_ from: Int, to: Int?, cachedOnly: Bool, fetchReason: String?)
        -> AsyncThrowingStream<[ISequencedDocumentMessage], any Error>
    {
        log.append("fetchMessages(\(from),\(to.map(String.init) ?? "nil"))")
        let (stream, continuation) = AsyncThrowingStream<[ISequencedDocumentMessage], any Error>.makeStream()
        Task { [ordering] in
            let messages = await ordering?.log.filter { $0.sequenceNumber >= from && $0.sequenceNumber < (to ?? Int.max) } ?? []
            if !messages.isEmpty { continuation.yield(messages) }
            continuation.finish()
        }
        return stream
    }
}

/// An in-process ordering service with deli's client sequence number rule (lambdas/src/deli/lambda.ts
/// `checkOrder`): the expected CSN is sequenced, a higher one is a gap and is nacked. It sequences a
/// join when a client connects and a leave when it disconnects, and broadcasts every sequenced
/// message to every connected client.
private actor Ordering {
    private(set) var sequenceNumber: Int
    private var clients: [String: AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error>.Continuation] = [:]
    private var expected: [String: Int] = [:]
    /// Clients whose deliveries are held, with what they have not received yet.
    private var held: [String: [ISequencedDocumentMessage]] = [:]
    private(set) var nacks: [String] = []
    /// Every message the service sequenced, in order.
    private(set) var log: [ISequencedDocumentMessage] = []
    /// `submit` calls, counted synchronously on the client's side of the socket.
    nonisolated let submitCalls = Mutex(0)

    init(sequenceNumber: Int) {
        self.sequenceNumber = sequenceNumber
    }

    func join(_ clientId: String, _ events: AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error>.Continuation) throws {
        clients[clientId] = events
        expected[clientId] = 1
        let data = JSON.stringify(.object(try JSON.parse(#"{"clientId":"\#(clientId)","detail":\#(interactiveClient)}"#).asObject()))
        try sequence(system: "join", data: data)
    }

    func leave(_ clientId: String) throws {
        guard clients.removeValue(forKey: clientId) != nil else { return }
        try sequence(system: "leave", data: JSON.stringify(.string(JSString(clientId))))
    }

    func receive(_ clientId: String, _ messages: [IDocumentMessage]) throws {
        for message in messages {
            guard let next = expected[clientId] else { return }
            guard message.clientSequenceNumber == next else {
                nacks.append("\(clientId): expected CSN \(next), got \(message.clientSequenceNumber)")
                return
            }
            expected[clientId] = next + 1
            var fields = try message.json.asObject()
            fields["clientId"] = .string(JSString(clientId))
            try broadcast(fields)
        }
    }

    /// Holds `clientId`'s deliveries until `release`, which hands them over as one socket event.
    func hold(_ clientId: String) {
        held[clientId] = []
    }

    func release(_ clientId: String) {
        guard let messages = held.removeValue(forKey: clientId), !messages.isEmpty else { return }
        clients[clientId]?.yield(.op(documentId: "doc", messages: messages))
    }

    private func sequence(system type: String, data: String) throws {
        var fields = JSObject<JSONValue>()
        fields["clientId"] = .null
        fields["clientSequenceNumber"] = .number(-1)
        fields["contents"] = .null
        fields["data"] = .string(JSString(data))
        fields["referenceSequenceNumber"] = .number(-1)
        fields["type"] = .string(JSString(type))
        try broadcast(fields)
    }

    private func broadcast(_ message: JSObject<JSONValue>) throws {
        sequenceNumber += 1
        var fields = message
        fields["sequenceNumber"] = .number(Double(sequenceNumber))
        fields["minimumSequenceNumber"] = .number(0)
        fields["timestamp"] = .number(0)
        let sequenced = try ISequencedDocumentMessage(json: .object(fields))
        log.append(sequenced)
        for (clientId, events) in clients {
            if held[clientId] != nil {
                held[clientId]?.append(sequenced)
            } else {
                events.yield(.op(documentId: "doc", messages: [sequenced]))
            }
        }
    }
}

/// A delta connection with the drivers' outbound shape: `submit` enqueues synchronously onto one
/// FIFO, and one writer hands each batch to the service's actor in order.
private final class FakeDeltaConnection: IDocumentDeltaConnection {
    let details: IConnected
    let events: AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error>
    private let continuation: AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error>.Continuation
    private let ordering: Ordering?
    private let clientId: String
    private let writes: AsyncStream<[IDocumentMessage]>.Continuation
    private let writer: Task<Void, Never>

    init(clientId: String, ordering: Ordering?) throws {
        self.clientId = clientId
        self.ordering = ordering
        details = try IConnected(json: JSON.parse("""
            {"claims":{"documentId":"doc","scopes":["doc:read","doc:write"],"tenantId":"fake","user":{"id":"u"},"iat":0,"exp":0,"ver":"1.0"},\
            "clientId":"\(clientId)","existing":true,"maxMessageSize":16384,"initialMessages":[],"initialSignals":[],"initialClients":[],\
            "version":"^0.4.0","supportedVersions":["^0.4.0"],"serviceConfiguration":{"maxMessageSize":16384,"blockSize":65436},"mode":"write"}
            """))
        (events, continuation) = AsyncThrowingStream.makeStream()
        let (pending, writes) = AsyncStream<[IDocumentMessage]>.makeStream()
        self.writes = writes
        writer = Task {
            for await batch in pending {
                do { try await ordering?.receive(clientId, batch) } catch { Issue.record(error) }
            }
        }
    }

    func join() async throws {
        try await ordering?.join(clientId, continuation)
    }

    func submit(_ messages: [IDocumentMessage]) {
        ordering?.submitCalls.withLock { $0 += 1 }
        writes.yield(messages)
    }

    func submitSignal(_ content: String, targetClientId: String?) throws {}

    func dispose() async {
        writes.finish()
        await writer.value
        do { try await ordering?.leave(clientId) } catch { Issue.record(error) }
        continuation.finish()
    }
}

private final class FakeService: IDocumentService {
    let resolvedUrl: IResolvedUrl
    let policies: IDocumentServicePolicies?
    let log: CallLog
    let captured: CapturedSnapshot
    let clientId: String
    let ordering: Ordering?
    private let connections = Mutex(0)

    init(resolvedUrl: IResolvedUrl, policies: IDocumentServicePolicies?, log: CallLog, captured: CapturedSnapshot, clientId: String, ordering: Ordering?) {
        self.resolvedUrl = resolvedUrl
        self.policies = policies
        self.log = log
        self.captured = captured
        self.clientId = clientId
        self.ordering = ordering
    }

    func connectToStorage() async throws -> any IDocumentStorageService {
        log.append("connectToStorage")
        return FakeStorage(log: log, captured: captured)
    }

    func connectToDeltaStorage() async throws -> any IDocumentDeltaStorageService {
        log.append("connectToDeltaStorage")
        return FakeDeltaStorage(log: log, ordering: ordering)
    }

    /// Each connection gets a new client id, as the service gives one.
    func connectToDeltaStream(_ client: IClient) async throws -> any IDocumentDeltaConnection {
        log.append("connectToDeltaStream(\(JSON.stringify(client.json)))")
        let index = connections.withLock { count in
            count += 1
            return count
        }
        let connection = try FakeDeltaConnection(clientId: "\(clientId)-\(index)", ordering: ordering)
        try await connection.join()
        return connection
    }

    func dispose(_ error: (any Error)?) {}
}

private final class FakeFactory: IDocumentServiceFactory {
    let policies: IDocumentServicePolicies?
    let log: CallLog
    let captured: CapturedSnapshot
    let ordering: Ordering?
    private let services = Mutex(0)

    init(policies: IDocumentServicePolicies?, log: CallLog, captured: CapturedSnapshot, ordering: Ordering? = nil) {
        self.policies = policies
        self.log = log
        self.captured = captured
        self.ordering = ordering
    }

    func createDocumentService(_ resolvedUrl: IResolvedUrl, clientIsSummarizer: Bool) async throws -> any IDocumentService {
        log.append("createDocumentService(\(JSON.stringify(resolvedUrl.json)),\(clientIsSummarizer))")
        let index = services.withLock { count in
            count += 1
            return count
        }
        return FakeService(resolvedUrl: resolvedUrl, policies: policies, log: log, captured: captured, clientId: "client-\(index)", ordering: ordering)
    }

    func createContainer(_ createNewSummary: SummaryTree?, resolvedUrl: IResolvedUrl, clientIsSummarizer: Bool) async throws
        -> any IDocumentService
    {
        throw JSONDecodingError("unexpected createContainer")
    }
}

private struct FakeResolver: IUrlResolver {
    let log: CallLog

    func resolve(_ request: IRequest) async throws -> IResolvedUrl? {
        log.append("resolve(\(request.url))")
        return try IResolvedUrl(json: JSON.parse("""
            {"type":"fluid","id":"doc","url":"https://fake.example/tenant/doc","tokens":{},"endpoints":{"storageUrl":"https://fake.example/storage"}}
            """))
    }

    func getAbsoluteUrl(_ resolvedUrl: IResolvedUrl, relativeUrl: String) async throws -> String {
        log.append("getAbsoluteUrl(\(relativeUrl))")
        return "doc/" + relativeUrl
    }
}

private let interactiveClient = #"{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"scopes":[],"user":{"id":""}}"#
private let summarizerClient = #"{"mode":"write","details":{"capabilities":{"interactive":false},"type":"summarizer"},"permission":[],"scopes":[],"user":{"id":""}}"#
private let resolvedJSON = #"{"type":"fluid","id":"doc","url":"https://fake.example/tenant/doc","tokens":{},"endpoints":{"storageUrl":"https://fake.example/storage"}}"#

/// A config provider with the given feature gates on.
private struct Gates: IConfigProviderBase {
    let names: Set<String>

    func getRawConfig(_ name: String) -> JSONValue? { names.contains(name) ? .bool(true) : nil }
}

private let snapshotFetchGate = "Fluid.Container.UseLoadingGroupIdForSnapshotFetch2"

private func props(_ factory: FakeFactory, _ log: CallLog, gates: Set<String> = []) throws -> ILoadExistingContainerProps {
    ILoadExistingContainerProps(
        request: IRequest(url: "doc"), urlResolver: FakeResolver(log: log), documentServiceFactory: factory,
        runtimeFactory: try createDOProviderContainerRuntimeFactory(
            schema: ContainerSchema(initialObjects: ["map": SharedMap.self]), oldestSupportedClient: "2.0.0"),
        configProvider: Gates(names: gates), summaryMode: .disabled)
}

/// fluid-static: the root data object's "map".
private func initialMap(_ entryPoint: AnyObject) throws -> SharedMap {
    guard let root = entryPoint as? RootDataObject, let map = root.initialObjects["map"] as? SharedMap else {
        throw JSONDecodingError("initialObject is not a SharedMap")
    }
    return map
}

/// The fluid-static entry point's "map" entries.
@MainActor
private func mapEntries(_ container: Container) async throws -> JSONValue {
    var values = JSObject<JSONValue>()
    for (key, value) in try initialMap(await container.getEntryPoint()).entries() { values[key] = value ?? .null }
    return .object(values)
}

private func pendingMessages(_ container: Container) throws -> Int {
    try container.view().member("runtime").member("pendingMessages").asInt()
}

private func sequenceNumber(_ container: Container) throws -> Int {
    try container.view().member("sequenceNumber").asInt()
}

/// Gives the owner's turns away until `condition` holds; the container's loop, its drivers and the
/// ordering service make progress meanwhile. A barrier, not a sleep.
@MainActor
private func until(_ label: String, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        await Task.yield()
    }
    throw JSONDecodingError("timed out: \(label)")
}

private let capturedValue = #"{"seed":0,"nested":[null,true,"hello"]}"#

@Suite("loadExistingContainer") @MainActor struct LoadExistingContainerTests {
    /// serializedStateManager.ts fetchISnapshotTree: without supportGetSnapshotApi the loader asks for
    /// the latest version, then its tree, and reads every blob through storage.
    @Test func loadsThroughVersionsAndSnapshotTreeWithoutGetSnapshotSupport() async throws {
        let log = CallLog()
        let captured = try CapturedSnapshot()
        let container = try await loadExistingContainer(props(FakeFactory(policies: nil, log: log, captured: captured), log), isolation: MainActor.shared)
        #expect(try await mapEntries(container) == JSON.parse("{\"captured\":\(capturedValue)}"))
        let calls = log.all
        #expect(Array(calls.prefix(5)) == [
            "resolve(doc)",
            "createDocumentService(\(resolvedJSON),false)",
            "connectToStorage",
            "getVersions(nil,1)",
            "getSnapshotTree(version-1)",
        ])
        #expect(!calls.contains { $0.hasPrefix("getSnapshot(") })
        for id in captured.blobs.keys { #expect(calls.contains("readBlob(\(id))")) }
        let connect = try #require(calls.firstIndex(of: "connectToDeltaStream(\(interactiveClient))"))
        let fetch = try #require(calls.firstIndex(of: "fetchMessages(\(captured.sequenceNumber),nil)"))
        #expect(connect < fetch)
        #expect(calls.contains("connectToDeltaStorage"))
        container.disconnect()
    }

    /// container.ts supportGetSnapshotApi also needs the UseLoadingGroupIdForSnapshotFetch2 gate:
    /// without it a service that supports getSnapshot still loads through getVersions.
    @Test func getSnapshotSupportAloneStillLoadsThroughVersions() async throws {
        let log = CallLog()
        let captured = try CapturedSnapshot()
        let factory = FakeFactory(policies: IDocumentServicePolicies(supportGetSnapshotApi: true), log: log, captured: captured)
        let container = try await loadExistingContainer(props(factory, log), isolation: MainActor.shared)
        let calls = log.all
        #expect(calls.contains("getVersions(nil,1)"))
        #expect(!calls.contains { $0.hasPrefix("getSnapshot(") })
        container.disconnect()
    }

    /// serializedStateManager.ts fetchISnapshot: with supportGetSnapshotApi and its gate the loader
    /// issues one getSnapshot and takes the runtime's blobs from ISnapshot.blobContents.
    @Test func loadsThroughGetSnapshotWhenTheServiceSupportsItAndTheGateIsOn() async throws {
        let log = CallLog()
        let captured = try CapturedSnapshot()
        let factory = FakeFactory(policies: IDocumentServicePolicies(supportGetSnapshotApi: true), log: log, captured: captured)
        let container = try await loadExistingContainer(props(factory, log, gates: [snapshotFetchGate]), isolation: MainActor.shared)
        #expect(try await mapEntries(container) == JSON.parse("{\"captured\":\(capturedValue)}"))
        let calls = log.all
        #expect(calls.contains("getSnapshot(nil)"))
        #expect(!calls.contains { $0.hasPrefix("getVersions") || $0.hasPrefix("getSnapshotTree") })
        // container.ts getDocumentAttributes and initializeProtocolStateFromSnapshot still read
        // `.protocol` through storage; the runtime's blobs come from blobContents.
        let protocolTree = try #require(captured.tree.trees[".protocol"])
        let protocolReads = ["attributes", "quorumMembers", "quorumProposals", "quorumValues"].map { name in
            "readBlob(\(protocolTree.blobs[JSString(name)]?.description ?? ""))"
        }
        #expect(calls.filter { $0.hasPrefix("readBlob") } == protocolReads)
        container.disconnect()
    }

    /// loader.ts RelativeLoader + container.ts clone: the summarizer reuses the resolved URL and the
    /// document service factory, with summarizer client details, and never re-resolves.
    @Test func summarizerChildReusesTheResolvedUrlAndFactory() async throws {
        let log = CallLog()
        let captured = try CapturedSnapshot()
        let container = try await loadExistingContainer(props(FakeFactory(policies: nil, log: log, captured: captured), log), isolation: MainActor.shared)
        await #expect(throws: (any Error).self) { _ = try await container.summarize() }
        let calls = log.all
        #expect(calls.filter { $0.hasPrefix("resolve(") }.count == 1)
        #expect(calls.filter { $0.hasPrefix("createDocumentService(") } == [
            "createDocumentService(\(resolvedJSON),false)",
            "createDocumentService(\(resolvedJSON),true)",
        ])
        #expect(calls.contains("connectToDeltaStream(\(summarizerClient))"))
        container.disconnect()
    }

    /// Swift-only bridge to the synchronous runtime: each node projects its blobs, then its trees,
    /// the order ISnapshotTree exposes them, with blob text from the contents map.
    @Test func resolvedSummaryTreeCombinesTheSnapshotTreeAndItsBlobContents() async throws {
        let captured = try CapturedSnapshot()
        var contents = JSObject<JSString>()
        for (id, bytes) in captured.blobs.entries { contents[id] = JSString(String(decoding: bytes, as: UTF8.self)) }
        let resolved = try summaryTreeFromSnapshot(captured.tree, blobContents: contents)
        func reorder(_ node: ISummaryTree) -> SummaryTree {
            var entries = JSObject<SummaryObject>()
            for (name, child) in node.tree.entries {
                if case .blob = child { entries[name] = child }
            }
            for (name, child) in node.tree.entries {
                if case .tree(let subtree) = child, case .tree(let projected) = reorder(subtree) {
                    entries[name] = .tree(projected)
                }
            }
            return SummaryTree(tree: entries)
        }
        guard case .tree(let root) = captured.summary else { throw JSONDecodingError("fixture root") }
        #expect(JSON.stringify(resolved.json) == JSON.stringify(reorder(root).json))
    }

    /// containerStorageAdapter.ts getBlobManagerTreeFromTree: under the root `.blobs` tree only the
    /// redirect table is content; every other entry is an attachment blob id.
    @Test func rootBlobsTreeBecomesAttachmentsAndItsRedirectTable() async throws {
        let tree = try ISnapshotTree(json: JSON.parse("""
            {"blobs":{},"trees":{".blobs":{"blobs":{"0":"sha-a",".redirectTable":"sha-table"},"trees":{}}}}
            """))
        var contents = JSObject<JSString>()
        contents["sha-table"] = #"[["local","sha-a"]]"#
        let resolved = try summaryTreeFromSnapshot(tree, blobContents: contents)
        #expect(JSON.stringify(resolved.json) == #"{"type":1,"tree":{".blobs":{"type":1,"tree":{"0":{"type":4,"id":"sha-a"},".redirectTable":{"type":2,"content":"[[\"local\",\"sha-a\"]]"}}}}}"#)
    }

    @Test func protocolSnapshotTreeFallsBackToTheRootForOldDocuments() throws {
        let nested = try ISnapshotTree(json: JSON.parse(#"{"blobs":{},"trees":{".protocol":{"blobs":{"attributes":"a"},"trees":{}}}}"#))
        #expect(getProtocolSnapshotTree(nested).blobs["attributes"] == "a")
        let flat = try ISnapshotTree(json: JSON.parse(#"{"blobs":{"quorumMembers":"m"},"trees":{}}"#))
        #expect(getProtocolSnapshotTree(flat).blobs["quorumMembers"] == "m")
    }

    @Test func compatibleResolvedUrlParsesTenantDocumentPathAndVersion() throws {
        let parsed = try #require(tryParseCompatibleResolvedUrl("http://localhost:7070/tinylicious/doc/route?version=abc"))
        #expect(parsed.id == "tinylicious/doc")
        #expect(parsed.path == "/route")
        #expect(parsed.query == "?version=abc")
        #expect(parsed.version == "abc")
        #expect(tryParseCompatibleResolvedUrl("not a url") == nil)
        #expect(tryParseCompatibleResolvedUrl("http://localhost/") == nil)
    }
}

/// Records the thread each runtime instantiation ran on, around the fluid-static factory.
private final class RecordingRuntimeFactory: IRuntimeFactory, Sendable {
    let inner: DOProviderContainerRuntimeFactory
    let ranOnMainThread = Mutex<[Bool]>([])

    init() throws {
        inner = try createDOProviderContainerRuntimeFactory(
            schema: ContainerSchema(initialObjects: ["map": SharedMap.self]), oldestSupportedClient: "2.0.0")
    }

    func instantiateRuntime(_ context: IContainerContext, existing: Bool) throws
        -> (runtime: ContainerRuntime, entryPoint: AnyObject)
    {
        ranOnMainThread.withLock { $0.append(Thread.isMainThread) }
        return try inner.instantiateRuntime(context, existing: existing)
    }
}

/// A private owner that makes one edit per call, as the service peer handles one request per turn.
private actor EditorHost {
    private var container: Container?
    private var map: SharedMap?

    func open(_ factory: FakeFactory, _ log: CallLog) async throws {
        let container = try await loadExistingContainer(props(factory, log), isolation: self)
        map = try initialMap(await container.getEntryPoint())
        self.container = container
    }

    func connected() -> Bool {
        container?.connectionState == .connected
    }

    func pending() throws -> Int {
        guard let container else { throw JSONDecodingError("not open") }
        return try pendingMessages(container)
    }

    func edit(_ index: Int) async throws {
        try map?.set(JSString("turn-\(index)"), .number(Double(index)))
        await container?.endTurn()
    }

    func dispose() {
        container?.dispose(nil)
    }
}

/// The owner model (ARCHITECTURE.md section 2) against an in-process ordering service: edits on the
/// owner, the turn-based flush, the synchronous socket edge and catch-up scheduling.
@Suite("Container owner") @MainActor struct ContainerOwnerTests {
    /// A host that ends each turn with `endTurn` sends each turn's edits as their own batch, even
    /// when another task starts the next turn at once, as a TS client's microtask flush runs before
    /// its next macrotask. Without it the actor runs the caller's next call before the loop's
    /// flush, and the turns share batches: 50 turns left as 2 batches with the barrier removed.
    @Test func eachHostTurnLeavesAsItsOwnBatch() async throws {
        let captured = try CapturedSnapshot()
        let ordering = Ordering(sequenceNumber: captured.sequenceNumber)
        let log = CallLog()
        let host = EditorHost()
        try await host.open(FakeFactory(policies: nil, log: log, captured: captured, ordering: ordering), log)
        try await until("own join") { await host.connected() }
        // Back-to-back calls from off the owner, as the peer's request loop makes them.
        try await Task.detached {
            for index in 0..<50 {
                try await host.edit(index)
            }
        }.value
        try await until("every turn acknowledged") { try await host.pending() == 0 }
        let ops = await ordering.log.filter { $0.clientId == "client-1-1" && $0.type == "op" }
        #expect(ops.count == 50)
        await host.dispose()
    }

    /// ARCHITECTURE.md section 2, "Loading is off-owner": the snapshot is hydrated into a runtime
    /// on the cooperative pool even when the owner is MainActor, and the owner adopts the result.
    @Test func loadingRunsOffTheOwner() async throws {
        let captured = try CapturedSnapshot()
        let log = CallLog()
        let runtimeFactory = try RecordingRuntimeFactory()
        let container = try await loadExistingContainer(ILoadExistingContainerProps(
            request: IRequest(url: "doc"), urlResolver: FakeResolver(log: log),
            documentServiceFactory: FakeFactory(policies: nil, log: log, captured: captured),
            runtimeFactory: runtimeFactory, summaryMode: .disabled), isolation: MainActor.shared)
        #expect(runtimeFactory.ranOnMainThread.withLock { $0 } == [false])
        #expect(try await mapEntries(container) == JSON.parse("{\"captured\":\(capturedValue)}"))
        container.dispose(nil)
    }

    private func load(_ factory: FakeFactory, _ log: CallLog) async throws -> (Container, SharedMap) {
        let container = try await loadExistingContainer(props(factory, log), isolation: MainActor.shared)
        let map = try initialMap(await container.getEntryPoint())
        try await until("own join") { container.connectionState == .connected }
        return (container, map)
    }

    /// driver-definitions `submit(messages): void` and deli `checkOrder`: client sequence numbers
    /// reach the service in the order they were assigned. Offline edits stay pending; the next
    /// connection's own join resubmits them, one message per batch, while new edits flush around
    /// it. With the awaiting submit this replaced, the resubmitted batches were overtaken by new
    /// edits in 50 of 50 trials, as CSNs [1, 5, 6, 7, 8, 2, 3, 4], which deli nacks as a gap.
    @Test func clientSequenceNumbersReachTheServiceInOrder() async throws {
        let captured = try CapturedSnapshot()
        for _ in 0..<20 {
            let ordering = Ordering(sequenceNumber: captured.sequenceNumber)
            let log = CallLog()
            let (container, map) = try await load(FakeFactory(policies: nil, log: log, captured: captured, ordering: ordering), log)
            container.disconnect()
            for index in 0..<4 {
                try map.set(JSString("offline-\(index)"), .number(Double(index)))
                try await until("offline batch \(index) pending") { try pendingMessages(container) == index + 1 }
            }
            container.connect()
            // connectionManager.ts connectCore: one attempt in flight.
            container.connect()
            for index in 0..<4 {
                try map.set(JSString("online-\(index)"), .number(Double(index)))
                await Task.yield()
            }
            try await until("every edit acknowledged") {
                try container.connectionState == .connected && pendingMessages(container) == 0
            }
            #expect(log.all.filter { $0.hasPrefix("connectToDeltaStream(") }.count == 2)
            #expect(await ordering.nacks == [])
            let sent = await ordering.log.filter { $0.clientId == "client-1-2" }.map(\.clientSequenceNumber)
            #expect(sent.count >= 5)
            #expect(sent == Array(1...max(1, sent.count)))
            container.dispose(nil)
        }
    }

    /// containerRuntime.ts scheduleFlush, TurnBased: edits made in one turn on the owner send
    /// nothing during the turn and leave as one batch after it, with no flush call.
    @Test func editsInOneTurnLeaveAsOneBatchAfterTheTurn() async throws {
        let captured = try CapturedSnapshot()
        let ordering = Ordering(sequenceNumber: captured.sequenceNumber)
        let log = CallLog()
        let (container, map) = try await load(FakeFactory(policies: nil, log: log, captured: captured, ordering: ordering), log)
        let before = ordering.submitCalls.withLock { $0 }
        try map.set("a", .number(1))
        try map.set("b", .number(2))
        try map.set("c", .number(3))
        #expect(ordering.submitCalls.withLock { $0 } == before)
        try await until("edits acknowledged") {
            try ordering.submitCalls.withLock { $0 } > before && pendingMessages(container) == 0
        }
        let ops = await ordering.log.filter { $0.clientId == "client-1-1" && $0.type == "op" }
        // One grouped batch: the three ops share one message and one reference sequence number.
        #expect(ops.count == 1)
        #expect(try await mapEntries(container).member("c") == .number(3))
        container.dispose(nil)
    }

    /// deltaScheduler.ts: a long catch-up on the owner pauses only at a runtime batch end, once its
    /// 4 ms slice is spent, and the owner's other work runs in the gap. An edit made there carries
    /// that batch end as its reference sequence number: the open batch is flushed before the next
    /// inbound op applies (containerRuntime.ts process).
    @Test func catchUpYieldsToTheOwnerOnlyAtBatchEnds() async throws {
        final class Probe {
            var seen: Int?
        }
        let captured = try CapturedSnapshot()
        let ordering = Ordering(sequenceNumber: captured.sequenceNumber)
        let log = CallLog()
        let factory = FakeFactory(policies: nil, log: log, captured: captured, ordering: ordering)
        let (reader, readerMap) = try await load(factory, log)
        let (writer, writerMap) = try await load(factory, log)
        try await until("reader saw the writer join") { (try sequenceNumber(reader)) == (await ordering.sequenceNumber) }
        await ordering.hold("client-1-1")
        let start = await ordering.sequenceNumber
        let text = JSString(String(repeating: "catch-up ", count: 40))
        for turn in 0..<60 {
            for index in 0..<10 { try writerMap.set(JSString("key-\(index)"), .string(text)) }
            try await until("writer batch \(turn) sequenced") { (await ordering.sequenceNumber) > start + turn }
        }
        try await until("writer acknowledged") { (try pendingMessages(writer)) == 0 }
        let end = await ordering.sequenceNumber
        let probe = Probe()
        reader.onDelta { event in
            guard case .op(let message, _) = event, message.sequenceNumber == start + 1 else { return }
            // Runs on the owner at its next opportunity: inside the catch-up only if the catch-up yields.
            Task {
                do {
                    probe.seen = try sequenceNumber(reader)
                    try readerMap.set("probe", .number(1))
                } catch {
                    Issue.record(error)
                }
            }
        }
        await ordering.release("client-1-1")
        try await until("reader caught up") {
            try sequenceNumber(reader) >= end && pendingMessages(reader) == 0
        }
        try await until("writer saw the probe") { (try sequenceNumber(writer)) == (try sequenceNumber(reader)) }
        // The probe exists from op start + 1 on; it ran before the catch-up ended.
        let seen = try #require(probe.seen)
        #expect(seen < end)
        let probeOp = await ordering.log.first { $0.clientId == "client-1-1" && $0.type == "op" }
        #expect(probeOp?.referenceSequenceNumber == seen)
        let writerEntries = try await mapEntries(writer)
        #expect(try await mapEntries(reader) == writerEntries)
        reader.dispose(nil)
        writer.dispose(nil)
    }
}

/// protocolTreeDocumentStorageService.ts with container.ts addProtocolSummaryIfMissing: when the
/// service asks for single-commit summaries, the runtime's summary goes up as `.app` beside the
/// captured protocol state, in TS property order.
@Suite("summarizeProtocolTree") struct SummarizeProtocolTreeTests {
    private func handler() throws -> ProtocolOpHandler {
        try ProtocolOpHandler(state: IProtocolState(json: JSON.parse(
            #"{"sequenceNumber":5,"minimumSequenceNumber":3,"members":[],"proposals":[],"values":[]}"#)))
    }

    @Test func capturedProtocolSummaryMatchesTheTypeScriptLiteral() throws {
        #expect(JSON.stringify(try captureProtocolSummary(handler()).json)
            == #"{"tree":{"attributes":{"content":"{\"minimumSequenceNumber\":3,\"sequenceNumber\":5}","type":2},"quorumMembers":{"content":"[]","type":2},"quorumProposals":{"content":"[]","type":2},"quorumValues":{"content":"[]","type":2}},"type":1}"#)
    }

    @Test func appSummaryIsCombinedWithTheProtocolSummaryOnce() throws {
        let app = SummaryTree.singleBlob("blob", "text")
        let combined = try addProtocolSummaryIfMissing(app, handler())
        #expect(JSON.stringify(combined.json).hasPrefix(#"{"type":1,"tree":{".protocol":{"tree":{"attributes""#))
        #expect(JSON.stringify(combined.json).hasSuffix(#""type":1},".app":{"type":1,"tree":{"blob":{"type":2,"content":"text"}}}}}"#))
        #expect(try addProtocolSummaryIfMissing(combined, handler()) == combined)
    }
}
