import Foundation
import FluidDriverDefinitions
import Testing
import FluidJS
@testable import FluidOdspDriver

struct OdspNetworkTests {
    @Test func retryAfterUsesMilliseconds() throws {
        let error = try createOdspNetworkError(status: 429, headers: ["retry-after": "2.5"])
        #expect(error.errorType == "throttlingError")
        #expect(error.retryAfterMs == 2500)
    }

    @Test func claimsChallenge() throws {
        let header = "Bearer realm=\"tenant\", error=\"insufficient_claims\", claims=\"eyJhIjoxfQ==\""
        #expect(try parseAuthErrorClaims(header) == "{\"a\":1}")
        #expect(try parseAuthErrorTenant(header) == "tenant")
    }

    @Test func epochCoherencyIsNotOverwrite() throws {
        let tracker = EpochTracker()
        try tracker.validateEpoch("E")
        let coherent = try tracker.classify(status: 409, headers: ["x-fluid-epoch": "E"])
        #expect(coherent.odsp409Error)
        #expect(coherent.retryAfterMs == 1000)
        #expect(coherent.canRetry)
        let overwritten = try tracker.classify(status: 409, headers: ["x-fluid-epoch": "F"])
        #expect(overwritten.errorType == "fileOverwrittenInStorage")
        #expect(!overwritten.canRetry)
        #expect(tracker.cacheClearCount == 1)
        #expect(tracker.fluidEpoch == "E")
    }

    @Test func opsCacheStopsAtHole() throws {
        let cache = OpsCache(startingSequenceNumber: 0, batchSize: 3, totalOpsToCache: 100)
        try cache.addOps([JSON.parse("{\"sequenceNumber\":1}"), JSON.parse("{\"sequenceNumber\":2}"), JSON.parse("{\"sequenceNumber\":3}"), JSON.parse("{\"sequenceNumber\":5}")])
        cache.flushOps()
        #expect(try cache.get(from: 1, to: 6).count == 3)
        #expect(cache.persisted["3_1"] == "[{\"sequenceNumber\":3},null,{\"sequenceNumber\":5}]")
    }
}

struct OdspRetryTests {
    @Test func coherencyRetryIsBounded() async throws {
        var calls = 0
        var waits: [Double] = []
        do {
            let _: Int = try await runWithRetry(sleep: { waits.append($0) }, random: { 0 }) {
                calls += 1
                var error = OdspNetworkError("throttlingError", canRetry: true, statusCode: 409)
                error.odsp409Error = true
                error.retryAfterMs = 1000
                throw error
            }
            Issue.record("expected failure")
        } catch let error as OdspNetworkError {
            #expect(!error.canRetry)
        }
        #expect(calls == 5)
        #expect(waits == [1000, 1000, 1000, 1000])
    }

