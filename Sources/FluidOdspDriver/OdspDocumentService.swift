import FluidDriverDefinitions
import FluidJS
import Foundation
import Synchronization

/// odsp-driver-definitions/src/factory.ts HostStoragePolicy: the fields this driver reads.
public struct HostStoragePolicy: Sendable {
    /// Extra trees/latest query options (`mds`, `blobs`, `deltas`, `timeout`).
    public var snapshotOptions: JSObject<JSONValue>?
    public var concurrentSnapshotFetch: Bool?
    public var opsBatchSize: Int?
    public var concurrentOpsBatches: Int?
    /// Cache the create-new summary as the new file's snapshot (default true).
    public var cacheCreateNewSummary: Bool?
    /// `sessionOptions.displayName` for app-only join sessions.
    public var displayName: String?
    public init() {}
}

/// odspDocumentService.ts. Lazily owns the storage manager and the delta stream; the epoch
/// tracker and file entry (`network`) are shared with them, as in TS.
public final class OdspDocumentService: IDocumentService {
    private struct State {
        var storageManager: OdspDocumentStorageService?
        var deltaStream: OdspDelayLoadedDeltaStream?
    }
    public let policies: IDocumentServicePolicies?
    private let network: OdspNetwork
    private let getWebsocketToken: (@Sendable (TokenFetchOptions) async throws -> String?)?
    private let sessionJoinCache: OdspSessionJoinCache
    private let persistedCache: LocalPersistentCache
    private let hostPolicy: HostStoragePolicy
    private let socketIOFactory: OdspSocketIOFactory
    private let clientIsSummarizer: Bool
    private let state = Mutex(State())

    init(network: OdspNetwork, getWebsocketToken: (@Sendable (TokenFetchOptions) async throws -> String?)?, sessionJoinCache: OdspSessionJoinCache, persistedCache: LocalPersistentCache, hostPolicy: HostStoragePolicy, socketIOFactory: OdspSocketIOFactory, clientIsSummarizer: Bool) {
        self.network = network
        self.getWebsocketToken = getWebsocketToken
        self.sessionJoinCache = sessionJoinCache
        self.persistedCache = persistedCache
        self.hostPolicy = hostPolicy
        self.socketIOFactory = socketIOFactory
        self.clientIsSummarizer = clientIsSummarizer
        // Load in storage-only mode if a file version is specified.
        policies = IDocumentServicePolicies(storageOnly: network.resolvedUrl.fileVersion != nil, summarizeProtocolTree: true, supportGetSnapshotApi: true)
    }

    /// The shared resolved URL: a create-new rename updates it after the first summary.
    public var resolvedUrl: IResolvedUrl {
        network.resolvedUrl.resolvedUrl
    }

    public func connectToStorage() async throws -> any IDocumentStorageService {
        let storageManager = state.withLock { state in
            if let existing = state.storageManager { return existing }
            let created = makeStorageManager()
            state.storageManager = created
            return created
        }
        return RetryErrorsStorageAdapter(storageManager)
    }

    private func makeStorageManager() -> OdspDocumentStorageService {
        let network = self.network
        let persistedCache = self.persistedCache
        return OdspDocumentStorageService(network: network, summarizerClient: clientIsSummarizer, hostSnapshotOptions: hostPolicy.snapshotOptions ?? .init(), concurrentSnapshotFetch: hostPolicy.concurrentSnapshotFetch ?? false, cacheRead: {
            let docId = network.resolvedUrl.hashedDocumentId
            guard let entry = persistedCache.get(docId: docId, key: snapshotCacheKey, now: Date().timeIntervalSince1970 * 1000), case .snapshot(let snapshot) = entry.value else { return nil }
            return .init(snapshot: snapshot, fluidEpoch: entry.fluidEpoch, cacheEntryTime: entry.cacheEntryTime, version: entry.version)
        }, cachePut: { cached in
            let docId = network.resolvedUrl.hashedDocumentId
            persistedCache.put(docId: docId, key: snapshotCacheKey, entry: .init(value: .snapshot(cached.snapshot), fluidEpoch: cached.fluidEpoch, version: cached.version, cacheEntryTime: cached.cacheEntryTime), now: Date().timeIntervalSince1970 * 1000)
        }, flushCallback: { [weak self] in
            let stream = self?.state.withLock { $0.deltaStream }
            guard let connection = await stream?.currentConnection, await !connection.disposed else {
                throw JSONDecodingError("Disconnected while uploading summary (attempt to perform flush())")
            }
            return try await connection.flush()
        }, relayServiceTenantAndSessionId: { [weak self] in
            let stream = self?.state.withLock { $0.deltaStream }
            return await stream?.relayServiceTenantAndSessionId
        })
    }

    public func connectToDeltaStorage() async throws -> any IDocumentDeltaStorageService {
        let storageManager = state.withLock { $0.storageManager }
        let snapshotOps = await storageManager?.ops ?? []
        let service = OdspDeltaStorageService(deltaFeedUrl: network.resolvedUrl.deltaStorageUrl, network: network)
        // Batch size: see issue #5211 for data around batch sizing.
        return OdspDeltaStorageWithCache(snapshotOps: snapshotOps, batchSize: hostPolicy.opsBatchSize ?? 5000, concurrency: hostPolicy.concurrentOpsBatches ?? 1, getFromStorage: { from, to, fetchReason in
            // The server returns every op it has in the range, so the result is never partial.
            .init(messages: try await service.get(from: from, to: to, fetchReason: fetchReason), partialResult: false)
        }, getCached: { _, _ in
            // The ops cache (opsCaching.ts) is not wired to the persisted cache yet: always a miss.
            []
        }, requestFromSocket: { [weak self] from, to in
            guard let stream = self?.state.withLock({ $0.deltaStream }), let connection = await stream.currentConnection, await !connection.disposed else { return }
            try await connection.requestOps(from: from, to: to)
        }, opsReceived: { _ in
            // TS adds these to the ops cache, which is not wired (see getCached).
        }, storageManagerGetter: { [weak self] in
            self?.state.withLock { $0.storageManager }
        })
    }

    public func connectToDeltaStream(_ client: IClient) async throws -> any IDocumentDeltaConnection {
        let stream = state.withLock { state in
            if let existing = state.deltaStream { return existing }
            let network = self.network
            let resolved = network.resolvedUrl
            let created = OdspDelayLoadedDeltaStream(hashedDocumentId: resolved.hashedDocumentId, cache: sessionJoinCache, fetch: { requestSocketToken, displayName, refreshing, options in
                try await fetchJoinSession(resolved: network.resolvedUrl, network: network, options: options, requestSocketToken: requestSocketToken, displayName: displayName)
            })
            state.deltaStream = created
            return created
        }
        return try await stream.connectToDeltaStream(client, factory: socketIOFactory, getWebsocketToken: getWebsocketToken, epochTracker: network.epochTracker, displayName: hostPolicy.displayName)
    }

    /// An error may mean the client's view of the file is stale (e.g. overwritten without a new
    /// epoch), so the cached entries go; TS ignores failures of that removal.
    public func dispose(_ error: (any Error)?) {
        let network = self.network
        if error != nil {
            Task { try? await network.epochTracker.removeEntries() }
        }
        guard let stream = state.withLock({ $0.deltaStream }) else { return }
        Task { await stream.dispose() }
    }
}

/// getKeyForCacheEntry's `${type}_${key}` part of the snapshot entry (key `""`).
let snapshotCacheKey = "snapshot_"
