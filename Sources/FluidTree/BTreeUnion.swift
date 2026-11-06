import FluidJS

extension BTree {
    /// @tylerbu/sorted-btree-es6/extended/union.js. Callers use the same key order.
    static func union(_ left: BTree, _ right: BTree, combine: (Key, Value?, Value?) throws -> Value?) throws -> BTree {
        if left === right { return left.clone() }
        guard left.maxNodeSize == right.maxNodeSize else { throw JSONDecodingError("BTree union requires matching node sizes") }
        if left.isEmpty { return right.clone() }
        if right.isEmpty { return left.clone() }
        let decomposition = BTreeUnionDecomposition(left: left, right: right)
        try decomposition.run(combine: combine)
        return BTreeUnionReconstruction(decomposition: decomposition, template: left).build()
    }
}

private final class UnionCursor<Key, Value> {
    struct Spine {
        let node: BNodeInternal<Key, Value>
        var index: Int
        var disqualified = false
    }
    let tree: BTree<Key, Value>
    var leaf: BNode<Key, Value>
    var index = 0
    var disqualified = false
    var spine: [Spine] = []
    init(_ tree: BTree<Key, Value>) {
        self.tree = tree
        leaf = tree.root
        while let inner = leaf as? BNodeInternal<Key, Value> {
            spine.append(Spine(node: inner, index: 0))
            leaf = inner.children[0]
        }
    }
    var key: Key { leaf.keys[index] }
}