    @Test func genericThrottleIsNotRetried() async throws {
        var calls = 0
        do {
            let _: Int = try await runWithRetry(sleep: { _ in Issue.record("unexpected wait") }, random: { 0 }) {
                calls += 1
                throw OdspNetworkError("throttlingError", canRetry: true, statusCode: 429)
            }
        } catch let error as OdspNetworkError { #expect(error.canRetry) }
        #expect(calls == 1)
    }

    @Test func tokenRefreshAtMostOnce() async throws {
        var calls: [Bool] = []
        do {
            let _: Int = try await getWithRetryForTokenRefresh { options in
                calls.append(options.refresh)
                throw OdspNetworkError("authorizationError", canRetry: false, statusCode: 401)
            }
        } catch let error as OdspNetworkError { #expect(error.statusCode == 401) }
        #expect(calls == [false, true])
    }
}

struct OdspSocketTests {
    @Test func synchronousDisconnectInvalidatesBeforeNotification() throws {
        var closed = false
        let reference = SocketReference(key: "relay", send: { _, _ in }, close: { closed = true })
        reference.connected = true
        let connection = OdspDocumentDeltaConnection(reference: reference, documentId: "doc", clientId: "client", noncePrefix: "n")
        var observedDisposed = false
        connection.onDisconnect = {
            observedDisposed = connection.disposed && reference.disconnected
        }
        try reference.closeSocket()
        #expect(observedDisposed)
        #expect(closed)
        #expect(reference.references == 0)
    }

    @Test func multiplexingUsesPresenceNotTruthiness() throws {
        #expect(try OdspDocumentDeltaConnection.enableMultiplexing("https://relay/?documentId=") == false)
        #expect(try OdspDocumentDeltaConnection.enableMultiplexing("https://relay/") == true)
    }
}

struct OdspURLAndSnapshotTests {
    @Test func internalURLRoundTripAndConsumerRoot() throws {
        let resolver = OdspDriverUrlResolver()
        let resolved = try resolver.resolve(createOdspUrl(siteUrl: "https://t.sharepoint.com/sites/a", driveId: "Drive", itemId: "Item", dataStorePath: "/store?x=1", fileVersion: "v"))
        #expect(resolved.snapshotStorageUrl == "https://t.sharepoint.com/_api/v2.1/drives/Drive/items/Item/versions/v/opStream/snapshots")
        #expect(resolved.dataStorePath == "/store?x=1")
        #expect(try getApiRoot("https://onedrive.com/site") == "https://onedrive.com/v2.1")
        #expect(!resolved.hashedDocumentId.contains("/"))
    }

    @Test func jsonSnapshotBreadthFirstHierarchy() throws {
        let input = try JSON.parse("{\"trees\":[{\"id\":\"root\",\"sequenceNumber\":7,\"entries\":[{\"path\":\"a\",\"type\":\"tree\",\"groupId\":\"g\"},{\"path\":\"a/b\",\"type\":\"blob\",\"id\":\"b\"}]}],\"blobs\":[{\"id\":\"b\",\"content\":\"AP8=\",\"encoding\":\"base64\"}],\"ops\":[{\"sequenceNumber\":8,\"op\":{\"sequenceNumber\":8}}]}")
        let snapshot = try convertOdspSnapshotToSnapshotTreeAndBlobs(input)
        #expect(snapshot.sequenceNumber == 7)
        #expect(snapshot.latestSequenceNumber == 8)
        #expect(snapshot.snapshotTree.trees["a"]?.groupId == "g")
        #expect(snapshot.snapshotTree.trees["a"]?.blobs["b"] == "b")
        #expect(snapshot.blobContents.get("b") == .buffer([0, 255][...]))
    }

    @Test func localCacheExpiresOnlyFromPut() {
        let cache = LocalPersistentCache()
        cache.put(docId: "d", key: "ops", entry: .init(value: .string("ops"), fluidEpoch: "E"), now: 0)
        #expect(cache.get(docId: "d", key: "ops", now: 3599999) != nil)
        #expect(cache.get(docId: "d", key: "ops", now: 3600000) == nil)
    }
}

struct OdspDeltaCacheTests {
    @Test func cacheMissDisablesFurtherReads() async throws {
        var reads = 0
        var storageReads = 0
        var socketRequests = 0
        let service = OdspDeltaStorageWithCache(snapshotOps: nil, getFromStorage: { _, _ in
            storageReads += 1
            return .init(messages: [], partialResult: false)
        }, getCached: { _, _ in
            reads += 1
            return []
        }, requestFromSocket: { _, _ in socketRequests += 1 }, opsReceived: { _ in })
        service.beginFetch(isFirstSnapshotFromNetwork: false)
        _ = try await service.fetchMessages(from: 1, to: 3)
        _ = try await service.fetchMessages(from: 3, to: 5)
        #expect(reads == 1)
        #expect(storageReads == 2)
        #expect(socketRequests == 2)
    }
}

struct OdspSummaryTests {
    @Test func protocolAloneIsNotCombinedSummary() async throws {
        let resolved = try OdspDriverUrlResolver().resolve("https://t.sharepoint.com/?driveId=d&itemId=i&path=")
        var body: JSONValue?
        let network = OdspNetwork(resolvedUrl: resolved, epochTracker: EpochTracker(), tokenFetcher: { _ in .token("token") }, send: { request in
            body = try JSON.parse(String(decoding: request.body, as: UTF8.self))
            return OdspResponse(status: 200, headers: [:], body: Data("{\"id\":\"proposal\"}".utf8))
        })
        let upload = OdspSummaryUploadManager(snapshotStorageUrl: resolved.snapshotStorageUrl, network: network)
        let tree = try ISummaryTree(json: JSON.parse("{\"type\":1,\"tree\":{\".protocol\":{\"type\":1,\"tree\":{}}}}"))
        let context = try ISummaryContext(json: JSON.parse("{\"ackHandle\":\"parent\",\"referenceSequenceNumber\":0}"))
        #expect(try await upload.writeSummaryTree(tree, context: context) == "proposal")
        #expect(try body?.member("type") == .string("channel"))
    }
}
