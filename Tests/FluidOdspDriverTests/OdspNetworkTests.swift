import FluidDriverUtils
import Foundation
import FluidDriverDefinitions
import Synchronization
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
        let connection = OdspDocumentDeltaConnectionState(reference: reference, documentId: "doc", clientId: "client", noncePrefix: "n")
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
        #expect(try OdspDocumentDeltaConnectionState.enableMultiplexing("https://relay/?documentId=") == false)
        #expect(try OdspDocumentDeltaConnectionState.enableMultiplexing("https://relay/") == true)
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
        cache.put(docId: "d", key: "ops", entry: .init(value: .json(.string("ops")), fluidEpoch: "E"), now: 0)
        #expect(cache.get(docId: "d", key: "ops", now: 3599999) != nil)
        #expect(cache.get(docId: "d", key: "ops", now: 3600000) == nil)
    }
}

struct OdspDeltaCacheTests {
    @Test func cacheMissDisablesFurtherReads() async throws {
        let counts = Mutex((reads: 0, storageReads: 0, socketRequests: 0))
        let service = OdspDeltaStorageWithCache(snapshotOps: nil, batchSize: 5000, concurrency: 1, getFromStorage: { _, _, _ in
            counts.withLock { $0.storageReads += 1 }
            return .init(messages: [], partialResult: false)
        }, getCached: { _, _ in
            counts.withLock { $0.reads += 1 }
            return []
        }, requestFromSocket: { _, _ in counts.withLock { $0.socketRequests += 1 } }, opsReceived: { _ in }, storageManagerGetter: { nil })
        _ = try await service.requestCallback(from: 1, to: 3, cachedOnly: false, fetchReason: nil)
        _ = try await service.requestCallback(from: 3, to: 5, cachedOnly: false, fetchReason: nil)
        let final = counts.withLock { $0 }
        // The first miss turns the cache off for the rest of the fetch.
        #expect(final.reads == 1)
        #expect(final.storageReads == 2)
        #expect(final.socketRequests == 2)
    }

    /// driver-base validateMessages (strict): a gap drops the whole batch instead of failing.
    @Test func nonContiguousBatchIsDropped() throws {
        var messages = [try JSON.parse("{\"sequenceNumber\":1}"), try JSON.parse("{\"sequenceNumber\":3}")]
        try validateMessages(&messages, from: 1)
        #expect(messages.isEmpty)
    }

    /// requestOps over an empty fixed range fails 0x270 ("All requested ops fetched"), as in TS.
    @Test func emptyFixedRangeFailsAllFetchedAssert() async throws {
        let stream = requestOps(concurrency: 1, fromTotal: 5, toTotal: 5, payloadSize: 5000) { _, _ in ([], false) }
        await #expect(throws: JSONDecodingError.self) {
            for try await _ in stream {}
        }
    }

    /// An open-ended fetch ends at the first short, non-partial batch.
    @Test func openEndedFetchStopsAtShortBatch() async throws {
        let stream = requestOps(concurrency: 1, fromTotal: 1, toTotal: nil, payloadSize: 2) { from, to in
            let available = Array(from..<min(to, 4))
            return (try available.map { try JSON.parse("{\"sequenceNumber\":\($0)}") }, false)
        }
        var batches: [[JSONValue]] = []
        for try await batch in stream { batches.append(batch) }
        #expect(batches.map(\.count) == [2, 1])
    }
}

struct OdspSummaryTests {
    @Test func protocolAloneIsNotCombinedSummary() async throws {
        let resolved = try OdspDriverUrlResolver().resolve("https://t.sharepoint.com/?driveId=d&itemId=i&path=")
        let body = Mutex<JSONValue?>(nil)
        let network = OdspNetwork(resolvedUrl: resolved, epochTracker: EpochTracker(), tokenFetcher: { _ in .token("token") }, send: { request in
            let parsed = try JSON.parse(String(decoding: request.body, as: UTF8.self))
            body.withLock { $0 = parsed }
            return OdspResponse(status: 200, headers: [:], body: Data("{\"id\":\"proposal\"}".utf8))
        })
        let upload = OdspSummaryUploadManager(snapshotStorageUrl: resolved.snapshotStorageUrl, network: network)
        let tree = try ISummaryTree(json: JSON.parse("{\"type\":1,\"tree\":{\".protocol\":{\"type\":1,\"tree\":{}}}}"))
        let context = try ISummaryContext(json: JSON.parse("{\"ackHandle\":\"parent\",\"referenceSequenceNumber\":0}"))
        #expect(try await upload.writeSummaryTree(tree, context: context, relayServiceTenantAndSessionId: nil) == "proposal")
        #expect(try body.withLock { $0 }?.member("type") == .string("channel"))
    }
}

private let reviewResolvedUrl = "https://contoso.sharepoint.com/?driveId=d&itemId=i&path="
private let emptyJSONSnapshot = #"{"trees":[{"id":"root","sequenceNumber":0,"entries":[]}],"blobs":[],"ops":[]}"#

