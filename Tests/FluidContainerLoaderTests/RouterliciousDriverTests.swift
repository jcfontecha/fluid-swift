import FluidDriverDefinitions
import FluidJS
import FluidRouterliciousDriver
import FluidTinyliciousDriver
import Foundation
import Synchronization
import Testing

private func message(_ sequenceNumber: Int) throws -> ISequencedDocumentMessage {
    try ISequencedDocumentMessage(json: JSON.parse("""
        {"clientId":null,"sequenceNumber":\(sequenceNumber),"minimumSequenceNumber":0,"clientSequenceNumber":0,\
        "referenceSequenceNumber":0,"type":"noop","timestamp":0}
        """))
}

private func result(_ range: Range<Int>, partial: Bool = false) throws -> IDeltasFetchResult {
    let messages = try range.map { try message($0).json }
    var object = JSObject<JSONValue>()
    object["messages"] = .array(messages)
    object["partialResult"] = .bool(partial)
    return try IDeltasFetchResult(json: .object(object))
}

/// The ranges requestOps asks for, and the canned responses it gets back, in order.
private final class Requests: Sendable {
    private let state: Mutex<(asked: [String], responses: [IDeltasFetchResult])>

    init(_ responses: [IDeltasFetchResult]) { state = Mutex(([], responses)) }

    func next(_ from: Int, _ to: Int) throws -> IDeltasFetchResult {
        try state.withLock { state in
            state.asked.append("\(from)..<\(to)")
            guard !state.responses.isEmpty else { throw JSONDecodingError("unexpected request \(from)..<\(to)") }
            return state.responses.removeFirst()
        }
    }

    var asked: [String] { state.withLock { $0.asked } }
}

private func drain(_ stream: AsyncThrowingStream<[ISequencedDocumentMessage], any Error>) async throws -> [[Int]] {
    var batches: [[Int]] = []
    for try await batch in stream { batches.append(batch.map(\.sequenceNumber)) }
    return batches
}

@Suite("requestOps") struct RequestOpsTests {
    /// parallelRequests.ts: with no known end, a full chunk asks for the next one and a short
    /// non-partial chunk is end of file.
    @Test func unboundedFetchStopsAtTheFirstShortChunk() async throws {
        let requests = Requests([try result(5..<9), try result(9..<11)])
        let stream = requestOps({ try requests.next($0, $1) }, fromTotal: 5, toTotal: nil, payloadSize: 4)
        #expect(try await drain(stream) == [[5, 6, 7, 8], [9, 10]])
        #expect(requests.asked == ["5..<9", "9..<13"])
    }

    /// parallelRequests.ts ParallelRequests_Partial: with a known end, a short chunk never means end
    /// of file; the remaining range is asked again.
    @Test func boundedFetchAsksAgainForTheRestOfAShortChunk() async throws {
        let requests = Requests([try result(10..<11), try result(11..<14)])
        let stream = requestOps({ try requests.next($0, $1) }, fromTotal: 10, toTotal: 14, payloadSize: 10)
        #expect(try await drain(stream) == [[10], [11, 12, 13]])
        #expect(requests.asked == ["10..<14", "11..<14"])
    }

    /// A partial result (deltaStorageService.ts logTail ops) continues from where it ended, even
    /// without a known end.
    @Test func partialResultContinuesWithTheNextChunk() async throws {
        let requests = Requests([try result(3..<4, partial: true), try result(4..<6)])
        let stream = requestOps({ try requests.next($0, $1) }, fromTotal: 3, toTotal: nil, payloadSize: 5)
        #expect(try await drain(stream) == [[3], [4, 5]])
        #expect(requests.asked == ["3..<8", "4..<9"])
    }

    /// getSingleOpBatch: an empty response for a range that must exist is retried after a delay.
    @Test func emptyResponseForAKnownRangeIsRetried() async throws {
        let requests = Requests([try result(7..<7), try result(7..<9)])
        let stream = requestOps({ try requests.next($0, $1) }, fromTotal: 7, toTotal: 9, payloadSize: 10)
        #expect(try await drain(stream) == [[7, 8]])
        #expect(requests.asked == ["7..<9", "7..<9"])
    }

    /// requestOps 0x26d: the first batch must start at fromTotal.
    @Test func batchStartingAfterTheRequestedOpFails() async throws {
        let requests = Requests([try result(6..<8)])
        let stream = requestOps({ try requests.next($0, $1) }, fromTotal: 5, toTotal: nil, payloadSize: 4)
        await #expect(throws: (any Error).self) { _ = try await drain(stream) }
    }

    /// A non-retryable error ends the stream with that error.
    @Test func nonRetryableErrorEndsTheStream() async throws {
        let stream = requestOps({ _, _ in throw JSONDecodingError("broken") }, fromTotal: 1, toTotal: nil, payloadSize: 4)
        await #expect(throws: JSONDecodingError.self) { _ = try await drain(stream) }
    }
}

