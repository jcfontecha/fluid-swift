import FluidJS

/// util/rangeMap.ts: RangeEntry. Property order differs for a written vs split range.
struct RangeEntry<Value> {
    var value: Value
    var length: Int
    var valueFirst: Bool
}
public struct RangeMapEntry<Key, Value> {
    public var start: Key
    public var length: Int
    public var value: Value
}
public struct RangeQueryResultFragment<Value> {
    public var offset: Int
    public var length: Int
    public var value: Value?
}

/// util/rangeMap.ts. Each B-tree entry owns a contiguous range of keys.
public final class RangeMap<Key, Value> {
    let offsetKey: (Key, Int) -> Key
    let subtractKeys: (Key, Key) -> Double
    let offsetValue: (Value, Int) -> Value
    var tree: BTree<Key, RangeEntry<Value>>
    public init(offsetKey: @escaping (Key, Int) -> Key, subtractKeys: @escaping (Key, Key) -> Double,
                offsetValue: @escaping (Value, Int) -> Value = { value, _ in value }, context: BTreeStorageContext = BTreeStorageContext()) {
        self.offsetKey = offsetKey
        self.subtractKeys = subtractKeys
        self.offsetValue = offsetValue
        tree = BTree(context: context, compare: { a, b in
            let difference = subtractKeys(a, b)
            return difference < 0 ? -1 : difference > 0 ? 1 : 0
        })
    }
    public var entries: [RangeMapEntry<Key, Value>] {
        tree.entries.compactMap { key, entry in entry.map { RangeMapEntry(start: key, length: $0.length, value: $0.value) } }
    }
    public func clear() { tree.clear() }
    public func getFirst(_ start: Key, count: Int) -> CrossFieldRange<Value> {
        precondition(count > 0)
        if let (key, entry) = tree.getPairOrNextLower(start), let entry {
            let last = offsetKey(key, entry.length - 1)
            let overlap = min(subtractKeys(last, start) + 1, Double(count))
            if overlap > 0 {
                return CrossFieldRange(length: Int(overlap), value: offsetValue(entry.value, Int(subtractKeys(start, key))))
            }
        }
        if let (key, _) = tree.getPairOrNextHigher(start, inclusive: false), subtractKeys(key, offsetKey(start, count - 1)) <= 0 {
            return CrossFieldRange(length: Int(subtractKeys(key, start)), value: nil)
        }
        return CrossFieldRange(length: count, value: nil)
    }
    public func getAll(_ start: Key, count: Int) -> [RangeQueryResultFragment<Value>] {
        var offset = 0
        var fragments: [RangeQueryResultFragment<Value>] = []
        while offset < count {
            let entry = getFirst(offsetKey(start, offset), count: count - offset)
            fragments.append(.init(offset: offset, length: entry.length, value: entry.value))
            offset += entry.length
        }
        return fragments
    }
    public func set(_ start: Key, count: Int, value: Value?) {
        delete(start, count: count)
        if let value { tree.set(start, RangeEntry(value: value, length: count, valueFirst: true)) }
    }
    @discardableResult public func delete(_ start: Key, count: Int) -> Int {
        precondition(count > 0)
        var deleted = 0
        let lastDelete = offsetKey(start, count - 1)
        for entry in intersectingEntries(start, count: count) {
            deleted += entry.length
            tree.delete(entry.start)
            let before = subtractKeys(start, entry.start)
            if before > 0 {
                tree.set(entry.start, RangeEntry(value: entry.value, length: Int(before), valueFirst: false))
                deleted -= Int(before)
            }
            let after = subtractKeys(offsetKey(entry.start, entry.length - 1), lastDelete)
            if after > 0 {
                let newKey = offsetKey(lastDelete, 1)
                tree.set(newKey, RangeEntry(value: offsetValue(entry.value, Int(subtractKeys(newKey, entry.start))), length: Int(after), valueFirst: false))
                deleted -= Int(after)
            }
        }
        return deleted
    }
    public func clone() -> RangeMap {
        let clone = RangeMap(offsetKey: offsetKey, subtractKeys: subtractKeys, offsetValue: offsetValue, context: tree.context)
        clone.tree = tree.clone()
        return clone
    }
    func intersectingEntries(_ start: Key, count: Int) -> [RangeMapEntry<Key, Value>] {
        var result: [RangeMapEntry<Key, Value>] = []
        let lastQuery = offsetKey(start, count - 1)
        if let (key, entry) = tree.getPairOrNextLower(start), let entry, subtractKeys(offsetKey(key, entry.length - 1), start) >= 0 {
            result.append(.init(start: key, length: entry.length, value: entry.value))
        }
        var next = tree.getPairOrNextHigher(start, inclusive: false)
        while let (key, entry) = next, let entry {
            if subtractKeys(key, lastQuery) > 0 { break }
            result.append(.init(start: key, length: entry.length, value: entry.value))
            next = tree.getPairOrNextHigher(offsetKey(key, entry.length - 1), inclusive: false)
        }
        return result
    }
    public func structure(key: (Key) throws -> JSONValue, value: (Value) throws -> JSONValue) rethrows -> JSONValue {
        let projected = try tree.structure(key: key) { entry in
            let value = try value(entry.value)
            let length = JSONValue.number(Double(entry.length))
            let properties: [(JSString, JSONValue)] = entry.valueFirst ? [(JSString("value"), value), (JSString("length"), length)] : [(JSString("length"), length), (JSString("value"), value)]
            return treeStructureObject(properties)
        }
        return treeStructureObject([("offsetKey", .null), ("subtractKeys", .null), ("offsetValue", .null), ("tree", projected)])
    }
}

