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

private final class FakeDeltaStorage: IDocumentDeltaStorageService {
    let log: CallLog

    init(log: CallLog) { self.log = log }

    func fetchMessages(_ from: Int, to: Int?, cachedOnly: Bool, fetchReason: String?)
        -> AsyncThrowingStream<[ISequencedDocumentMessage], any Error>
    {
        log.append("fetchMessages(\(from),\(to.map(String.init) ?? "nil"))")
        return AsyncThrowingStream { $0.finish() }
    }
}

private final class FakeDeltaConnection: IDocumentDeltaConnection {
    let details: IConnected
    let events: AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error>
    private let continuation: AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error>.Continuation

    init(clientId: String) throws {
        details = try IConnected(json: JSON.parse("""
            {"claims":{"documentId":"doc","scopes":["doc:read","doc:write"],"tenantId":"fake","user":{"id":"u"},"iat":0,"exp":0,"ver":"1.0"},\
            "clientId":"\(clientId)","existing":true,"maxMessageSize":16384,"initialMessages":[],"initialSignals":[],"initialClients":[],\
            "version":"^0.4.0","supportedVersions":["^0.4.0"],"serviceConfiguration":{"maxMessageSize":16384,"blockSize":65436},"mode":"write"}
            """))
        (events, continuation) = AsyncThrowingStream.makeStream()
    }

    func submit(_ messages: [IDocumentMessage]) async throws {}

    func submitSignal(_ content: String, targetClientId: String?) async throws {}

    func dispose() async { continuation.finish() }
}

private final class FakeService: IDocumentService {
    let resolvedUrl: IResolvedUrl
    let policies: IDocumentServicePolicies?
    let log: CallLog
    let captured: CapturedSnapshot
    let clientId: String

    init(resolvedUrl: IResolvedUrl, policies: IDocumentServicePolicies?, log: CallLog, captured: CapturedSnapshot, clientId: String) {
        self.resolvedUrl = resolvedUrl
        self.policies = policies
        self.log = log
        self.captured = captured
        self.clientId = clientId
    }

    func connectToStorage() async throws -> any IDocumentStorageService {
        log.append("connectToStorage")
        return FakeStorage(log: log, captured: captured)
    }

    func connectToDeltaStorage() async throws -> any IDocumentDeltaStorageService {
        log.append("connectToDeltaStorage")
        return FakeDeltaStorage(log: log)
    }

    func connectToDeltaStream(_ client: IClient) async throws -> any IDocumentDeltaConnection {
        log.append("connectToDeltaStream(\(JSON.stringify(client.json)))")
        return try FakeDeltaConnection(clientId: clientId)
    }

    func dispose(_ error: (any Error)?) {}
}

private final class FakeFactory: IDocumentServiceFactory {
    let policies: IDocumentServicePolicies?
    let log: CallLog
    let captured: CapturedSnapshot
    private let services = Mutex(0)

    init(policies: IDocumentServicePolicies?, log: CallLog, captured: CapturedSnapshot) {
        self.policies = policies
        self.log = log
        self.captured = captured
    }

    func createDocumentService(_ resolvedUrl: IResolvedUrl, clientIsSummarizer: Bool) async throws -> any IDocumentService {
        log.append("createDocumentService(\(JSON.stringify(resolvedUrl.json)),\(clientIsSummarizer))")
        let index = services.withLock { count in
            count += 1
            return count
        }
        return FakeService(resolvedUrl: resolvedUrl, policies: policies, log: log, captured: captured, clientId: "client-\(index)")
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

/// The fluid-static entry point's "map" entries.
private func mapEntries(_ container: Container) async throws -> JSONValue {
    try await container.withEntryPoint { entryPoint in
        guard let root = entryPoint as? RootDataObject, let map = root.initialObjects["map"] as? SharedMap else {
            throw JSONDecodingError("initialObject is not a SharedMap")
        }
        var values = JSObject<JSONValue>()
        for (key, value) in map.entries() { values[key] = value ?? .null }
        return .object(values)
    }
}

private let capturedValue = #"{"seed":0,"nested":[null,true,"hello"]}"#

@Suite("loadExistingContainer") struct LoadExistingContainerTests {
    /// serializedStateManager.ts fetchISnapshotTree: without supportGetSnapshotApi the loader asks for
    /// the latest version, then its tree, and reads every blob through storage.
    @Test func loadsThroughVersionsAndSnapshotTreeWithoutGetSnapshotSupport() async throws {
        let log = CallLog()
        let captured = try CapturedSnapshot()
        let container = try await loadExistingContainer(props(FakeFactory(policies: nil, log: log, captured: captured), log))
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
        await container.disconnect()
    }

    /// container.ts supportGetSnapshotApi also needs the UseLoadingGroupIdForSnapshotFetch2 gate:
    /// without it a service that supports getSnapshot still loads through getVersions.
    @Test func getSnapshotSupportAloneStillLoadsThroughVersions() async throws {
        let log = CallLog()
        let captured = try CapturedSnapshot()
        let factory = FakeFactory(policies: IDocumentServicePolicies(supportGetSnapshotApi: true), log: log, captured: captured)
        let container = try await loadExistingContainer(props(factory, log))
        let calls = log.all
        #expect(calls.contains("getVersions(nil,1)"))
        #expect(!calls.contains { $0.hasPrefix("getSnapshot(") })
        await container.disconnect()
    }

    /// serializedStateManager.ts fetchISnapshot: with supportGetSnapshotApi and its gate the loader
    /// issues one getSnapshot and takes the runtime's blobs from ISnapshot.blobContents.
    @Test func loadsThroughGetSnapshotWhenTheServiceSupportsItAndTheGateIsOn() async throws {
        let log = CallLog()
        let captured = try CapturedSnapshot()
        let factory = FakeFactory(policies: IDocumentServicePolicies(supportGetSnapshotApi: true), log: log, captured: captured)
        let container = try await loadExistingContainer(props(factory, log, gates: [snapshotFetchGate]))
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
        await container.disconnect()
    }

    /// loader.ts RelativeLoader + container.ts clone: the summarizer reuses the resolved URL and the
    /// document service factory, with summarizer client details, and never re-resolves.
    @Test func summarizerChildReusesTheResolvedUrlAndFactory() async throws {
        let log = CallLog()
        let captured = try CapturedSnapshot()
        let container = try await loadExistingContainer(props(FakeFactory(policies: nil, log: log, captured: captured), log))
        await #expect(throws: (any Error).self) { _ = try await container.summarize() }
        let calls = log.all
        #expect(calls.filter { $0.hasPrefix("resolve(") }.count == 1)
        #expect(calls.filter { $0.hasPrefix("createDocumentService(") } == [
            "createDocumentService(\(resolvedJSON),false)",
            "createDocumentService(\(resolvedJSON),true)",
        ])
        #expect(calls.contains("connectToDeltaStream(\(summarizerClient))"))
        await container.disconnect()
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
