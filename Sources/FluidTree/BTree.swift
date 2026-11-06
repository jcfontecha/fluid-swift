import FluidJS

/// @tylerbu/sorted-btree-es6/b+tree.js: module-scoped undefVals storage.
/// Containers share this context among their trees, not among unrelated actors.
private protocol BTreePoolEntry {}
private struct BTreePoolBox<Value>: BTreePoolEntry {
    let value: Value
}
public final class BTreeStorageContext {
    var undefinedValueCount = 0
    private var pool: [Int: any BTreePoolEntry] = [:]
    public init() {}
    func poolValue<Value>(_ index: Int, as type: Value.Type) -> Value? {
        guard let entry = pool[index] else { return nil }
        guard let box = entry as? BTreePoolBox<Value> else {
            preconditionFailure("shared BTree pool contains an incompatible native value type")
        }
        return box.value
    }
    func setPoolValue<Value>(_ index: Int, _ value: Value?) {
        if let value { pool[index] = BTreePoolBox(value: value) }
        else { pool[index] = nil }
        undefinedValueCount = max(undefinedValueCount, index + 1)
    }
    func projectPool<Value>(_ type: Value.Type, value: (Value) throws -> JSONValue) rethrows -> [JSONValue] {
        try (0..<undefinedValueCount).map { index in try poolValue(index, as: type).map(value) ?? treeStructureUndefined }
    }
}

enum BTreeInsertResult<Key, Value> {
    case existing
    case inserted
    case split(BNode<Key, Value>)
}
public enum BTreeEdit<Value> {
    case keep
    case replace(Value?)
    case delete
}

/// @tylerbu/sorted-btree-es6/b+tree.js: BTree (pinned 2.1.1).
public final class BTree<Key, Value> {
    var root: BNode<Key, Value>
    let compare: (Key, Key) -> Int
    public let maxNodeSize: Int
    public let context: BTreeStorageContext
    public init(maxNodeSize: Int = 32, context: BTreeStorageContext = BTreeStorageContext(), compare: @escaping (Key, Key) -> Int) {
        self.maxNodeSize = maxNodeSize >= 4 ? min(maxNodeSize, 256) : 32
        self.context = context
        self.compare = compare
        root = BNode(context: context)
        root.isShared = true
    }
    public var count: Int { root.size }
    public var isEmpty: Bool { count == 0 }
    public var entries: [(Key, Value?)] { root.entries }
    public func get(_ key: Key) -> Value? { root.get(key, compare: compare) }
    public func has(_ key: Key) -> Bool {
        guard let pair = getPairOrNextHigher(key) else { return false }
        return compare(pair.0, key) == 0
    }
    @discardableResult public func set(_ key: Key, _ value: Value?, overwrite: Bool = true) -> Bool {
        if root.isShared == true { root = root.clone() }
        switch root.set(key, value: value, overwrite: overwrite, tree: self) {
        case .existing: return false
        case .inserted: return true
        case .split(let right):
            root = BNodeInternal(children: [root, right])
            return true
        }
    }
    @discardableResult public func delete(_ key: Key) -> Bool {
        editRange(key, key) { _, _ in .delete } != 0
    }
    public func clear() {
        root = BNode(context: context)
        root.isShared = true
    }
    public func clone() -> BTree {
        root.isShared = true
        let result = BTree(maxNodeSize: maxNodeSize, context: context, compare: compare)
        result.root = root
        return result
    }
    public func greedyClone(force: Bool = false) -> BTree {
        let result = BTree(maxNodeSize: maxNodeSize, context: context, compare: compare)
        result.root = root.greedyClone(force: force)
        return result
    }
    public func mapValues(_ transform: (Value?, Key) throws -> Value?) rethrows -> BTree {
        let result = greedyClone()
        try result.editAll { key, value in .replace(try transform(value, key)) }
        return result
    }
    /// b+tree.js minKey: the lowest key, or nil when empty.
    public func minKey() -> Key? { root.minKey }
    /// b+tree.js maxKey: the highest key, or nil when empty.
    public func maxKey() -> Key? { isEmpty ? nil : root.maxKey() }
    /// b+tree.js nextHigherKey: the lowest key strictly greater than `key`.
    public func nextHigherKey(_ key: Key) -> Key? { getPairOrNextHigher(key, inclusive: false)?.0 }
    /// b+tree.js getRange: pairs with `low <= key < high` (`<= high` when `includeHigh`), ascending.
    public func getRange(_ low: Key, _ high: Key, includeHigh: Bool = false) -> [(Key, Value?)] {
        entries.filter { entry in
            let upper = compare(entry.0, high)
            return compare(entry.0, low) >= 0 && (includeHigh ? upper <= 0 : upper < 0)
        }
    }
    public func getPairOrNextHigher(_ key: Key, inclusive: Bool = true) -> (Key, Value?)? {
        root.neighbor(key, higher: true, inclusive: inclusive, compare: compare)
    }
    public func getPairOrNextLower(_ key: Key, inclusive: Bool = true) -> (Key, Value?)? {
        root.neighbor(key, higher: false, inclusive: inclusive, compare: compare)
    }
    @discardableResult public func editAll(_ edit: (Key, Value?) throws -> BTreeEdit<Value>) rethrows -> Int {
        try editRange(root.minKey, root.keys.last, edit: edit)
    }
    @discardableResult public func editRange(_ low: Key?, _ high: Key?, includeHigh: Bool = true, edit: (Key, Value?) throws -> BTreeEdit<Value>) rethrows -> Int {
        if root.isShared == true { root = root.clone() }
        defer {
            var shared = false
            while let inner = root as? BNodeInternal<Key, Value>, inner.keys.count <= 1 {
                shared = shared || inner.isShared == true
                if inner.keys.isEmpty { clear() } else { root = inner.children[0] }
            }
            if shared { root.isShared = true }
        }
        guard let low, let high else { return 0 }
        return try root.editRange(low, high, includeHigh: includeHigh, tree: self, edit: edit)
    }
    public func structure(key: (Key) throws -> JSONValue, value: (Value) throws -> JSONValue) rethrows -> JSONValue {
        try treeStructureObject([
            ("_root", root.structure(context: context, key: key, value: value)),
            ("_maxNodeSize", .number(Double(maxNodeSize))),
            ("_compare", .null),
        ])
    }
}