@Suite("buildGitTreeHierarchy") struct GitTreeHierarchyTests {
    private func flat(_ entries: String) throws -> Git.ITree {
        try Git.ITree(json: JSON.parse(#"{"sha":"root","url":"u","tree":[\#(entries)]}"#))
    }

    /// gitHelper.ts: `.app/` is stripped, path bases are URI-decoded, and blob shas are cached.
    @Test func stripsTheAppPrefixAndDecodesNames() throws {
        let tree = try flat("""
            {"path":".app","mode":"040000","sha":"t-app","size":0,"type":"tree","url":"u"},\
            {"path":".app/a%20b","mode":"040000","sha":"t-ab","size":0,"type":"tree","url":"u"},\
            {"path":".app/a%20b/x","mode":"100644","sha":"b-x","size":0,"type":"blob","url":"u"},\
            {"path":".protocol","mode":"040000","sha":"t-p","size":0,"type":"tree","url":"u"},\
            {"path":".protocol/attributes","mode":"100644","sha":"b-attr","size":0,"type":"blob","url":"u"}
            """)
        var cache: [String: String] = [:]
        let hierarchy = try buildGitTreeHierarchy(tree, blobsShaToPathCache: &cache, removeAppTreePrefix: true)
        #expect(hierarchy.id == "root")
        #expect(hierarchy.trees.keys.map(\.description) == [".app", "a b", ".protocol"])
        #expect(hierarchy.trees["a b"]?.blobs["x"] == "b-x")
        #expect(hierarchy.trees[".protocol"]?.blobs["attributes"] == "b-attr")
        #expect(cache == ["b-x": "/a%20b/x", "b-attr": "/.protocol/attributes"])
    }

    @Test func rejectsUnknownEntryTypes() throws {
        let tree = try flat(#"{"path":"sub","mode":"160000","sha":"c","size":0,"type":"commit","url":"u"}"#)
        var cache: [String: String] = [:]
        #expect(throws: (any Error).self) { _ = try buildGitTreeHierarchy(tree, blobsShaToPathCache: &cache, removeAppTreePrefix: true) }
    }
}

@Suite("RouterliciousDocumentServiceFactory") struct RouterliciousFactoryTests {
    private func resolved(_ url: String) throws -> IResolvedUrl {
        try IResolvedUrl(json: JSON.parse("""
            {"type":"fluid","id":"doc","url":"\(url)","tokens":{},"endpoints":{"deltaStorageUrl":"http://localhost:7070/deltas/tinylicious/doc",\
            "ordererUrl":"http://localhost:7070","storageUrl":"http://localhost:7070/repos/tinylicious"}}
            """))
    }

    /// documentServiceFactory.ts: tenant and document come from the resolved URL's path.
    @Test func documentServiceTakesTenantAndDocumentFromTheResolvedUrl() async throws {
        let factory = RouterliciousDocumentServiceFactory(tokenProvider: InsecureTinyliciousTokenProvider())
        let service = try await factory.createDocumentService(
            resolved("http://localhost:7070/tinylicious/doc"), clientIsSummarizer: false)
        let routerlicious = try #require(service as? DocumentService)
        #expect(routerlicious.tenantId == "tinylicious")
        #expect(routerlicious.documentId == "doc")
        // documentService.ts: policies stay undefined until a delta connection reports its features.
        #expect(service.policies == nil)
        let storage = try await service.connectToStorage()
        #expect(try await service.connectToStorage() === storage)
    }

    @Test func documentServiceRejectsAUrlWithoutDocument() async throws {
        let factory = RouterliciousDocumentServiceFactory(tokenProvider: InsecureTinyliciousTokenProvider())
        await #expect(throws: (any Error).self) {
            _ = try await factory.createDocumentService(self.resolved("http://localhost:7070/tinylicious"), clientIsSummarizer: false)
        }
    }

    /// shreddedSummaryDocumentStorageService.ts has no getSnapshot, so documentStorageServiceProxy.ts
    /// throws a UsageError; downloadSummary is not implemented.
    @Test func shreddedStorageHasNoGetSnapshotOrDownloadSummary() async throws {
        let factory = RouterliciousDocumentServiceFactory(tokenProvider: InsecureTinyliciousTokenProvider())
        let service = try await factory.createDocumentService(
            resolved("http://localhost:7070/tinylicious/doc"), clientIsSummarizer: false)
        let storage = try await service.connectToStorage()
        await #expect {
            _ = try await storage.getSnapshot(nil)
        } throws: { error in
            String(describing: error) == "getSnapshot api should exist on internal storage in documentStorageServiceProxy class"
        }
        let handle = try ISummaryHandle(json: JSON.parse(#"{"type":3,"handleType":1,"handle":"h"}"#))
        await #expect {
            _ = try await storage.downloadSummary(handle)
        } throws: { error in
            String(describing: error) == "NOT IMPLEMENTED!"
        }
    }

    /// specs/routerlicious-driver.md connect_document literal, before driver-base appends
    /// supportedFeatures.
    @Test func connectMessageMatchesTheDocumentedLiteral() throws {
        let client = try IClient(json: JSON.parse(
            #"{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"user":{"id":"u"},"scopes":[]}"#))
        let connect = try R11sDocumentDeltaConnection.connectMessage(tenantId: "t", id: "doc", token: "jwt", client: client)
        #expect(JSON.stringify(connect.json) == #"{"client":{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"user":{"id":"u"},"scopes":[]},"id":"doc","mode":"write","tenantId":"t","token":"jwt","versions":["^0.4.0","^0.3.0","^0.2.0","^0.1.0"],"relayUserAgent":"; driverVersion:3.11.0"}"#)
    }
}
