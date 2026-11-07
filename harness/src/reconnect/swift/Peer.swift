import FluidContainerDefinitions
import FluidContainerRuntime
import FluidDatastore
import FluidDriverUtils
import FluidDriverDefinitions
import FluidJS
import FluidMap
import FluidStatic
import Foundation
import Synchronization

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
        let url = URL(fileURLWithPath: "Tests/FluidContainerLoaderTests/Fixtures/m2-summary.json")
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

/// Driver-side bridge to the same TS fake ordering service used by the oracle. This actor owns
/// transport callbacks and the received log, but does not assign sequence numbers or author ops.
private actor Ordering {
    private(set) var sequenceNumber: Int
    private var clients: [String: AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error>.Continuation] = [:]
    private(set) var log: [ISequencedDocumentMessage] = []
    private(set) var submitted: [IDocumentMessage] = []
    nonisolated let submitCalls = Mutex(0)

    init(sequenceNumber: Int) { self.sequenceNumber = sequenceNumber }

    func join(_ clientId: String, _ events: AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error>.Continuation) async throws {
        clients[clientId] = events
        try await exchange("join", clientId: clientId)
    }

    func leave(_ clientId: String) async throws {
        guard clients.removeValue(forKey: clientId) != nil else { return }
        try await exchange("leave", clientId: clientId)
    }

    func fault(_ clientId: String, code: Int?, retryAfter: Double = 0) throws {
        if let code {
            let nack = try INack(json: JSON.parse("{\"operation\":{\"clientSequenceNumber\":1,\"referenceSequenceNumber\":0,\"type\":\"op\",\"contents\":null},\"sequenceNumber\":0,\"content\":{\"code\":\(code),\"type\":\"BadRequestError\",\"message\":\"fault\",\"retryAfter\":\(retryAfter)}}"))
            clients[clientId]?.yield(.nack(documentId: "doc", nacks: [nack]))
        } else {
            clients[clientId]?.yield(.disconnect(reason: NetworkError("socket drop", canRetry: true)))
        }
    }

    func receive(_ clientId: String, _ messages: [IDocumentMessage]) async throws {
        submitted.append(contentsOf: messages)
        try await exchange("submit", clientId: clientId, messages: messages)
    }

    private func exchange(_ method: String, clientId: String, messages: [IDocumentMessage] = []) async throws {
        var payload = JSObject<JSONValue>()
        payload["method"] = .string(JSString(method))
        payload["clientId"] = .string(JSString(clientId))
        payload["messages"] = .array(messages.map { .string(JSString(JSON.stringify($0.json))) })
        guard let url = URL(string: "http://127.0.0.1:7090") else { throw JSONDecodingError("fake URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(JSON.stringify(.object(payload)).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw JSONDecodingError(String(decoding: data, as: UTF8.self))
        }
        let operations = try JSON.parse(String(decoding: data, as: UTF8.self)).asArray().map { try ISequencedDocumentMessage(json: $0) }
        let added = operations.filter { $0.sequenceNumber > sequenceNumber }
        log = operations
        sequenceNumber = operations.last?.sequenceNumber ?? sequenceNumber
        for continuation in clients.values {
            if !added.isEmpty { continuation.yield(.op(documentId: "doc", messages: added)) }
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
                do { try await ordering?.receive(clientId, batch) } catch { fatalError(String(describing: error)) }
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
        do { try await ordering?.leave(clientId) } catch { fatalError(String(describing: error)) }
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


private final class FailingStorage: IDocumentStorageService {
    let calls = Mutex(0)
    let failures: Int

    init(failures: Int) { self.failures = failures }

    private func attempt() throws {
        let call = calls.withLock { value in
            value += 1
            return value
        }
        if call <= failures {
            throw NetworkError("503", canRetry: true, retryAfterSeconds: 0.01, endpointReached: true)
        }
    }

    func readBlob(_ id: JSString) async throws -> [UInt8] {
        try attempt()
        return [1, 2, 3]
    }

    func uploadSummaryWithContext(_ summary: SummaryTree, context: ISummaryContext) async throws -> JSString {
        try attempt()
        return "summary"
    }

    func getSnapshotTree(_ version: IVersion?, scenarioName: String?) async throws -> ISnapshotTree? {
        try attempt()
        return nil
    }

    func getVersions(_ versionId: JSString?, count: Int, scenarioName: String?, fetchSource: FetchSource?) async throws -> [IVersion] {
        try attempt()
        return []
    }

    func getSnapshot(_ options: ISnapshotFetchOptions?) async throws -> ISnapshot { throw JSONDecodingError("unused") }
    func createBlob(_ file: [UInt8]) async throws -> ICreateBlobResponse { throw JSONDecodingError("unused") }
    func downloadSummary(_ handle: ISummaryHandle) async throws -> SummaryTree { throw JSONDecodingError("unused") }
}


@main struct ReconnectPeer {
    @MainActor static func main() async {
        let live = LiveHost()
        while let line = readLine() {
            do {
                let request = try JSON.parse(line)
                let result: JSONValue
                if let seed = try request.asObject()["seed"] {
                    result = try await run(seed.asInt())
                } else {
                    result = try await live.handle(request)
                }
                try FileHandle.standardOutput.write(contentsOf: Data((JSON.stringify(result) + "\n").utf8))
            } catch {
                try? FileHandle.standardOutput.write(contentsOf: Data((JSON.stringify(.string(JSString("ERROR: \(error)"))) + "\n").utf8))
            }
        }
    }

    @MainActor static func run(_ seed: Int) async throws -> JSONValue {
        let storageDelays = Mutex<[Double]>([])
        let storage = RetriableDocumentStorageService(FailingStorage(failures: seed % 4 + 1), sleep: { delay in
            storageDelays.withLock { $0.append(delay) }
        })
        _ = try await storage.readBlob("blob")
        let captured = try CapturedSnapshot()
        let ordering = Ordering(sequenceNumber: captured.sequenceNumber)
        let log = CallLog()
        let factory = FakeFactory(policies: nil, log: log, captured: captured, ordering: ordering)
        let delays = Mutex<[Double]>([])
        let container = try Container(
            resolvedUrl: IResolvedUrl(json: JSON.parse(resolvedJSON)), urlResolver: FakeResolver(log: log),
            documentServiceFactory: factory,
            runtimeFactory: createDOProviderContainerRuntimeFactory(schema: ContainerSchema(initialObjects: ["map": SharedMap.self]), oldestSupportedClient: "2.0.0"),
            configProvider: nil, specifiedVersion: nil, clientDetailsOverride: nil, loadRuntime: true, summaryMode: .disabled,
            retryDelay: { delay in
                if delay > 0 { delays.withLock { $0.append(delay) } }
            })
        try await container.open()
        container.start(on: MainActor.shared)
        defer { container.dispose(nil) }
        try await until("initial connection") { container.connectionState == .connected }
        let map = try initialMap(await container.getEntryPoint())
        var events: [String] = []
        container.events.on { event in
            switch event {
            case .connected: events.append("connected")
            case .disconnected:
                events.append("disconnected")
            case .closed: events.append("closed")
            default: break
            }
        }
        try map.set("during", .number(Double(seed)))
        try await until("pending op sent") { await !ordering.submitted.isEmpty }
        let codes: [Int?] = [nil, 400, 401, 403, 404, 429, 500, 503]
        let code = codes[seed % codes.count]
        let retryAfter = Double(seed % 5) / 4
        try await ordering.fault("client-1-1", code: code, retryAfter: retryAfter)
        try await until("recovery") {
            if code == 403 { return container.closed }
            return try container.clientId == "client-1-2" && container.connectionState == .connected && pendingMessages(container) == 0
        }
        var output = JSObject<JSONValue>()
        output["storageDelays"] = .array(storageDelays.withLock { $0 }.map(JSONValue.number))
        output["events"] = .array(events.map { .string(JSString($0)) })
        output["delays"] = .array(delays.withLock { $0 }.map(JSONValue.number))
        var state = JSObject<JSONValue>()
        for (key, value) in map.entries() { state[key] = value ?? .null }
        output["state"] = .object(state)
        output["ops"] = .array(await ordering.submitted.filter { $0.type == "op" }.map { .string(JSString(JSON.stringify($0.json))) })
        return .object(output)
    }
}
