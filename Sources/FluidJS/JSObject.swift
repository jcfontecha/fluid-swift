/// A string-keyed map with JavaScript own-property ordering: array-index keys in ascending numeric
/// order first, then every other key in insertion order. Reassigning an existing key keeps its
/// position; removing and re-adding moves it to the end.
public struct JSObject<Value> {
    private var indexKeys: [UInt32] = []
    private var namedKeys: [JSString] = []
    private var storage: [JSString: Value] = [:]

    public init() {}

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public subscript(key: JSString) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { insertKey(key) }
            } else if storage.removeValue(forKey: key) != nil {
                removeKey(key)
            }
        }
    }

    /// Keys in `Object.keys` order.
    public var keys: [JSString] {
        indexKeys.map { JSString(String($0)) } + namedKeys
    }

    /// Entries in `Object.entries` order.
    public var entries: [(key: JSString, value: Value)] {
        keys.map { ($0, storage[$0]!) }
    }

    private mutating func insertKey(_ key: JSString) {
        guard let index = key.arrayIndex else {
            namedKeys.append(key)
            return
        }
        indexKeys.insert(index, at: indexKeys.partitioningIndex { $0 > index })
    }

    private mutating func removeKey(_ key: JSString) {
        if let index = key.arrayIndex {
            indexKeys.remove(at: indexKeys.partitioningIndex { $0 >= index })
        } else {
            namedKeys.remove(at: namedKeys.firstIndex(of: key)!)
        }
    }
}

extension JSObject: Sendable where Value: Sendable {}

extension JSObject: Equatable where Value: Equatable {
    public static func == (lhs: JSObject, rhs: JSObject) -> Bool {
        lhs.indexKeys == rhs.indexKeys && lhs.namedKeys == rhs.namedKeys && lhs.storage == rhs.storage
    }
}

extension Array {
    /// First index whose element satisfies `predicate`, for a predicate that is false then true
    /// across the (sorted) array.
    fileprivate func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
