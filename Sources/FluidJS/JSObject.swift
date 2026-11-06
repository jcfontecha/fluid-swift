/// A string-keyed map with JavaScript own-property ordering: array-index keys in ascending numeric
/// order first, then every other key in insertion order. Reassigning an existing key keeps its
/// position; removing and re-adding moves it to the end.
public struct JSObject<Value> {
    @usableFromInline internal var indexKeys: [(index: UInt32, key: JSString)] = []
    @usableFromInline internal var namedKeys: [JSString] = []
    @usableFromInline internal var storage: [JSString: Value] = [:]

    @inlinable public init() {}

    @inlinable public var count: Int { storage.count }
    @inlinable public var isEmpty: Bool { storage.isEmpty }

    @inlinable public subscript(key: JSString) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.isEmpty { storage.reserveCapacity(3) }
                if storage.updateValue(newValue, forKey: key) == nil { insertKey(key) }
            } else if storage.removeValue(forKey: key) != nil {
                removeKey(key)
            }
        }
    }

    /// Keys in `Object.keys` order.
    @inlinable public var keys: [JSString] {
        indexKeys.isEmpty ? namedKeys : indexKeys.map(\.key) + namedKeys
    }

    /// Allocation-free property-order traversal. `keys` remains the array snapshot API.
    @inlinable public var orderedKeys: Keys { Keys(object: self) }

    public struct Keys: RandomAccessCollection {
        public typealias Index = Int
        @usableFromInline internal let object: JSObject<Value>
        @usableFromInline internal init(object: JSObject<Value>) { self.object = object }
        @inlinable public var startIndex: Int { 0 }
        @inlinable public var endIndex: Int { object.count }
        @inlinable public subscript(position: Int) -> JSString {
            position < object.indexKeys.count
                ? object.indexKeys[position].key
                : object.namedKeys[position - object.indexKeys.count]
        }
    }

    /// Entries in `Object.entries` order.
    @inlinable public var entries: [(key: JSString, value: Value)] { Array(orderedEntries) }

    @inlinable public var orderedEntries: Entries { Entries(object: self) }

    /// A copy-on-write snapshot: walking it neither constructs an entries array nor formats keys.
    public struct Entries: RandomAccessCollection {
        public typealias Index = Int
        @usableFromInline internal let object: JSObject<Value>
        @usableFromInline internal init(object: JSObject<Value>) { self.object = object }
        @inlinable public var startIndex: Int { 0 }
        @inlinable public var endIndex: Int { object.count }
        @inlinable public subscript(position: Int) -> (key: JSString, value: Value) {
            let key = position < object.indexKeys.count
                ? object.indexKeys[position].key
                : object.namedKeys[position - object.indexKeys.count]
            return (key, object.storage[key]!)
        }
    }

    @usableFromInline internal mutating func insertKey(_ key: JSString) {
        guard let index = key.arrayIndex else {
            namedKeys.append(key)
            return
        }
        indexKeys.insert((index, key), at: indexKeys.partitioningIndex { $0.index > index })
    }

    @usableFromInline internal mutating func removeKey(_ key: JSString) {
        if let index = key.arrayIndex {
            indexKeys.remove(at: indexKeys.partitioningIndex { $0.index >= index })
        } else {
            namedKeys.remove(at: namedKeys.firstIndex(of: key)!)
        }
    }
}

extension JSObject: Sendable where Value: Sendable {}

extension JSObject: Equatable where Value: Equatable {
    public static func == (lhs: JSObject, rhs: JSObject) -> Bool {
        lhs.indexKeys.elementsEqual(rhs.indexKeys, by: { $0.index == $1.index }) && lhs.namedKeys == rhs.namedKeys && lhs.storage == rhs.storage
    }
}

extension Array {
    /// First index whose element satisfies `predicate`, for a predicate that is false then true
    /// across the (sorted) array.
    @inlinable internal func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