func treeStructureObject(_ entries: [(JSString, JSONValue)]) -> JSONValue {
    .array([.string("object"), .array(entries.map { .array([.string($0.0), $0.1]) })])
}
func treeStructureArray(_ values: [JSONValue]) -> JSONValue { .array([.string("array"), .array(values)]) }
var treeStructureUndefined: JSONValue { .array([.string("undefined")]) }

/// @tylerbu/sorted-btree-es6/b+tree.js: BNode (leaf and shared node operations).
class BNode<Key, Value> {
    var keys: [Key]
    // nil is the shared undefVals pool, distinct from a private array of nils.
    var values: [Value?]?
    var isShared: Bool?
    let context: BTreeStorageContext
    init(keys: [Key] = [], values: [Value?]? = nil, context: BTreeStorageContext) {
        self.context = context
        self.keys = keys
        self.values = values
    }
    var size: Int { keys.count }
    var minKey: Key? { keys.first }
    var minPair: (Key, Value?)? { keys.isEmpty ? nil : (keys[0], value(at: 0)) }
    var maxPair: (Key, Value?)? { keys.isEmpty ? nil : (keys[keys.count - 1], value(at: keys.count - 1)) }
    var entries: [(Key, Value?)] { keys.indices.map { (keys[$0], value(at: $0)) } }
    func value(at index: Int) -> Value? {
        if let values { return values[index] }
        return context.poolValue(index, as: Value.self)
    }
    func maxKey() -> Key {
        precondition(!keys.isEmpty)
        return keys[keys.count - 1]
    }
    func indexOf(_ key: Key, compare: (Key, Key) -> Int) -> (index: Int, found: Bool) {
        var low = 0
        var high = keys.count
        while low < high {
            let middle = (low + high) / 2
            let order = compare(keys[middle], key)
            if order < 0 { low = middle + 1 }
            else if order > 0 { high = middle }
            else { return (middle, true) }
        }
        return (low, false)
    }
    func clone() -> BNode { BNode(keys: keys, values: values, context: context) }
    func greedyClone(force: Bool) -> BNode { isShared == true && !force ? self : clone() }
    func get(_ key: Key, compare: (Key, Key) -> Int) -> Value? {
        let found = indexOf(key, compare: compare)
        return found.found ? value(at: found.index) : nil
    }
    func neighbor(_ key: Key, higher: Bool, inclusive: Bool, compare: (Key, Key) -> Int) -> (Key, Value?)? {
        let found = indexOf(key, compare: compare)
        let index = higher ? found.index + (found.found && !inclusive ? 1 : 0) : found.index - (!found.found || !inclusive ? 1 : 0)
        return keys.indices.contains(index) ? (keys[index], value(at: index)) : nil
    }
    func set(_ key: Key, value: Value?, overwrite: Bool, tree: BTree<Key, Value>) -> BTreeInsertResult<Key, Value> {
        let found = indexOf(key, compare: tree.compare)
        if found.found {
            if overwrite {
                if value != nil { reifyValues() }
                keys[found.index] = key
                if values != nil { values?[found.index] = value }
                else { context.setPoolValue(found.index, value) }
            }
            return .existing
        }
        if keys.count < tree.maxNodeSize {
            insertInLeaf(found.index, key: key, value: value, tree: tree)
            return .inserted
        }
        let right = splitOffRightSide()
        if found.index > keys.count { right.insertInLeaf(found.index - keys.count, key: key, value: value, tree: tree) }
        else { insertInLeaf(found.index, key: key, value: value, tree: tree) }
        return .split(right)
    }
    func reifyValues() {
        if values == nil { values = (0..<keys.count).map { context.poolValue($0, as: Value.self) } }
    }
    func insertInLeaf(_ index: Int, key: Key, value: Value?, tree: BTree<Key, Value>) {
        keys.insert(key, at: index)
        if values == nil {
            tree.context.undefinedValueCount = max(tree.context.undefinedValueCount, tree.maxNodeSize)
            if value == nil { return }
            values = (0..<(keys.count - 1)).map { context.poolValue($0, as: Value.self) }
        }
        values?.insert(value, at: index)
    }
    func splitOffRightSide() -> BNode {
        let half = keys.count / 2
        let right = BNode(keys: Array(keys[half...]), values: values.map { Array($0[half...]) }, context: context)
        keys.removeSubrange(half...)
        values?.removeSubrange(half...)
        return right
    }
    func takeFromRight(_ right: BNode) {
        if right.values == nil {
            values?.append(nil)
        } else {
            reifyValues()
            values?.append(right.values?.removeFirst())
        }
        keys.append(right.keys.removeFirst())
    }
    func takeFromLeft(_ left: BNode) {
        if left.values == nil {
            values?.insert(nil, at: 0)
        } else {
            reifyValues()
            values?.insert(left.values?.removeLast(), at: 0)
        }
        keys.insert(left.keys.removeLast(), at: 0)
    }
    func editRange(_ low: Key, _ high: Key, includeHigh: Bool, tree: BTree<Key, Value>, edit: (Key, Value?) throws -> BTreeEdit<Value>) rethrows -> Int {
        var index = indexOf(low, compare: tree.compare).index
        let upper = indexOf(high, compare: tree.compare)
        var end = upper.index + (upper.found && includeHigh ? 1 : 0)
        var count = 0
        while index < end {
            let action = try edit(keys[index], value(at: index))
            count += 1
            switch action {
            case .keep: break
            case .replace(let value):
                // Pinned JS writes directly into undefVals rather than reifying it.
                if values != nil { values?[index] = value }
                else { context.setPoolValue(index, value) }
            case .delete:
                keys.remove(at: index)
                values?.remove(at: index)
                index -= 1
                end -= 1
            }
            index += 1
        }
        return count
    }
    func mergeSibling(_ right: BNode, maxNodeSize: Int) {
        keys.append(contentsOf: right.keys)
        if values == nil {
            if right.values == nil { return }
            values = (0..<keys.count).map { context.poolValue($0, as: Value.self) }
        }
        right.reifyValues()
        if let other = right.values { values?.append(contentsOf: other) }
    }
    func structure(context: BTreeStorageContext, key: (Key) throws -> JSONValue, value: (Value) throws -> JSONValue) rethrows -> JSONValue {
        let projectedValues = try values.map { try $0.map { try $0.map(value) ?? treeStructureUndefined } }
            ?? context.projectPool(Value.self, value: value)
        return try treeStructureObject([
            ("keys", treeStructureArray(keys.map(key))),
            ("values", treeStructureArray(projectedValues)),
            ("isShared", isShared.map(JSONValue.bool) ?? treeStructureUndefined),
        ])
    }
}

