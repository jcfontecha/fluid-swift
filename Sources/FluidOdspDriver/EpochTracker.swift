import FluidJS
import Foundation

/// epochTracker.ts. Owned by the container's serial executor, not an independently scheduled actor.
public final class EpochTracker {
    public private(set) var fluidEpoch: String?
    public private(set) var cacheClearCount = 0
    public var onCacheClear: () -> Void = {}
    public init() {}

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
