import FluidJS
import Foundation

/// odspDocumentStorageManager.ts. Native snapshots retain byte slices and maps in cache.
public final class OdspDocumentStorageService {
    public struct CachedSnapshot {
        public let snapshot: CompactSnapshot
        public let fluidEpoch: String
        public let cacheEntryTime: Double
        public let version: Int
        public init(snapshot: CompactSnapshot, fluidEpoch: String, cacheEntryTime: Double, version: Int = 3) {
            self.snapshot = snapshot
            self.fluidEpoch = fluidEpoch
            self.cacheEntryTime = cacheEntryTime
            self.version = version
        }
    }
    public private(set) var firstSnapshotFetchCall = true
    public private(set) var ops: [JSONValue] = []
    public var persistedSnapshot: CachedSnapshot?
    public var prefetchedSnapshot: CachedSnapshot?
    public var onPrefetchError: (Error) -> Void = { _ in }
    public var now: () -> Double = { Date().timeIntervalSince1970 * 1000 }
    private let resolved: IOdspResolvedUrl
    private let network: OdspNetwork
    public init(resolved: IOdspResolvedUrl, network: OdspNetwork) {
        self.resolved = resolved
        self.network = network
    }
    public func getSnapshot(noCache: Bool = false, summarizer: Bool = false, options: JSObject<JSONValue> = .init(), loadingGroupIds: [String]? = nil) async throws -> CompactSnapshot {
        if !noCache, loadingGroupIds?.isEmpty != false, let cached = persistedSnapshot, cached.version == 3 {
            // Cache epoch is learned before age rejection, as in epochTracker.get.
            if network.epochTracker.fluidEpoch == nil { try network.epochTracker.validateEpoch(cached.fluidEpoch) }
            let age = now() - cached.cacheEntryTime
            if age >= 432000000 { persistedSnapshot = nil }
            else if cached.fluidEpoch == network.epochTracker.fluidEpoch, !summarizer || age <= 60000 { return initialize(cached.snapshot) }
        }
        if firstSnapshotFetchCall, !noCache, let prefetched = prefetchedSnapshot {
            prefetchedSnapshot = nil
            do {
                try network.epochTracker.validateEpoch(prefetched.fluidEpoch)
                return initialize(prefetched.snapshot)
            } catch { onPrefetchError(error) }
        }
        do {
            let fetched = try await fetchSnapshotCore(resolved: resolved, network: network, options: options, loadingGroupIds: loadingGroupIds)
            let snapshot = fetched.snapshot
            if fetched.cacheAllowed, let epoch = network.epochTracker.fluidEpoch, loadingGroupIds?.isEmpty != false {
                let firstSequence = try snapshot.ops.first.map { try $0.member("sequenceNumber").asInt() }
                if firstSequence == nil || firstSequence == (snapshot.sequenceNumber ?? 0) + 1 {
                    persistedSnapshot = CachedSnapshot(snapshot: snapshot, fluidEpoch: epoch, cacheEntryTime: now())
                }
            }
            return initialize(snapshot)
        } catch var error as OdspNetworkError {
            error.canRetry = false
            throw error
        }
    }
    private func initialize(_ snapshot: CompactSnapshot) -> CompactSnapshot {
        if firstSnapshotFetchCall { ops = snapshot.ops }
        firstSnapshotFetchCall = false
        return snapshot
    }
}

/// prefetchLatestSnapshot.ts. Failure is observable as false; cache holds native binary values.
public func prefetchLatestSnapshot(storage: OdspDocumentStorageService, resolved: IOdspResolvedUrl, network: OdspNetwork, now: () -> Double) async -> Bool {
    do {
        let snapshot = try await downloadSnapshot(resolved: resolved, network: network)
        guard let epoch = network.epochTracker.fluidEpoch, !epoch.isEmpty else { throw JSONDecodingError("0x585") }
        let cached = OdspDocumentStorageService.CachedSnapshot(snapshot: snapshot, fluidEpoch: epoch, cacheEntryTime: now())
        storage.persistedSnapshot = cached
        storage.prefetchedSnapshot = cached
        return true
    } catch {
        storage.prefetchedSnapshot = nil
        return false
    }
}