/// @tylerbu/sorted-btree-es6/b+tree.js: BNodeInternal.
final class BNodeInternal<Key, Value>: BNode<Key, Value> {
    var children: [BNode<Key, Value>]
    var cachedSize: Int
    init(children: [BNode<Key, Value>], keys: [Key]? = nil) {
        self.children = children
        cachedSize = children.reduce(0) { $0 + $1.size }
        precondition(!children.isEmpty)
        super.init(keys: keys ?? children.map { $0.maxKey() }, context: children[0].context)
    }
    override var size: Int { cachedSize }
    override var minKey: Key? { children.first?.minKey }
    override var minPair: (Key, Value?)? { children.first?.minPair }
    override var maxPair: (Key, Value?)? { children.last?.maxPair }
    override var entries: [(Key, Value?)] { children.flatMap(\.entries) }
    override func clone() -> BNode<Key, Value> {
        for child in children { child.isShared = true }
        let cloned = BNodeInternal(children: children, keys: keys)
        cloned.cachedSize = cachedSize
        return cloned
    }
    override func greedyClone(force: Bool) -> BNode<Key, Value> {
        if isShared == true && !force { return self }
        let cloned = BNodeInternal(children: children.map { $0.greedyClone(force: force) }, keys: keys)
        cloned.cachedSize = cachedSize
        return cloned
    }
    override func get(_ key: Key, compare: (Key, Key) -> Int) -> Value? {
        let index = indexOf(key, compare: compare).index
        return index < children.count ? children[index].get(key, compare: compare) : nil
    }
    override func neighbor(_ key: Key, higher: Bool, inclusive: Bool, compare: (Key, Key) -> Int) -> (Key, Value?)? {
        let index = indexOf(key, compare: compare).index
        if index >= children.count {
            if higher { return nil }
            return children.last?.maxPair
        }
        if let found = children[index].neighbor(key, higher: higher, inclusive: inclusive, compare: compare) { return found }
        if higher { return index + 1 < children.count ? children[index + 1].minPair : nil }
        return index > 0 ? children[index - 1].maxPair : nil
    }
    override func set(_ key: Key, value: Value?, overwrite: Bool, tree: BTree<Key, Value>) -> BTreeInsertResult<Key, Value> {
        let index = min(indexOf(key, compare: tree.compare).index, children.count - 1)
        if children[index].isShared == true { children[index] = children[index].clone() }
        let child = children[index]
        if child.keys.count >= tree.maxNodeSize {
            if index > 0 && children[index - 1].keys.count < tree.maxNodeSize && tree.compare(child.keys[0], key) < 0 {
                if children[index - 1].isShared == true { children[index - 1] = children[index - 1].clone() }
                children[index - 1].takeFromRight(child)
                keys[index - 1] = children[index - 1].maxKey()
            } else if index + 1 < children.count && children[index + 1].keys.count < tree.maxNodeSize && tree.compare(child.maxKey(), key) < 0 {
                if children[index + 1].isShared == true { children[index + 1] = children[index + 1].clone() }
                children[index + 1].takeFromLeft(child)
                keys[index] = child.maxKey()
            }
        }
        let oldSize = child.size
        let result = child.set(key, value: value, overwrite: overwrite, tree: tree)
        cachedSize += child.size - oldSize
        if case .existing = result { return result }
        keys[index] = child.maxKey()
        guard case .split(let newChild) = result else { return .inserted }
        if keys.count < tree.maxNodeSize {
            insert(index + 1, child: newChild)
            return .inserted
        }
        let right = splitOffRightSide()
        guard let innerRight = right as? BNodeInternal else { preconditionFailure("internal split must return internal node") }
        if tree.compare(newChild.maxKey(), maxKey()) > 0 { innerRight.insert(index - keys.count + 1, child: newChild) }
        else { insert(index + 1, child: newChild) }
        return .split(right)
    }
    func insert(_ index: Int, child: BNode<Key, Value>) {
        children.insert(child, at: index)
        keys.insert(child.maxKey(), at: index)
        cachedSize += child.size
    }
    override func splitOffRightSide() -> BNode<Key, Value> {
        let half = children.count / 2
        let previousSize = cachedSize
        let right = BNodeInternal(children: Array(children[half...]), keys: Array(keys[half...]))
        children.removeSubrange(half...)
        keys.removeSubrange(half...)
        cachedSize = children.reduce(0) { $0 + $1.size }
        right.cachedSize = previousSize - cachedSize
        return right
    }
    override func takeFromRight(_ right: BNode<Key, Value>) {
        guard let right = right as? BNodeInternal else { preconditionFailure("mixed tree heights") }
        let child = right.children.removeFirst()
        keys.append(right.keys.removeFirst())
        children.append(child)
        right.cachedSize -= child.size
        cachedSize += child.size
    }
    override func takeFromLeft(_ left: BNode<Key, Value>) {
        guard let left = left as? BNodeInternal else { preconditionFailure("mixed tree heights") }
        let child = left.children.removeLast()
        keys.insert(left.keys.removeLast(), at: 0)
        children.insert(child, at: 0)
        left.cachedSize -= child.size
        cachedSize += child.size
    }
    override func editRange(_ low: Key, _ high: Key, includeHigh: Bool, tree: BTree<Key, Value>, edit: (Key, Value?) throws -> BTreeEdit<Value>) rethrows -> Int {
        let lowIndex = indexOf(low, compare: tree.compare).index
        let highIndex = min(indexOf(high, compare: tree.compare).index, keys.count - 1)
        guard lowIndex <= highIndex else { return 0 }
        defer {
            let start = max(0, lowIndex - 1)
            for index in stride(from: highIndex, through: start, by: -1) {
                if children[index].keys.count <= tree.maxNodeSize / 2 {
                    if children[index].keys.isEmpty {
                        keys.remove(at: index)
                        children.remove(at: index)
                    } else {
                        tryMerge(index, maxSize: tree.maxNodeSize)
                    }
                }
            }
        }
        var count = 0
        for index in lowIndex...highIndex {
            if children[index].isShared == true { children[index] = children[index].clone() }
            let child = children[index]
            let oldSize = child.size
            count += try child.editRange(low, high, includeHigh: includeHigh, tree: tree, edit: edit)
            if !child.keys.isEmpty { keys[index] = child.maxKey() }
            cachedSize += child.size - oldSize
        }
        return count
    }
    func tryMerge(_ index: Int, maxSize: Int) {
        guard index >= 0 && index + 1 < children.count else { return }
        guard children[index].keys.count + children[index + 1].keys.count <= maxSize else { return }
        if children[index].isShared == true { children[index] = children[index].clone() }
        children[index].mergeSibling(children[index + 1], maxNodeSize: maxSize)
        children.remove(at: index + 1)
        keys.remove(at: index + 1)
        keys[index] = children[index].maxKey()
    }
    override func mergeSibling(_ right: BNode<Key, Value>, maxNodeSize: Int) {
        guard let right = right as? BNodeInternal else { preconditionFailure("mixed tree heights") }
        let oldLength = keys.count
        keys.append(contentsOf: right.keys)
        children.append(contentsOf: right.children)
        cachedSize += right.size
        if right.isShared == true && isShared != true {
            for child in right.children { child.isShared = true }
        }
        tryMerge(oldLength - 1, maxSize: maxNodeSize)
    }
    override func structure(context: BTreeStorageContext, key: (Key) throws -> JSONValue, value: (Value) throws -> JSONValue) rethrows -> JSONValue {
        try treeStructureObject([
            ("keys", treeStructureArray(keys.map(key))),
            ("values", treeStructureArray(context.projectPool(Value.self, value: value))),
            ("isShared", isShared.map(JSONValue.bool) ?? treeStructureUndefined),
            ("children", treeStructureArray(children.map { try $0.structure(context: context, key: key, value: value) })),
            ("_size", .number(Double(cachedSize))),
        ])
    }
}

extension BTree {
    /// Typed mapValues for changes such as TreeChunk -> destruction count.
    public func mapValuesAs<Output>(_ transform: (Value?, Key) throws -> Output?) rethrows -> BTree<Key, Output> {
        let working = greedyClone()
        // Realize the same COW paths and merge opportunities as JS editAll.
        working.editAll { _, _ in .keep }
        func convert(_ node: BNode<Key, Value>) throws -> BNode<Key, Output> {
            if let internalNode = node as? BNodeInternal<Key, Value> {
                return BNodeInternal<Key, Output>(children: try internalNode.children.map(convert), keys: internalNode.keys)
            }
            let values = try node.keys.indices.map { try transform(node.value(at: $0), node.keys[$0]) }
            return BNode<Key, Output>(keys: node.keys, values: values, context: context)
        }
        let result = BTree<Key, Output>(maxNodeSize: maxNodeSize, context: context, compare: compare)
        result.root = try convert(working.root)
        return result
    }
}
