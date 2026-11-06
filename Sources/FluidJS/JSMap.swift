/// A JavaScript `Map`: iteration follows insertion order for every key (unlike `JSObject`, array-index
/// keys are not hoisted). Setting an existing key keeps its position; deleting and re-adding moves it
/// to the end.
public struct JSMap<Key: Hashable, Value> {
    @usableFromInline internal var order: [Key] = []
    @usableFromInline internal var storage: [Key: Value] = [:]

    @inlinable public init() {}

    @inlinable public var size: Int { storage.count }

    @inlinable public func get(_ key: Key) -> Value? {
        storage[key]
    }

    @inlinable public func has(_ key: Key) -> Bool {
        storage[key] != nil
    }

    @inlinable public mutating func set(_ key: Key, _ value: Value) {
        if storage.updateValue(value, forKey: key) == nil {
            order.append(key)
        }
    }

    /// Returns whether the key was present, as `Map.prototype.delete` does.
    @discardableResult
    @inlinable public mutating func delete(_ key: Key) -> Bool {
        guard storage.removeValue(forKey: key) != nil else {
            return false
        }
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        return true
    }

    @inlinable public mutating func clear() {
        order.removeAll()
        storage.removeAll()
    }

    /// `Map.prototype.keys()`, snapshotted.
    @inlinable public var keys: [Key] { order }

    /// `Map.prototype.entries()`, snapshotted.
    @inlinable public var entries: [(key: Key, value: Value)] {
        order.compactMap { key in
            storage[key].map { (key, $0) }
        }
    }
}

extension JSMap: Sendable where Key: Sendable, Value: Sendable {}
