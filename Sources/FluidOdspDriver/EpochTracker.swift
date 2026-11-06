import FluidJS
import Foundation

/// epochTracker.ts. Owned by the container's serial executor, not an independently scheduled actor.
public class EpochTracker {
    public private(set) var fluidEpoch: String?
    public private(set) var cacheClearCount = 0
    public var onCacheClear: () -> Void = {}
    public struct Entry: Sendable {
        public let type: String
        public let key: String
        public init(type: String, key: String) {
            self.type = type
            self.key = key
        }
    }
    public let rateLimiter = RateLimiter(24)
    public var onCacheError: (Error) -> Void = { _ in }
    private let cacheGet: ((Entry) async throws -> JSONValue?)?
    private let cachePut: ((Entry, JSONValue) async throws -> Void)?
    private let cacheRemove: (() async throws -> Void)?
    private let now: () -> Double
    public init(now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }, cacheGet: ((Entry) async throws -> JSONValue?)? = nil, cachePut: ((Entry, JSONValue) async throws -> Void)? = nil, cacheRemove: (() async throws -> Void)? = nil) {
        self.now = now
        self.cacheGet = cacheGet
        self.cachePut = cachePut
        self.cacheRemove = cacheRemove
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
            onCacheError(error)
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
        do { try await cachePut?(entry, .object(envelope)) }
        catch {
            onCacheError(error)
            throw error
        }
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
        if let current = fluidEpoch, !current.isEmpty, !epoch.isEmpty, current != epoch {
            clearCache()
            var error = OdspNetworkError("fileOverwrittenInStorage", canRetry: false)
            error.serverEpoch = epoch
            throw error
        }
        if fluidEpoch == nil { fluidEpoch = epoch }
    }

    public func clearCache() {
        cacheClearCount += 1
        onCacheClear()
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

/// odspCache.ts. Clock injection preserves expiry equality and makes tests independent of wall time.
public final class LocalPersistentCache {
    public struct Entry {
        public let value: JSONValue
        public let fluidEpoch: String
        public let version: Int
        public let cacheEntryTime: Double?
        public init(value: JSONValue, fluidEpoch: String, version: Int = 3, cacheEntryTime: Double? = nil) {
            self.value = value
            self.fluidEpoch = fluidEpoch
            self.version = version
            self.cacheEntryTime = cacheEntryTime
        }
    }
    private var entries: [String: Entry] = [:]
    private var expires: [String: Double] = [:]
    public init() {}
    public func put(docId: String, key: String, entry: Entry, now: Double) {
        entries[docId + "_" + key] = entry
        expires[docId] = now + 3600000
    }
    public func get(docId: String, key: String, now: Double) -> Entry? {
        if let expiry = expires[docId], now >= expiry { removeEntries(docId: docId) }
        return entries[docId + "_" + key]
    }
    public func removeEntries(docId: String) {
        entries = entries.filter { $0.key.components(separatedBy: "_").first != docId }
        expires.removeValue(forKey: docId)
    }
}