extension RangeMap {
    /// util/rangeMap.ts: union preserves the underlying BTree decomposition,
    /// then replaces intersections/residuals in the original callback order.
    static func union(_ first: RangeMap, _ second: RangeMap, merge: (Key, Value, Value) throws -> Value = { _, _, value in value }) throws -> RangeMap {
        let result = RangeMap(offsetKey: first.offsetKey, subtractKeys: first.subtractKeys, offsetValue: first.offsetValue, context: first.tree.context)
        result.tree = try BTree.union(first.tree, second.tree) { _, value, _ in value }
        func choose(_ key: Key?) -> (RangeMapEntry<Key, Value>?, RangeMap, RangeMap) {
            let a = first.getOrNextEntry(key)
            let b = second.getOrNextEntry(key)
            guard let a else { return (b, second, first) }
            guard let b else { return (a, first, second) }
            return first.subtractKeys(a.start, b.start) <= 0 ? (a, first, second) : (b, second, first)
        }
        func residual(_ entry: RangeMapEntry<Key, Value>, count: Int) {
            result.tree.set(entry.start, RangeEntry(value: entry.value, length: count, valueFirst: true))
        }
        var (entry, map1, map2) = choose(nil)
        while let current = entry {
            if let other = map2.getOrNextEntry(current.start) {
                let offset = Int(min(first.subtractKeys(other.start, current.start), Double(current.length)))
                if offset > 0 { residual(current, count: offset) }
                let length = min(current.length - offset, other.length)
                if length > 0 {
                    let value = first.offsetValue(current.value, offset)
                    let a = map1 === first ? value : other.value
                    let b = map1 === first ? other.value : value
                    result.tree.set(other.start, RangeEntry(value: try merge(other.start, a, b), length: length, valueFirst: true))
                    (entry, map1, map2) = choose(first.offsetKey(other.start, length))
                    continue
                }
            }
            residual(current, count: current.length)
            (entry, map1, map2) = choose(first.offsetKey(current.start, current.length))
        }
        return result
    }
    private func getOrNextEntry(_ minimum: Key?) -> RangeMapEntry<Key, Value>? {
        guard let key = minimum ?? tree.root.minKey else { return nil }
        if let (start, entry) = tree.getPairOrNextLower(key), let entry {
            let offset = subtractKeys(key, start)
            if offset >= 0 && offset < Double(entry.length) {
                return RangeMapEntry(start: key, length: entry.length - Int(offset), value: offsetValue(entry.value, Int(offset)))
            }
        }
        guard let (start, entry) = tree.getPairOrNextHigher(key, inclusive: false), let entry else { return nil }
        return RangeMapEntry(start: start, length: entry.length, value: entry.value)
    }
}