struct OdspEpochMismatchTests {
    /// epochTracker.ts:234-242 validateEpoch and :467-499 checkForEpochError: a mismatch awaits
    /// removeEntries (whose failure is only logged) before the epoch error is rethrown.
    @Test func validateEpochClearsCacheBeforeRethrowing() async throws {
        let removals = Mutex(0)
        let tracker = EpochTracker(cacheRemove: {
            removals.withLock { $0 += 1 }
            throw JSONDecodingError("cache removal failed")
        })
        try await tracker.validateEpoch("E", fetchType: .treesLatest)
        #expect(removals.withLock { $0 } == 0)
        do {
            try await tracker.validateEpoch("F", fetchType: .push)
            Issue.record("expected an epoch mismatch")
        } catch let error as OdspNetworkError {
            #expect(error.errorType == "fileOverwrittenInStorage")
            #expect(!error.canRetry)
        }
        #expect(removals.withLock { $0 } == 1)
        #expect(tracker.cacheClearCount == 1)
        #expect(tracker.fluidEpoch == "E")
    }

    /// odspDocumentStorageManager.ts:603: the prefetched snapshot's epoch goes through
    /// `await epochTracker.validateEpoch`, so a mismatch clears the cache before the network fetch.
    @Test func prefetchEpochMismatchClearsCache() async throws {
        let removals = Mutex(0)
        let tracker = EpochTracker(cacheRemove: { removals.withLock { $0 += 1 } })
        try tracker.validateEpoch("A")
        let resolved = try OdspDriverUrlResolver().resolve(reviewResolvedUrl)
        let responses = Mutex(["B", "A"])
        let network = OdspNetwork(resolvedUrl: resolved, epochTracker: tracker, tokenFetcher: { _ in .token("t") }, send: { _ in
            let epoch = responses.withLock { $0.removeFirst() }
            return OdspResponse(status: 200, headers: ["content-type": "application/json", "x-fluid-epoch": epoch], body: Data(emptyJSONSnapshot.utf8))
        })
        let storage = OdspDocumentStorageService(network: network, flushCallback: { .null }, relayServiceTenantAndSessionId: { nil })
        #expect(await storage.prefetchLatestSnapshot().value)
        _ = try await storage.fetchSnapshot(fetchSource: nil, loadingGroupIds: nil)
        #expect(removals.withLock { $0 } == 1)
        #expect(responses.withLock { $0 }.isEmpty)
    }
}

struct OdspDeltaFetchCancellationTests {
    /// parallelRequests.ts:434 and :617: once the consumer aborts, getSingleOpBatch stops retrying
    /// and the manager is cancelled; an offline fetch makes no further requests.
    @Test func offlineRetryStopsWhenTheConsumerCancels() async throws {
        let calls = Mutex(0)
        let storage = OdspDeltaStorageWithCache(snapshotOps: nil, batchSize: 10, concurrency: 1, getFromStorage: { _, _, _ in
            calls.withLock { $0 += 1 }
            throw OdspNetworkError("fetchFailure", canRetry: true)
        }, getCached: { _, _ in [] }, requestFromSocket: { _, _ in }, opsReceived: { _ in }, storageManagerGetter: { nil })
        let consumer = Task {
            for try await _ in storage.fetchMessages(1, to: 5, cachedOnly: false, fetchReason: nil) {}
        }
        while calls.withLock({ $0 }) == 0 { await Task.yield() }
        consumer.cancel()
        _ = await consumer.result
        // Without cancellation the retries run at 100, 300 and 700 ms.
        try await Task.sleep(for: .milliseconds(800))
        #expect(calls.withLock { $0 } == 1)
    }
}

struct OdspRedemptionTests {
    /// epochTracker.ts:524-536 and :553-571: a snapshot served from cache completes the redemption
    /// deferral, so a 401-404 joinSession afterwards fails at once (:585-610): one request, no wait.
    @Test func joinSessionFailureAfterCacheHitFailsImmediately() async throws {
        let joins = Mutex(0)
        let waits = Mutex(0)
        let tracker = EpochTrackerWithRedemption(sleep: { _ in waits.withLock { $0 += 1 } })
        let resolved = try OdspDriverUrlResolver().resolve(reviewResolvedUrl)
        let network = OdspNetwork(resolvedUrl: resolved, epochTracker: tracker, tokenFetcher: { _ in .token("t") }, send: { _ in
            joins.withLock { $0 += 1 }
            return OdspResponse(status: 403, headers: [:], body: Data())
        })
        let snapshot = CompactSnapshot(snapshotTree: CompactSnapshotTree(id: "root"), blobContents: JSMap(), ops: [], sequenceNumber: 0, latestSequenceNumber: 0)
        let cached = OdspDocumentStorageService.CachedSnapshot(snapshot: snapshot, fluidEpoch: "E", cacheEntryTime: Date().timeIntervalSince1970 * 1000)
        let storage = OdspDocumentStorageService(network: network, cacheRead: { cached }, flushCallback: { .null }, relayServiceTenantAndSessionId: { nil })
        _ = try await storage.fetchSnapshot(fetchSource: nil, loadingGroupIds: nil)
        #expect(joins.withLock { $0 } == 0)
        do {
            _ = try await fetchJoinSession(resolved: resolved, network: network)
            Issue.record("expected the join session to fail")
        } catch let error as OdspNetworkError {
            #expect(error.statusCode == 403)
        }
        #expect(joins.withLock { $0 } == 1)
        #expect(waits.withLock { $0 } == 0)
    }
}
