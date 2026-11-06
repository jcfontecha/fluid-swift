import Foundation
import Synchronization

/// Ports cache.ts InMemoryCache with mapWithExpiration.ts: an entry older than the expiry is gone
/// on the next read. Shared by every document service the factory creates.
final class InMemoryCache<Value: Sendable>: Sendable {
    private let entries = Mutex<[String: (value: Value, stored: Date)]>([:])
    private let expirationMs: Double?

    init(expirationMs: Double? = nil) {
        self.expirationMs = expirationMs
    }

    func get(_ key: String) -> Value? {
        entries.withLock { entries in
            guard let entry = entries[key] else { return nil }
            if let expirationMs, Date().timeIntervalSince(entry.stored) * 1000 > expirationMs {
                entries[key] = nil
                return nil
            }
            return entry.value
        }
    }

    func put(_ key: String, _ value: Value) {
        entries.withLock { $0[key] = (value, Date()) }
    }
}
