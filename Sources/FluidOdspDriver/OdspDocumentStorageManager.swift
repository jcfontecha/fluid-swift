import FluidJS
import Foundation

/// odspDocumentStorageManager.ts. Native snapshots retain byte slices and maps in cache.
public actor OdspDocumentStorageService {
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
    public private(set) var firstSnapshotFetchCall = true
    public private(set) var ops: [JSONValue] = []
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
    private let resolved: IOdspResolvedUrl
    private let network: OdspNetwork
    private let concurrentSnapshotFetch: Bool
    private let cacheRead: (@Sendable () async throws -> CachedSnapshot?)?
    private let cachePut: (@Sendable (CachedSnapshot) async throws -> Void)?
    public init(resolved: IOdspResolvedUrl, network: sending OdspNetwork, concurrentSnapshotFetch: Bool = false, cacheRead: (@Sendable () async throws -> CachedSnapshot?)? = nil, cachePut: (@Sendable (CachedSnapshot) async throws -> Void)? = nil, sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) }) {
        self.resolved = resolved
        self.network = network
        self.concurrentSnapshotFetch = concurrentSnapshotFetch
        self.cacheRead = cacheRead
        self.cachePut = cachePut
        self.sleep = sleep
    }
    public func getSnapshot(noCache: Bool = false, summarizer: Bool = false, options: JSObject<JSONValue> = .init(), loadingGroupIds: [String]? = nil) async throws -> CompactSnapshot {
        if !noCache, loadingGroupIds?.isEmpty != false {
            if firstSnapshotFetchCall, concurrentSnapshotFetch, !summarizer {
                let cached = Task { try await self.readCachedSnapshot(summarizer: summarizer) }
                let fetched = Task { try await self.loadNetworkSnapshot(options: options, summarizer: summarizer, loadingGroupIds: loadingGroupIds) }
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
                    if case .success(let snapshot?) = await cached.result { return initialize(snapshot) }
                    return initialize(try await fetched.value)
                }
                if case .success(let snapshot) = await fetched.result { return initialize(snapshot) }
                if let snapshot = try await cached.value { return initialize(snapshot) }
                return initialize(try await fetched.value)
            }
            if let cached = try await readCachedSnapshot(summarizer: summarizer) { return initialize(cached) }
        }
        do {
            return initialize(try await loadNetworkSnapshot(options: options, summarizer: summarizer, loadingGroupIds: loadingGroupIds, avoidPrefetch: noCache))
        } catch var error as OdspNetworkError {
            error.canRetry = false
            throw error
        }
    }
    private func readCachedSnapshot(summarizer: Bool) async throws -> CompactSnapshot? {
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
            guard cached.fluidEpoch == network.epochTracker.fluidEpoch, !summarizer || age <= 60000 else { return nil }
            return cached.snapshot
        } catch {
            onCacheReadError(error)
            return nil
        }
    }
    private func loadNetworkSnapshot(options: JSObject<JSONValue>, summarizer: Bool, loadingGroupIds: [String]?, avoidPrefetch: Bool = false) async throws -> CompactSnapshot {
        if !avoidPrefetch, let prefetchedSnapshot {
            do {
                let cached = try await prefetchedSnapshot.value.snapshot
                try network.epochTracker.validateEpoch(cached.fluidEpoch)
                return cached.snapshot
            } catch { onPrefetchError(error) }
        }
        let fetched: SnapshotFetchResult
        do { fetched = try await fetchSnapshotFromNetwork(options: options, summarizer: summarizer, loadingGroupIds: loadingGroupIds) }
        catch var error as OdspNetworkError {
            error.canRetry = false
            throw error
        }
        let snapshot = fetched.snapshot
        if fetched.cacheAllowed, let epoch = network.epochTracker.fluidEpoch, loadingGroupIds?.isEmpty != false {
            let firstSequence = try snapshot.ops.first.map { try $0.member("sequenceNumber").asInt() }
            if firstSequence == nil || firstSequence == (snapshot.sequenceNumber ?? 0) + 1 {
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
        }
        return snapshot
    }
    public func setPersistedSnapshot(_ snapshot: CachedSnapshot?) { persistedSnapshot = snapshot }
    /// prefetchLatestSnapshot.ts: publish the deferred first, resolve before awaiting persisted put.
    public func prefetchLatestSnapshot() -> Task<Bool, Never> {
        let downloaded = Task {
            let fetched = try await fetchSnapshotCore(resolved: resolved, network: network, untracked: true)
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
    private func fetchSnapshotFromNetwork(options: JSObject<JSONValue>, summarizer: Bool, loadingGroupIds: [String]?) async throws -> SnapshotFetchResult {
        var snapshotOptions = JSObject<JSONValue>()
        snapshotOptions["mds"] = .number(500000000)
        for (key, value) in options.entries { snapshotOptions[key] = value }
        let hostTimeout = try options["timeout"]?.asNumber() ?? 0
        snapshotOptions["timeout"] = .number(hostTimeout == 0 ? 120000 : min(hostTimeout, 120000))
        if summarizer {
            snapshotOptions["mds"] = nil
            snapshotOptions["timeout"] = nil
        }
        do {
            return try await fetchSnapshotCore(resolved: resolved, network: network, options: snapshotOptions, loadingGroupIds: loadingGroupIds)
        } catch let error as OdspNetworkError {
            if error.errorType == "snapshotTooBig", options["mds"] != nil, !summarizer { throw error }
            let blobs = snapshotOptions["blobs"]
            let hasBlobs = blobs != nil && blobs != .number(0) && blobs != .bool(false) && blobs != .null
            guard ["snapshotTooBig", "fetchTimeout"].contains(error.errorType), hasBlobs else { throw error }
            snapshotOptions["blobs"] = .number(0)
            snapshotOptions["mds"] = nil
            snapshotOptions["timeout"] = nil
            return try await fetchSnapshotCore(resolved: resolved, network: network, options: snapshotOptions, loadingGroupIds: loadingGroupIds)
        }
    }
    private func initialize(_ snapshot: CompactSnapshot) -> CompactSnapshot {
        if firstSnapshotFetchCall { ops = snapshot.ops }
        firstSnapshotFetchCall = false
        return snapshot
    }
}

/// prefetchLatestSnapshot.ts. Download completion and persisted-put completion remain distinct.
public func prefetchLatestSnapshot(storage: OdspDocumentStorageService) async -> Bool {
    await storage.prefetchLatestSnapshot().value
}
