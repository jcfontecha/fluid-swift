/// A JavaScript `Map`: iteration follows insertion order for every key (unlike `JSObject`, array-index
/// keys are not hoisted). Setting an existing key keeps its position; deleting and re-adding moves it
/// to the end.
///
/// Like a JS `Map`, `delete` is O(1): it leaves a hole in the insertion order, and holes are
/// compacted away once they outnumber the live keys.
public struct JSMap<Key: Hashable, Value> {
    @usableFromInline internal struct Entry {
        /// The key's slot in `order`.
        @usableFromInline internal var slot: Int
        @usableFromInline internal var value: Value

        @inlinable internal init(slot: Int, value: Value) {
            self.slot = slot
            self.value = value
        }
    }

    /// Keys in insertion order; nil where a key was deleted.
    @usableFromInline internal var order: [Key?] = []
    @usableFromInline internal var storage: [Key: Entry] = [:]

    @inlinable public init() {}

    @inlinable public var size: Int { storage.count }

    @inlinable public func get(_ key: Key) -> Value? {
        storage[key]?.value
    }

    @inlinable public func has(_ key: Key) -> Bool {
        storage[key] != nil
    }

    @inlinable public mutating func set(_ key: Key, _ value: Value) {
        // One hash probe: an existing key keeps its slot; a new one is stored at the end.
        let end = order.count
        if Self.update(&storage[key, default: Entry(slot: end, value: value)], to: value) == end {
            order.append(key)
        }
    }

    /// Stores `value` in the entry and returns the entry's slot.
    @inlinable internal static func update(_ entry: inout Entry, to value: Value) -> Int {
        entry.value = value
        return entry.slot
    }

    /// Returns whether the key was present, as `Map.prototype.delete` does.
    @discardableResult
    @inlinable public mutating func delete(_ key: Key) -> Bool {
        guard let entry = storage.removeValue(forKey: key) else {
            return false
        }
        if storage.isEmpty {
            order.removeAll(keepingCapacity: true)
        } else {
            order[entry.slot] = nil
            if order.count > 2 * storage.count + 16 { compact() }
        }
        return true
    }

    @inlinable public mutating func clear() {
        order.removeAll()
        storage.removeAll()
    }

    /// `Map.prototype.keys()`, snapshotted.
    @inlinable public var keys: [Key] { order.compactMap { $0 } }

    /// `Map.prototype.entries()`, snapshotted.
    @inlinable public var entries: [(key: Key, value: Value)] {
        order.compactMap { key in
            key.map { ($0, storage[$0]!.value) }
        }
    }

    /// Removes the holes, keeping insertion order.
    @inlinable internal mutating func compact() {
        var live = 0
        for slot in order.indices {
            guard let key = order[slot] else { continue }
            order[live] = key
            storage[key]!.slot = live
            live += 1
        }
        order.removeLast(order.count - live)
    }
}

extension JSMap.Entry: Sendable where Value: Sendable {}

extension JSMap: Sendable where Key: Sendable, Value: Sendable {}
