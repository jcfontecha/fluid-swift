/// @tylerbu/sorted-btree-es6/extended/decompose.js: buildFromDecomposition
/// and its two-sided frontier reconstruction helpers.
final class BTreeUnionReconstruction<Key, Value> {
    private enum Side { case left, right }
    private let decomposition: BTreeUnionDecomposition<Key, Value>
    private let template: BTree<Key, Value>
    private var spine: [BNode<Key, Value>] = []
    private var side = Side.right
    init(decomposition: BTreeUnionDecomposition<Key, Value>, template: BTree<Key, Value>) {
        self.decomposition = decomposition
        self.template = template
    }
    func build() -> BTree<Key, Value> {
        let pivot = decomposition.tallestIndex
        precondition(decomposition.nodes.indices.contains(pivot), "union decomposition requires a node")
        spine = [decomposition.nodes[pivot]]
        if pivot + 1 < decomposition.nodes.count {
            updateFrontier(from: 0)
            processSide(start: pivot + 1, end: decomposition.nodes.count, step: 1)
        }
        side = .left
        if pivot > 0 {
            updateFrontier(from: 0)
            processSide(start: pivot - 1, end: -1, step: -1)
        }
        let result = BTree<Key, Value>(maxNodeSize: template.maxNodeSize, context: template.context, compare: template.compare)
        result.root = spine[0]
        return result
    }
    private func inner(_ depth: Int) -> BNodeInternal<Key, Value> {
        guard let node = spine[depth] as? BNodeInternal<Key, Value> else { preconditionFailure("expected internal frontier node") }
        return node
    }
    private func sideIndex(_ node: BNodeInternal<Key, Value>) -> Int { side == .left ? 0 : node.children.count - 1 }
    private func insertionIndex(_ node: BNodeInternal<Key, Value>) -> Int { side == .left ? 0 : node.children.count }
    private func updateMax(_ node: BNodeInternal<Key, Value>, _ key: Key) {
        if side == .right { node.keys[node.keys.count - 1] = key }
    }
    private func insertNoCount(_ parent: BNodeInternal<Key, Value>, _ child: BNode<Key, Value>) {
        let index = insertionIndex(parent)
        parent.children.insert(child, at: index)
        parent.keys.insert(child.maxKey(), at: index)
    }
    private func splitSide(_ node: BNodeInternal<Key, Value>) -> BNodeInternal<Key, Value> {
        if side == .right {
            guard let split = node.splitOffRightSide() as? BNodeInternal<Key, Value> else { preconditionFailure("expected internal split") }
            return split
        }
        let half = node.children.count / 2
        let previousSize = node.cachedSize
        let split = BNodeInternal(children: Array(node.children[..<half]), keys: Array(node.keys[..<half]))
        node.children.removeSubrange(..<half)
        node.keys.removeSubrange(..<half)
        node.cachedSize = node.children.reduce(0) { $0 + $1.size }
        split.cachedSize = previousSize - node.cachedSize
        return split
    }
    private func processSide(start: Int, end: Int, step: Int) {
        var sharedDepth = 0
        var current = spine[0]
        while current.isShared != true && sharedDepth < spine.count - 1 {
            sharedDepth += 1
            let node = inner(sharedDepth - 1)
            current = node.children[sideIndex(node)]
        }
        var sizes = Array(repeating: 0, count: spine.count)
        var index = start
        while index != end {
            let height = spine.count - 1
            let subtree = decomposition.nodes[index]
            let subtreeHeight = decomposition.heights[index]
            let entries = subtreeHeight == -1
            precondition(subtreeHeight <= height)
            let insertionDepth = height - (subtreeHeight + 1)
            ensureUnshared(from: sharedDepth, through: insertionDepth)
            let insertionCount = entries ? subtree.keys.count : 1
            let insertionSize = entries ? subtree.keys.count : subtree.size
            let expansionDepth = max(0, cascadeEndDepth(from: insertionDepth, count: insertionCount))
            updateSizeAndMax(&sizes, sharedDepth: sharedDepth, through: expansionDepth)
            let newRoot: BNodeInternal<Key, Value>?
            var sizeChangeDepth: Int
            if entries {
                newRoot = insertEntries(at: insertionDepth, entries: subtree)
                sizeChangeDepth = insertionDepth - 1
            } else {
                newRoot = insertSubtree(at: insertionDepth, subtree: subtree).root
                sizeChangeDepth = insertionDepth
            }
            if let newRoot {
                spine[0] = newRoot
                sizes.append(0)
                sizeChangeDepth += 1
            }
            sharedDepth = sizeChangeDepth + 1
            // Leaf-only insertion has no cached ancestor size to update.
            if sizeChangeDepth >= 0 { sizes[sizeChangeDepth] += insertionSize }
            updateFrontier(from: expansionDepth)
            index += step
        }
        updateSizeAndMax(&sizes, sharedDepth: sharedDepth, through: 0)
    }
    private func ensureUnshared(from sharedDepth: Int, through depth: Int) {
        guard depth >= 0 else { return }
        if sharedDepth == 0 { spine[0] = spine[0].clone() }
        let start = max(sharedDepth, 1)
        if start <= depth {
            for current in start...depth {
                let parent = inner(current - 1)
                let index = sideIndex(parent)
                let clone = parent.children[index].clone()
                parent.children[index] = clone
                spine[current] = clone
            }
        }
    }
    private func cascadeEndDepth(from insertionDepth: Int, count: Int) -> Int {
        guard insertionDepth >= 0 else { return -1 }
        if spine[insertionDepth].keys.count + count <= template.maxNodeSize { return insertionDepth }
        if insertionDepth > 0 {
            for depth in stride(from: insertionDepth - 1, through: 0, by: -1) {
                if spine[depth].keys.count < template.maxNodeSize { return depth }
            }
        }
        return -1
    }
    private func updateSizeAndMax(_ sizes: inout [Int], sharedDepth: Int, through depth: Int) {
        let maximum = spine[sharedDepth].maxKey()
        guard sharedDepth - 1 >= depth else { return }
        for index in stride(from: sharedDepth - 1, through: depth, by: -1) {
            let amount = sizes[index]
            sizes[index] = 0
            if index > 0 { sizes[index - 1] += amount }
            let node = inner(index)
            node.cachedSize += amount
            updateMax(node, maximum)
        }
    }
    private func updateFrontier(from depth: Int) {
        var current = spine[depth]
        var index = depth
        while let node = current as? BNodeInternal<Key, Value> {
            current = node.children[sideIndex(node)]
            index += 1
            if index < spine.count { spine[index] = current } else { spine.append(current) }
        }
    }
    private func insertSubtree(at depth: Int, subtree: BNode<Key, Value>) -> (root: BNodeInternal<Key, Value>?, target: BNodeInternal<Key, Value>) {
        if depth < 0 {
            let root = BNodeInternal(children: [spine[0]])
            insertNoCount(root, subtree)
            return (root, root)
        }
        var target = inner(depth)
        var carry: BNodeInternal<Key, Value>?
        if target.keys.count == template.maxNodeSize {
            let split = splitSide(target)
            target = split
            carry = split
        }
        var ancestor = depth - 1
        while let carried = carry, ancestor >= 0 {
            let parent = inner(ancestor)
            updateMax(parent, parent.children[sideIndex(parent)].maxKey())
            if parent.keys.count < template.maxNodeSize {
                insertNoCount(parent, carried)
                carry = nil
            } else {
                let split = splitSide(parent)
                insertNoCount(split, carried)
                carry = split
            }
            ancestor -= 1
        }
        var root: BNodeInternal<Key, Value>?
        if let carry {
            let newRoot = BNodeInternal(children: [spine[0]])
            newRoot.cachedSize += carry.size
            insertNoCount(newRoot, carry)
            root = newRoot
        }
        insertNoCount(target, subtree)
        return (root, target)
    }
    private func insertEntries(at depth: Int, entries: BNode<Key, Value>) -> BNodeInternal<Key, Value>? {
        let leaf = spine[depth]
        leaf.reifyValues()
        entries.reifyValues()
        if leaf.keys.count + entries.keys.count <= template.maxNodeSize {
            if side == .right {
                leaf.keys.append(contentsOf: entries.keys)
                if let values = entries.values { leaf.values?.append(contentsOf: values) }
            } else {
                leaf.keys.insert(contentsOf: entries.keys, at: 0)
                if let values = entries.values { leaf.values?.insert(contentsOf: values, at: 0) }
            }
            return nil
        }
        let (root, parent) = insertSubtree(at: depth - 1, subtree: entries)
        let take = template.maxNodeSize / 2 - entries.keys.count
        if side == .right {
            let siblingIndex = parent.children.count - 2
            let sibling = parent.children[siblingIndex]
            sibling.reifyValues()
            let start = sibling.keys.count - take
            entries.keys.insert(contentsOf: sibling.keys[start...], at: 0)
            if let values = sibling.values { entries.values?.insert(contentsOf: values[start...], at: 0) }
            sibling.keys.removeSubrange(start...)
            sibling.values?.removeSubrange(start...)
            parent.keys[siblingIndex] = sibling.maxKey()
        } else {
            let sibling = parent.children[1]
            sibling.reifyValues()
            entries.keys.append(contentsOf: sibling.keys[..<take])
            if let values = sibling.values { entries.values?.append(contentsOf: values[..<take]) }
            sibling.keys.removeSubrange(..<take)
            sibling.values?.removeSubrange(..<take)
            parent.keys[0] = entries.maxKey()
        }
        return root
    }
}
