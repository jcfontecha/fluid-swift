import FluidDriverDefinitions
import FluidJS
import Foundation

/// odspDocumentStorageManager.ts OdspDocumentStorageService. The base-class members
/// (odspDocumentStorageServiceBase.ts) are in OdspDocumentStorageServiceBase.swift. Native
/// snapshots retain byte slices and maps in cache.
public actor OdspDocumentStorageService: IDocumentStorageService {
    public struct CachedSnapshot: Sendable {
        public let snapshot: CompactSnapshot
        public let fluidEpoch: String
        public let cacheEntryTime: Double?
        public let version: Int
        public init(snapshot: CompactSnapshot, fluidEpoch: String, cacheEntryTime: Double? = nil, version: Int = 3) {
            self.snapshot = snapshot
            self.fluidEpoch = fluidEpoch
            self.cacheEntryTime = cacheEntryTime
            self.version = version
        }
    }
    /// TS `defaultSummarizerCacheExpiryTimeout`.
    static let defaultSummarizerCacheExpiryTimeout = 60000.0
    public private(set) var firstSnapshotFetchCall = true
    public private(set) var isFirstSnapshotFromNetwork: Bool?
    /// The snapshot's ops from the first fetch (`undefined` until then).
    public internal(set) var ops: [JSONValue]?
    public internal(set) var snapshotSequenceNumber: Int?
    var commitCache: [JSString: CompactSnapshotTree] = [:]
    var blobCache = BlobCache()
    public var persistedSnapshot: CachedSnapshot?
    private typealias PrefetchResult = (snapshot: CachedSnapshot, persisted: Task<Void, Error>)
    private var prefetchedSnapshot: Task<PrefetchResult, Error>?
    private var prefetchEviction: Task<Void, Never>?
    private let sleep: @Sendable (Double) async throws -> Void
    public var hasPrefetchedSnapshot: Bool { prefetchedSnapshot != nil }
    public var onPrefetchError: @Sendable (Error) -> Void = { _ in }
    public var onCacheReadError: @Sendable (Error) -> Void = { _ in }
    public var onCacheWriteError: @Sendable (Error) -> Void = { _ in }
    public var now: @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }
    private let network: OdspNetwork
    private let documentId: String
    let snapshotUrl: String
    private let attachmentPOSTUrl: String
    private let attachmentGETUrl: String
    private let summarizerClient: Bool
    private let hostSnapshotOptions: JSObject<JSONValue>
    private let concurrentSnapshotFetch: Bool
    private let cacheRead: (@Sendable () async throws -> CachedSnapshot?)?
    private let cachePut: (@Sendable (CachedSnapshot) async throws -> Void)?
    private let flushCallback: @Sendable () async throws -> JSONValue
    private let relayServiceTenantAndSessionId: @Sendable () async -> String?
    private var odspSummaryUploadManager: OdspSummaryUploadManager?
    /// Limits parallel attachment blob uploads.
    private let createBlobRateLimiter = RateLimiter(1)

    public init(network: OdspNetwork, summarizerClient: Bool = false, hostSnapshotOptions: JSObject<JSONValue> = .init(), concurrentSnapshotFetch: Bool = false, cacheRead: (@Sendable () async throws -> CachedSnapshot?)? = nil, cachePut: (@Sendable (CachedSnapshot) async throws -> Void)? = nil, flushCallback: @escaping @Sendable () async throws -> JSONValue, relayServiceTenantAndSessionId: @escaping @Sendable () async -> String?, sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) }) {
        self.network = network
        let resolved = network.resolvedUrl
        documentId = resolved.hashedDocumentId
        snapshotUrl = resolved.snapshotStorageUrl
        attachmentPOSTUrl = resolved.attachmentPOSTStorageUrl
        attachmentGETUrl = resolved.attachmentGETStorageUrl
        self.summarizerClient = summarizerClient
        self.hostSnapshotOptions = hostSnapshotOptions
        self.concurrentSnapshotFetch = concurrentSnapshotFetch
        self.cacheRead = cacheRead
        self.cachePut = cachePut
        self.flushCallback = flushCallback
        self.relayServiceTenantAndSessionId = relayServiceTenantAndSessionId
        self.sleep = sleep
    }

    public func createBlob(_ file: [UInt8]) async throws -> ICreateBlobResponse {
        guard !attachmentPOSTUrl.isEmpty else { throw OdspNetworkError("genericError", canRetry: false) }
        let url = attachmentPOSTUrl + "/content"
        let limiter = createBlobRateLimiter
        let response = try await network.authorized(url: url, make: { auth, _ in
            var headers = try getHeadersWithAuth(auth)
            headers["Content-Type"] = "application/octet-stream"
            return OdspRequest(url: url, headers: headers, body: Data(file), timeoutMs: nil, fetchType: .createBlob)
        }, fetchResponse: { request in
            await limiter.acquire()
            do {
                let response = try await self.network.fetch(request)
                await limiter.release()
                return response
            } catch {
                await limiter.release()
                throw error
            }
        })
        return try ICreateBlobResponse(json: response.json())
    }

    func fetchBlobFromStorage(_ blobId: JSString, evicted: Bool) async throws -> [UInt8] {
        guard !attachmentGETUrl.isEmpty else { throw OdspNetworkError("genericError", canRetry: false) }
        let url = attachmentGETUrl + "/" + encodeOdspComponent(blobId.description) + "/content"
        let response = try await network.authorized(url: url, method: "GET") { auth, _ in
            OdspRequest(url: url, method: "GET", headers: try getHeadersWithAuth(auth), timeoutMs: nil, fetchType: .blob)
        }
        let blob = Array(response.body)
        blobCache.setBlob(blobId, blob)
        return blob
    }

    /// The snapshot for all ungrouped data unless loading groups are requested; a loading-group
    /// fetch never consults the cache.
    public func getSnapshot(_ options: ISnapshotFetchOptions?) async throws -> ISnapshot {
        let loadingGroupIds = options?.loadingGroupIds?.map(\.description)
        let groupFetch = loadingGroupIds.map { !$0.isEmpty } ?? false
        let (snapshot, _) = try await fetchSnapshot(fetchSource: groupFetch ? .noCache : options?.fetchSource, loadingGroupIds: loadingGroupIds ?? [], cacheSnapshot: options?.cacheSnapshot, scenarioName: options?.scenarioName?.description)
        var buffers = JSObject<[UInt8]>()
        for (id, content) in snapshot.blobContents.entries { buffers[id] = try content.bytes() }
        return ISnapshot(
            snapshotTree: try ISnapshotTree(json: combineProtocolAndAppSnapshotTree(snapshot.snapshotTree)),
            blobContents: SnapshotBlobContents(buffers: buffers),
            ops: try snapshot.ops.map { try ISequencedDocumentMessage(json: $0) },
            sequenceNumber: snapshot.sequenceNumber,
            latestSequenceNumber: snapshot.latestSequenceNumber)
    }

    /// TS private `fetchSnapshot`: cache and network per policy, then `initializeFromSnapshot`.
    public func fetchSnapshot(fetchSource: FetchSource?, loadingGroupIds: [String]?, cacheSnapshot: Bool? = nil, scenarioName: String? = nil) async throws -> (snapshot: CompactSnapshot, id: JSString?) {
        let (retrieved, fromCache) = try await obtainSnapshot(fetchSource: fetchSource, loadingGroupIds: loadingGroupIds, scenarioName: scenarioName)
        if firstSnapshotFetchCall { isFirstSnapshotFromNetwork = !fromCache }
        // Don't override ops fetched during initial load: they may still be needed.
        let id = try initializeFromSnapshot(retrieved, cacheOps: firstSnapshotFetchCall, cacheSnapshot: cacheSnapshot ?? firstSnapshotFetchCall)
        firstSnapshotFetchCall = false
        return (retrieved, id)
    }

    private func obtainSnapshot(fetchSource: FetchSource?, loadingGroupIds: [String]?, scenarioName: String?) async throws -> (CompactSnapshot, Bool) {
        if fetchSource == .noCache {
            return (try await fetchSnapshotFromNetwork(loadingGroupIds: loadingGroupIds, scenarioName: scenarioName, avoidPrefetch: true), false)
        }
        if firstSnapshotFetchCall, concurrentSnapshotFetch, !summarizerClient {
            let cached = Task { try await self.readCachedSnapshot() }
            let fetched = Task { try await self.fetchSnapshotFromNetwork(loadingGroupIds: loadingGroupIds, scenarioName: scenarioName) }
            let (completed, continuation) = AsyncStream<Int>.makeStream()
            Task {
                _ = await cached.result
                continuation.yield(0)
            }
            Task {
                _ = await fetched.result
                continuation.yield(1)
            }
            var iterator = completed.makeAsyncIterator()
            guard let winner = await iterator.next() else { throw JSONDecodingError("missing snapshot race winner") }
            continuation.finish()
            if winner == 0 {
                if case .success(let snapshot?) = await cached.result { return (snapshot, true) }
                return (try await fetched.value, false)
            }
            if case .success(let snapshot) = await fetched.result { return (snapshot, false) }
            if let snapshot = try await cached.value { return (snapshot, true) }
            return (try await fetched.value, false)
        }
        if let cached = try await readCachedSnapshot() { return (cached, true) }
        return (try await fetchSnapshotFromNetwork(loadingGroupIds: loadingGroupIds, scenarioName: scenarioName), false)
    }

    public func getVersions(_ versionId: JSString?, count: Int, scenarioName: String?, fetchSource: FetchSource?) async throws -> [IVersion] {
        // The regular load workflow uses blobId === documentId to mean "latest".
        if let versionId, versionId.description != documentId, !versionId.description.isEmpty {
            return [try version(versionId)]
        }
        if snapshotUrl.isEmpty { return [] }
        if count == 1, versionId == nil || versionId?.description == documentId {
            let (_, id) = try await fetchSnapshot(fetchSource: fetchSource, loadingGroupIds: nil, cacheSnapshot: true, scenarioName: scenarioName)
            return try id.map { [try version($0)] } ?? []
        }
        let url = snapshotUrl + "/versions?top=\(count)"
        let response = try await network.authorized(url: url, method: "GET") { auth, _ in
            OdspRequest(url: url, method: "GET", headers: try getHeadersWithAuth(auth), timeoutMs: nil, fetchType: .versions, fetchReason: scenarioName)
        }
        guard case .array(let values) = try response.json().asObject()["value"] else {
            throw OdspNetworkError("genericNetworkError", canRetry: false)
        }
        return try values.map { try version($0.member("id").asString()) }
    }

    /// ODSP versions carry no tree ID (`treeId: undefined!` in TS).
    private func version(_ id: JSString) throws -> IVersion {
        var object = JSObject<JSONValue>()
        object["id"] = .string(id)
        return try IVersion(json: .object(object))
    }

    private func readCachedSnapshot() async throws -> CompactSnapshot? {
        do {
            let cached: CachedSnapshot?
            if let cacheRead { cached = try await cacheRead() }
            else { cached = persistedSnapshot }
            guard let cached, cached.version == 3 else { return nil }
            if network.epochTracker.fluidEpoch == nil { try network.epochTracker.validateEpoch(cached.fluidEpoch) }
            guard let timestamp = cached.cacheEntryTime else {
                try await network.epochTracker.removeEntries()
                return nil
            }
            let age = now() - timestamp
            if age >= 432000000 {
                persistedSnapshot = nil
                try await network.epochTracker.removeEntries()
                return nil
            }
            guard cached.fluidEpoch == network.epochTracker.fluidEpoch, !summarizerClient || age <= Self.defaultSummarizerCacheExpiryTimeout else { return nil }
            return cached.snapshot
        } catch {
            onCacheReadError(error)
            return nil
        }
    }
    /// Offline errors stay non-retryable: retrying getSnapshotTree would take the slow versions path.
    private func fetchSnapshotFromNetwork(loadingGroupIds: [String]?, scenarioName: String?, avoidPrefetch: Bool = false) async throws -> CompactSnapshot {
        do { return try await fetchSnapshotFromNetworkCore(loadingGroupIds: loadingGroupIds, scenarioName: scenarioName, avoidPrefetch: avoidPrefetch) }
        catch var error as OdspNetworkError {
            error.canRetry = false
            throw error
        }
    }
    private func fetchSnapshotFromNetworkCore(loadingGroupIds: [String]?, scenarioName: String?, avoidPrefetch: Bool) async throws -> CompactSnapshot {
        if !avoidPrefetch, firstSnapshotFetchCall, let prefetchedSnapshot {
            do {
                let cached = try await prefetchedSnapshot.value.snapshot
                try await network.epochTracker.validateEpoch(cached.fluidEpoch, fetchType: .treesLatest)
                return cached.snapshot
            } catch { onPrefetchError(error) }
        }
        let fetched: SnapshotFetchResult
        do { fetched = try await fetchSnapshotWithRedeem(loadingGroupIds: loadingGroupIds, scenarioName: scenarioName) }
        catch let error as OdspNetworkError {
            // fetchSnapshotWithRedeem clears the cache when the file is gone or access was revoked.
            if error.errorType == "authorizationError" || error.errorType == "fileNotFoundOrAccessDeniedError" {
                try await network.epochTracker.removeEntries()
            }
            throw error
        }
        var snapshot = fetched.snapshot
        let firstSequence = try snapshot.ops.first.map { try $0.member("sequenceNumber").asInt() - 1 }
        if let firstSequence, firstSequence != snapshot.sequenceNumber ?? 0 {
            snapshot.sequenceNumber = nil
        } else if fetched.cacheAllowed, let epoch = network.epochTracker.fluidEpoch, loadingGroupIds?.isEmpty != false {
            let cached = CachedSnapshot(snapshot: snapshot, fluidEpoch: epoch, cacheEntryTime: now())
            persistedSnapshot = cached
            if let cachePut {
                // fetchLatestSnapshotCore starts the persisted write without delaying the snapshot.
                Task {
                    do { try await cachePut(cached) }
                    catch { onCacheWriteError(error) }
                }
            }
        }
        return snapshot
    }
    public func setPersistedSnapshot(_ snapshot: CachedSnapshot?) { persistedSnapshot = snapshot }
    /// prefetchLatestSnapshot.ts: publish the deferred first, resolve before awaiting persisted put.
    public func prefetchLatestSnapshot() -> Task<Bool, Never> {
        let network = self.network
        let downloaded = Task {
            let fetched = try await fetchSnapshotCore(resolved: network.resolvedUrl, network: network, untracked: true)
            guard let epoch = fetched.fluidEpoch, !epoch.isEmpty else { throw JSONDecodingError("0x585") }
            let cached = CachedSnapshot(snapshot: fetched.snapshot, fluidEpoch: epoch, cacheEntryTime: now())
            let persisted = Task {
                if let cachePut { try await cachePut(cached) }
            }
            return (snapshot: cached, persisted: persisted)
        }
        prefetchedSnapshot = downloaded
        return Task { await self.completePrefetch(downloaded) }
    }
    private func completePrefetch(_ downloaded: Task<PrefetchResult, Error>) async -> Bool {
        do {
            let result = try await downloaded.value
            let cached = result.snapshot
            try await result.persisted.value
            persistedSnapshot = cached
            prefetchEviction = Task {
                do { try await sleep(5000) } catch { return }
                self.prefetchedSnapshot = nil
            }
            return true
        } catch {
            prefetchedSnapshot = nil
            onPrefetchError(error)
            return false
        }
    }
    /// fetchSnapshot.ts fetchSnapshotWithRedeem plus this class's size/time limits: the driver's
    /// 500 MB / 2 min defaults, none for the summarizer, and a blobless retry on 413 or timeout.
    private func fetchSnapshotWithRedeem(loadingGroupIds: [String]?, scenarioName: String?) async throws -> SnapshotFetchResult {
        var snapshotOptions = JSObject<JSONValue>()
        snapshotOptions["mds"] = .number(500000000)
        for (key, value) in hostSnapshotOptions.entries { snapshotOptions[key] = value }
        let hostTimeout = try hostSnapshotOptions["timeout"]?.asNumber() ?? 0
        snapshotOptions["timeout"] = .number(hostTimeout == 0 ? 120000 : min(hostTimeout, 120000))
        if summarizerClient {
            snapshotOptions["mds"] = nil
            snapshotOptions["timeout"] = nil
        }
        let resolved = network.resolvedUrl
        do {
            return try await fetchSnapshotCore(resolved: resolved, network: network, options: snapshotOptions, loadingGroupIds: loadingGroupIds, scenarioName: scenarioName)
        } catch let error as OdspNetworkError {
            if error.errorType == "snapshotTooBig", hostSnapshotOptions["mds"] != nil, !summarizerClient { throw error }
            let blobs = snapshotOptions["blobs"]
            let hasBlobs = blobs != nil && blobs != .number(0) && blobs != .bool(false) && blobs != .null
            guard ["snapshotTooBig", "fetchTimeout"].contains(error.errorType), hasBlobs else { throw error }
            snapshotOptions["blobs"] = .number(0)
            snapshotOptions["mds"] = nil
            snapshotOptions["timeout"] = nil
            return try await fetchSnapshotCore(resolved: resolved, network: network, options: snapshotOptions, loadingGroupIds: loadingGroupIds, scenarioName: scenarioName)
        }
    }

    /// The legacy trees/<id> download (fetchSnapshot.ts fetchSnapshot with fetchFullSnapshot).
    func fetchTreeFromSnapshot(_ id: JSString, scenarioName: String?) async throws -> CompactSnapshotTree? {
        let query = id == "latest" ? "?deltas=1&blobs=2" : "?blobs=2"
        let url = snapshotUrl + "/trees/" + id.description + query
        let response = try await network.authorized(url: url, method: "GET") { auth, _ in
            OdspRequest(url: url, method: "GET", headers: try getHeadersWithAuth(auth), timeoutMs: nil, fetchType: .snapshotTree, fetchReason: scenarioName)
        }
        let snapshot = try convertOdspSnapshotToSnapshotTreeAndBlobs(response.json())
        guard let treeId = snapshot.snapshotTree.id else { throw JSONDecodingError("0x222") }
        commitCache[treeId] = snapshot.snapshotTree
        try blobCache.addBlobs(snapshot.blobContents)
        // If the version ID differs from the tree's, the first tree is the one that was fetched.
        return commitCache[id] ?? commitCache[treeId]
    }

    public func uploadSummaryWithContext(_ summary: SummaryTree, context: ISummaryContext) async throws -> JSString {
        guard !snapshotUrl.isEmpty else { throw OdspNetworkError("genericError", canRetry: false) }
        guard case .tree(let tree) = summary else { throw JSONDecodingError("TypeError: summary.tree is undefined") }
        // Flush only for single-commit summaries that are not the initial summary of an empty file.
        if tree.tree[".protocol"] != nil, context.ackHandle != nil {
            var retry = 1
            while true {
                let result = try await flushCallback().asObject()
                let sequenceNumber = try result["lastPersistedSequenceNumber"]?.asNumber()
                if let sequenceNumber, sequenceNumber >= Double(context.referenceSequenceNumber) { break }
                if retry > 3 { break }
                retry += 1
                try await sleep(1000 * (try result["retryAfter"]?.asNumber() ?? 1))
            }
        }
        let manager: OdspSummaryUploadManager
        if let existing = odspSummaryUploadManager { manager = existing }
        else {
            manager = OdspSummaryUploadManager(snapshotStorageUrl: network.resolvedUrl.snapshotStorageUrl, network: network)
            odspSummaryUploadManager = manager
        }
        let relaySession = await relayServiceTenantAndSessionId()
        let id = try await manager.writeSummaryTree(tree, context: context, relayServiceTenantAndSessionId: relaySession)
        let resolved = network.resolvedUrl
        if let pendingRename = resolved.pendingRename {
            // A temporary file from the empty-file create flow: remove its .tmp name after the first summary.
            guard context.ackHandle == nil, context.proposalHandle == nil, context.referenceSequenceNumber == 0 else { throw JSONDecodingError("0xa88") }
            let renameResponse = try await renameEmptyFluidFile(network: network, odspParts: resolved, requestedFileName: pendingRename)
            let renamed = try resolved.setting("pendingRename", nil).setting("fileName", renameResponse.member("name"))
            network.updateResolvedUrl(renamed)
        }
        return JSString(id)
    }
}

/// prefetchLatestSnapshot.ts. Download completion and persisted-put completion remain distinct.
public func prefetchLatestSnapshot(storage: OdspDocumentStorageService) async -> Bool {
    await storage.prefetchLatestSnapshot().value
}