/// extended/decompose.js and parallelWalk.js: the alternating cursor traversal.
final class BTreeUnionDecomposition<Key, Value> {
    let left: BTree<Key, Value>
    let right: BTree<Key, Value>
    var heights: [Int] = []
    var nodes: [BNode<Key, Value>] = []
    var tallestIndex = -1
    private var tallestHeight = -1
    private var pendingKeys: [Key] = []
    private var pendingValues: [Value?] = []
    private var highestDisjoint: (node: BNode<Key, Value>, height: Int)?
    private enum Descent { case up, out, index(Int) }
    init(left: BTree<Key, Value>, right: BTree<Key, Value>) {
        self.left = left
        self.right = right
    }
    private func overlaps(_ aMin: Key, _ aMax: Key, _ bMin: Key, _ bMax: Key) -> Bool {
        left.compare(aMin, bMax) <= 0 && left.compare(aMax, bMin) >= 0
    }
    private func flushPending() {
        var remaining = pendingKeys.count
        var leaves = remaining <= left.maxNodeSize ? (remaining == 0 ? 0 : 1) : Int((Double(remaining) / (Double(left.maxNodeSize) * 0.7).rounded(.up)).rounded(.up))
        var start = 0
        while leaves > 0 {
            let count = (remaining + leaves - 1) / leaves
            let end = start + count
            let node = BNode(keys: Array(pendingKeys[start..<end]), values: Array(pendingValues[start..<end]), context: left.context)
            nodes.append(node)
            heights.append(count < left.maxNodeSize / 2 ? -1 : 0)
            start = end
            remaining -= count
            leaves -= 1
        }
        pendingKeys.removeAll(keepingCapacity: true)
        pendingValues.removeAll(keepingCapacity: true)
    }
    private func addShared(_ node: BNode<Key, Value>, height: Int) {
        flushPending()
        if !(node is BNodeInternal<Key, Value>) && node.keys.count < left.maxNodeSize / 2 {
            heights.append(-1)
            nodes.append(node.clone())
        } else {
            node.isShared = true
            heights.append(height)
            nodes.append(node)
        }
        if height > tallestHeight {
            tallestIndex = heights.count - 1
            tallestHeight = height
        }
    }
    private func addHighest() {
        if let highestDisjoint { addShared(highestDisjoint.node, height: highestDisjoint.height) }
        highestDisjoint = nil
    }
    private func disqualify(_ cursor: UnionCursor<Key, Value>, from depth: Int) {
        guard depth >= 0 else { return }
        for index in stride(from: depth, through: 0, by: -1) {
            if cursor.spine[index].disqualified { break }
            cursor.spine[index].disqualified = true
        }
    }
    private func pushRange(_ leaf: BNode<Key, Value>, from: Int, to: Int) {
        guard from < to else { return }
        pendingKeys.append(contentsOf: leaf.keys[from..<to])
        pendingValues.append(contentsOf: (from..<to).map { leaf.value(at: $0) })
    }
    private func exitLeaf(_ cursor: UnionCursor<Key, Value>, startedEqual: Bool) {
        highestDisjoint = nil
        if !cursor.disqualified {
            highestDisjoint = (cursor.leaf, 0)
            if cursor.spine.isEmpty { addHighest() }
        } else {
            pushRange(cursor.leaf, from: cursor.index + (startedEqual ? 1 : 0), to: cursor.leaf.keys.count)
        }
    }
    private func stepUp(_ cursor: UnionCursor<Key, Value>, depth: Int, height: Int, descent: Descent) {
        let entry = cursor.spine[depth]
        let children = entry.node.children
        switch descent {
        case .up, .out:
            if !entry.disqualified {
                if case .out = descent {
                    if entry.node.keys.count < left.maxNodeSize / 2 {
                        for child in children[entry.index...] { addShared(child, height: height - 1) }
                    } else { addShared(entry.node, height: height) }
                    highestDisjoint = nil
                } else { highestDisjoint = (entry.node, height) }
            } else {
                addHighest()
                if entry.index + 1 < children.count {
                    for child in children[(entry.index + 1)...] { addShared(child, height: height - 1) }
                }
            }
        case .index(let destination):
            if destination > 0 { disqualify(cursor, from: depth) }
            addHighest()
            if entry.index + 1 < destination {
                for child in children[(entry.index + 1)..<destination] { addShared(child, height: height - 1) }
            }
        }
    }
    private func enterLeaf(_ cursor: UnionCursor<Key, Value>, other: UnionCursor<Key, Value>) {
        if cursor.index > 0 || overlaps(cursor.leaf.keys[0], cursor.leaf.maxKey(), other.key, other.leaf.maxKey()) {
            cursor.disqualified = true
            other.disqualified = true
            disqualify(cursor, from: cursor.spine.count - 1)
            disqualify(other, from: other.spine.count - 1)
            pushRange(cursor.leaf, from: 0, to: cursor.index)
        }
    }
    private func moveTo(_ cursor: UnionCursor<Key, Value>, other: UnionCursor<Key, Value>, target: Key, inclusive: Bool, startedEqual: Bool) -> (out: Bool, equal: Bool) {
        let found = cursor.leaf.indexOf(target, compare: left.compare)
        let destination = found.index + (found.found && !inclusive ? 1 : 0)
        if destination < cursor.leaf.keys.count {
            pushRange(cursor.leaf, from: cursor.index + (startedEqual ? 1 : 0), to: destination)
            cursor.index = destination
            return (false, found.found && inclusive)
        }
        let oldHeight = cursor.spine.count
        var descentLevel: Int?
        var descentIndex = -1
        if oldHeight > 0 {
            for depth in stride(from: oldHeight - 1, through: 0, by: -1) {
                let parent = cursor.spine[depth].node
                let found = parent.indexOf(target, compare: left.compare)
                let next = found.index + (found.found && !inclusive ? 1 : 0)
                if next < parent.keys.count {
                    descentLevel = depth
                    descentIndex = next
                    break
                }
            }
        }
        exitLeaf(cursor, startedEqual: startedEqual)
        guard let descentLevel else {
            if oldHeight > 0 {
                for depth in stride(from: oldHeight - 1, through: 0, by: -1) {
                    stepUp(cursor, depth: depth, height: oldHeight - depth, descent: depth == 0 ? .out : .up)
                }
            }
            return (true, false)
        }
        if oldHeight - 1 > descentLevel {
            for depth in stride(from: oldHeight - 1, through: descentLevel + 1, by: -1) { stepUp(cursor, depth: depth, height: oldHeight - depth, descent: .up) }
        }
        stepUp(cursor, depth: descentLevel, height: oldHeight - descentLevel, descent: .index(descentIndex))
        cursor.spine[descentLevel].index = descentIndex
        var height = oldHeight - descentLevel - 1
        cursor.spine.removeSubrange((descentLevel + 1)...)
        var node = cursor.spine[descentLevel].node.children[descentIndex]
        while let inner = node as? BNodeInternal<Key, Value> {
            let found = inner.indexOf(target, compare: left.compare)
            let next = found.index + (found.found && !inclusive ? 1 : 0)
            cursor.spine.append(.init(node: inner, index: next))
            if next > 0 {
                disqualify(cursor, from: cursor.spine.count - 1)
                for child in inner.children[..<next] { addShared(child, height: height - 1) }
            }
            node = inner.children[next]
            height -= 1
        }
        let leafFound = node.indexOf(target, compare: left.compare)
        cursor.leaf = node
        cursor.disqualified = false
        cursor.index = leafFound.index + (leafFound.found && !inclusive ? 1 : 0)
        enterLeaf(cursor, other: other)
        return (false, leafFound.found && inclusive)
    }
    private func moveOne(_ cursor: UnionCursor<Key, Value>, other: UnionCursor<Key, Value>) -> Bool {
        if cursor.index + 1 < cursor.leaf.keys.count {
            cursor.index += 1
            return false
        }
        return moveTo(cursor, other: other, target: cursor.key, inclusive: false, startedEqual: true).out
    }
    func run(combine: (Key, Value?, Value?) throws -> Value?) throws {
        let a = UnionCursor(left)
        let b = UnionCursor(right)
        for (cursor, other) in [(a, b), (b, a)] {
            if overlaps(cursor.key, cursor.leaf.maxKey(), other.key, other.leaf.maxKey()) { cursor.disqualified = true }
            for depth in cursor.spine.indices {
                if overlaps(cursor.key, cursor.spine[depth].node.maxKey(), other.key, other.leaf.maxKey()) { cursor.spine[depth].disqualified = true }
            }
        }
        let maximum = left.compare(left.root.maxKey(), right.root.maxKey()) >= 0 ? left.root.maxKey() : right.root.maxKey()
        var leading = a
        var trailing = b
        var order = left.compare(leading.key, trailing.key)
        while true {
            if order == 0 {
                if let value = try combine(leading.key, a.leaf.value(at: a.index), b.leaf.value(at: b.index)) {
                    pendingKeys.append(leading.key)
                    pendingValues.append(value)
                }
                let outTrailing = moveOne(trailing, other: leading)
                let outLeading = moveOne(leading, other: trailing)
                if outTrailing || outLeading {
                    if !outTrailing || !outLeading {
                        if outTrailing { _ = moveTo(leading, other: trailing, target: maximum, inclusive: false, startedEqual: false) }
                        else { _ = moveTo(trailing, other: leading, target: maximum, inclusive: false, startedEqual: false) }
                    }
                    break
                }
                order = left.compare(leading.key, trailing.key)
            } else {
                if order < 0 { swap(&leading, &trailing) }
                let result = moveTo(trailing, other: leading, target: leading.key, inclusive: true, startedEqual: false)
                if result.out {
                    _ = moveTo(leading, other: trailing, target: maximum, inclusive: false, startedEqual: false)
                    break
                }
                order = result.equal ? 0 : -1
            }
        }
        flushPending()
        if tallestHeight < 0 && !heights.isEmpty { tallestIndex = 0 }
    }
}
