import FluidJS
import Foundation
import Synchronization

/// epochTracker.ts. One tracker is shared by every component of a file (storage, delta storage,
/// join session, summary upload, create-new), as `createOdspCacheAndTracker` shares it in TS.
/// Its mutable state lives behind a mutex; each synchronous TS segment (validate, learn, count)
/// is one critical section. Non-final because `EpochTrackerWithRedemption` extends it, as in TS.
public class EpochTracker: @unchecked Sendable {
    public struct Entry: Sendable {
        public let type: String
        public let key: String
        public init(type: String, key: String) {
            self.type = type
            self.key = key
        }
    }
    private struct State {
        var fluidEpoch: String?
        var cacheClearCount = 0
    }
    private let state = Mutex(State())
    public let rateLimiter = RateLimiter(24)
    /// `isSummarizer=${clientIsSummarizer}` in X-RequestStats.
    public let clientIsSummarizer: Bool
    private let cacheGet: (@Sendable (Entry) async throws -> JSONValue?)?
    private let cachePut: (@Sendable (Entry, JSONValue) async throws -> Void)?
    private let cacheRemove: (@Sendable () async throws -> Void)?
    private let now: @Sendable () -> Double

    public init(clientIsSummarizer: Bool = false, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, cacheGet: (@Sendable (Entry) async throws -> JSONValue?)? = nil, cachePut: (@Sendable (Entry, JSONValue) async throws -> Void)? = nil, cacheRemove: (@Sendable () async throws -> Void)? = nil) {
        self.clientIsSummarizer = clientIsSummarizer
        self.now = now
        self.cacheGet = cacheGet
        self.cachePut = cachePut
        self.cacheRemove = cacheRemove
    }

    public var fluidEpoch: String? {
        state.withLock { $0.fluidEpoch }
    }

    public var cacheClearCount: Int {
        state.withLock { $0.cacheClearCount }
    }

    nonisolated(nonsending) public func get(_ entry: Entry) async -> JSONValue? {
        do {
            guard let envelope = try await cacheGet?(entry), try envelope.asObject()["version"] == .number(3) else { return nil }
            guard let epoch = try envelope.asObject()["fluidEpoch"]?.asString().description else { throw JSONDecodingError("0x1dc") }
            if fluidEpoch == nil { try validateEpoch(epoch) }
            else if fluidEpoch != epoch { return nil }
            let value = try envelope.asObject()["value"]
            if isSnapshot(entry) {
                let timestamp = try value?.asObject()["cacheEntryTime"]?.asNumber()
                if timestamp == nil || now() - (timestamp ?? 0) >= 432000000 {
                    try await removeEntries()
                    return nil
                }
            }
            return value
        } catch {
            // TS logs cacheFetchError and treats the entry as missing.
            return nil
        }
    }
    nonisolated(nonsending) public func put(_ entry: Entry, value: JSONValue) async throws {
        guard let epoch = fluidEpoch else { throw JSONDecodingError("0x1dd") }
        var value = value
        if isSnapshot(entry) {
            var fields = try value.asObject()
            if fields["cacheEntryTime"] == nil || fields["cacheEntryTime"] == .null { fields["cacheEntryTime"] = .number(now()) }
            value = .object(fields)
        }
        var envelope = JSObject<JSONValue>()
        envelope["value"] = value
        envelope["version"] = .number(3)
        envelope["fluidEpoch"] = .string(JSString(epoch))
        try await cachePut?(entry, .object(envelope))
    }
    nonisolated(nonsending) public func removeEntries() async throws {
        clearCache()
        try await cacheRemove?()
    }
    private func isSnapshot(_ entry: Entry) -> Bool {
        entry.type == "snapshot" || entry.type == "snapshotWithLoadingGroupId"
    }

    nonisolated(nonsending) public func fetch<T>(type: OdspFetchType, call: () async throws -> T) async throws -> T {
        do { return try await call() }
        catch let error as OdspNetworkError {
            if error.errorType == "fileOverwrittenInStorage" { try await cacheRemove?() }
            throw error
        }
    }

    public func validateEpoch(_ epoch: String?) throws {
        guard let epoch else { throw JSONDecodingError("0x584") }
        let mismatch = state.withLock { state -> Bool in
            if let current = state.fluidEpoch, !current.isEmpty, !epoch.isEmpty, current != epoch {
                state.cacheClearCount += 1
                return true
            }
            if state.fluidEpoch == nil { state.fluidEpoch = epoch }
            return false
        }
        if mismatch {
            var error = OdspNetworkError("fileOverwrittenInStorage", canRetry: false)
            error.serverEpoch = epoch
            throw error
        }
    }

    public func clearCache() {
        state.withLock { $0.cacheClearCount += 1 }
    }

    public func classify(status: Int, headers: [String: String], body: String = "") throws -> OdspNetworkError {
        var error = try createOdspNetworkError(status: status, headers: headers, body: body)
        if status == 409, fluidEpoch != nil, let incoming = error.serverEpoch {
            do { try validateEpoch(incoming) }
            catch let mismatch as OdspNetworkError { return mismatch }
        }
        if status == 409 {
            error.errorType = "throttlingError"
            error.canRetry = true
            error.retryAfterMs = 1000
            error.odsp409Error = true
        }
        return error
    }
}

/// A persisted-cache value. Snapshots keep their native buffers (TS stores the ISnapshot object
/// with its `Map` of ArrayBuffers as is); other entries are JSON.
public enum PersistedCacheValue: Sendable {
    case json(JSONValue)
    case snapshot(CompactSnapshot)
}

/// odspCache.ts LocalPersistentCache. The per-docId 1-hour expiry restarts on every put (TS
/// `updateExpirationEntry`); clock injection preserves expiry equality without wall time.
public final class LocalPersistentCache: Sendable {
    public struct Entry: Sendable {
        public let value: PersistedCacheValue
        public let fluidEpoch: String
        public let version: Int
        public let cacheEntryTime: Double?
        public init(value: PersistedCacheValue, fluidEpoch: String, version: Int = 3, cacheEntryTime: Double? = nil) {
            self.value = value
            self.fluidEpoch = fluidEpoch
            self.version = version
            self.cacheEntryTime = cacheEntryTime
        }
    }
    private struct State {
        var entries: [String: Entry] = [:]
        var expires: [String: Double] = [:]
    }
    private let state = Mutex(State())
    public init() {}
    public func put(docId: String, key: String, entry: Entry, now: Double) {
        state.withLock { state in
            state.entries[docId + "_" + key] = entry
            state.expires[docId] = now + 3600000
        }
    }
    public func get(docId: String, key: String, now: Double) -> Entry? {
        state.withLock { state in
            if let expiry = state.expires[docId], now >= expiry { Self.remove(docId: docId, from: &state) }
            return state.entries[docId + "_" + key]
        }
    }
    public func removeEntries(docId: String) {
        state.withLock { Self.remove(docId: docId, from: &$0) }
    }
    private static func remove(docId: String, from state: inout State) {
        state.entries = state.entries.filter { $0.key.components(separatedBy: "_").first != docId }
        state.expires.removeValue(forKey: docId)
    }
}
