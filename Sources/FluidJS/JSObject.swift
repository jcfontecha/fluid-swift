/// A string-keyed map with JavaScript own-property ordering: array-index keys in ascending numeric
/// order first, then every other key in insertion order. Reassigning an existing key keeps its
/// position; removing and re-adding moves it to the end.
///
/// Properties live in one array already in that order, so iteration and encoding walk it directly.
/// Small objects (most wire envelopes and ops) are searched linearly; a key → position index is
/// built only once an object grows past `indexThreshold` properties.
public struct JSObject<Value> {
    @usableFromInline internal struct Property {
        @usableFromInline internal let key: JSString
        @usableFromInline internal var value: Value

        @inlinable internal init(key: JSString, value: Value) {
            self.key = key
            self.value = value
        }
    }

    /// Properties in `Object.keys` order.
    @usableFromInline internal var properties: ContiguousArray<Property> = []
    /// Position of every key in `properties`; nil while the object is small enough to scan.
    @usableFromInline internal var positions: [JSString: Int]?

    @usableFromInline internal static var indexThreshold: Int { 16 }

    @inlinable public init() {}

    @inlinable public var count: Int { properties.count }
    @inlinable public var isEmpty: Bool { properties.isEmpty }

    @inlinable public subscript(key: JSString) -> Value? {
        get {
            guard let position = position(of: key) else { return nil }
            return properties[position].value
        }
        set {
            guard let newValue else {
                if let position = position(of: key) { remove(at: position) }
                return
            }
            let position = positions == nil ? position(of: key) : claimPosition(of: key)
            if let position, position < properties.count {
                properties[position].value = newValue
            } else {
                insert(Property(key: key, value: newValue))
            }
        }
    }

    /// Keys in `Object.keys` order.
    @inlinable public var keys: [JSString] { properties.map(\.key) }

    /// Allocation-free property-order traversal. `keys` remains the array snapshot API.
    @inlinable public var orderedKeys: Keys { Keys(object: self) }

    public struct Keys: RandomAccessCollection {
        public typealias Index = Int
        @usableFromInline internal let object: JSObject<Value>
        @usableFromInline internal init(object: JSObject<Value>) { self.object = object }
        @inlinable public var startIndex: Int { 0 }
        @inlinable public var endIndex: Int { object.count }
        @inlinable public subscript(position: Int) -> JSString { object.properties[position].key }
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
            let property = object.properties[position]
            return (property.key, property.value)
        }
    }

    @inlinable internal func position(of key: JSString) -> Int? {
        if let positions {
            return positions[key]
        }
        var position = 0
        while position < properties.count {
            if properties[position].key == key { return position }
            position += 1
        }
        return nil
    }

    /// The key's position in an indexed object; a new key is recorded at `count`, the end. One hash
    /// probe either way, where a lookup followed by an insertion would take two.
    @inlinable internal mutating func claimPosition(of key: JSString) -> Int {
        let end = properties.count
        return Self.read(&positions![key, default: end])
    }

    @inlinable internal static func read(_ position: inout Int) -> Int { position }

    /// Adds a key that is not present: named keys append; array-index keys go after every smaller
    /// index and before the first larger index or named key. An indexed object has already claimed
    /// the end position for the key.
    @inlinable internal mutating func insert(_ property: Property) {
        if properties.isEmpty {
            // Most objects are small; skip the 1 → 2 → 4 growth steps.
            properties.reserveCapacity(4)
        }
        var position = properties.count
        if let index = property.key.arrayIndex {
            // Ascending construction (the common case) appends without searching.
            let appends = properties.last.map { $0.key.arrayIndex.map { $0 < index } ?? false } ?? true
            if !appends {
                position = properties.partitioningIndex { $0.key.arrayIndex.map { $0 > index } ?? true }
            }
        }
        if position == properties.count {
            properties.append(property)
        } else {
            properties.insert(property, at: position)
            if positions != nil { reindex(from: position) }
        }
        if positions == nil, properties.count > Self.indexThreshold {
            reindex(from: 0)
        }
    }

    @inlinable internal mutating func remove(at position: Int) {
        let key = properties.remove(at: position).key
        guard positions != nil else { return }
        positions![key] = nil
        reindex(from: position)
    }

    /// Records the position of every property from `start` on.
    @inlinable internal mutating func reindex(from start: Int) {
        var positions = self.positions ?? Dictionary(minimumCapacity: properties.count)
        self.positions = nil
        for position in start..<properties.count {
            positions[properties[position].key] = position
        }
        self.positions = positions
    }
}

extension JSObject.Property: Sendable where Value: Sendable {}

extension JSObject: Sendable where Value: Sendable {}

extension JSObject: Equatable where Value: Equatable {
    /// The same keys in the same order with equal values.
    public static func == (lhs: JSObject, rhs: JSObject) -> Bool {
        lhs.properties.elementsEqual(rhs.properties) { $0.key == $1.key && $0.value == $1.value }
    }
}

extension ContiguousArray {
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
