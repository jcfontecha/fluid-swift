import FluidJS

private struct ComposeFieldContext {
    let fieldId: FieldId
    let first: FieldChangeset
    let second: FieldChangeset
    let composed: FieldChange
}
private final class ComposeTable {
    let shared: CrossFieldTable<MoveEffect, FieldChange>
    let baseChange: ModularChangeset
    let newChange: ModularChangeset
    var contexts: [FieldChange: ComposeFieldContext] = [:]
    var newFieldToBaseField: [FieldChange: FieldChange] = [:]
    let newToBaseNodeId: ChangeAtomIdBTree<ChangeAtomId>
    var composedNodes: Set<NodeChangeset> = []
    let composedNodeToParent: ChangeAtomIdBTree<FieldId>
    var nodeIdsToCompose: [(ChangeAtomId, ChangeAtomId)] = []
    let affectedBaseFields: BTree<FieldId, Bool>
    let affectedNewFields: BTree<FieldId, Bool>
    init(first: ModularChangeset, second: ModularChangeset, parents: ChangeAtomIdBTree<FieldId>, context: BTreeStorageContext) {
        shared = CrossFieldTable(context: context)
        baseChange = first
        newChange = second
        composedNodeToParent = parents
        newToBaseNodeId = newChangeAtomIdBTree(context: context)
        affectedBaseFields = newFieldIdKeyBTree(context: context)
        affectedNewFields = newFieldIdKeyBTree(context: context)
    }
}

/// feature-libraries/modular-schema/modularChangeFamily.ts: ComposeManager.
private final class ComposeManager: CrossFieldManagerI<MoveEffect, FieldChange> {
    private let composition: ComposeTable
    private let fieldId: FieldId
    init(table: ComposeTable, field: FieldChange, fieldId: FieldId, allowInvalidation: Bool = true) {
        composition = table
        self.fieldId = fieldId
        super.init(table: table.shared, field: field, allowInvalidation: allowInvalidation, onMoveIn: { _ in }, moveKey: { _, _, _, _ in })
    }
    override func set(_ target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int, value: MoveEffect, invalidateDependents: Bool) throws {
        if invalidateDependents && allowInvalidation {
            let key = CrossFieldKey(target: target, revision: revision, localId: id)
            let newFields = try getFieldsForCrossFieldKey(composition.newChange, key: key, count: count)
            if !newFields.isEmpty {
                for field in newFields { composition.affectedNewFields.set(field, true) }
            } else {
                let baseFields = try getFieldsForCrossFieldKey(composition.baseChange, key: key, count: count)
                guard !baseFields.isEmpty else { throw JSONDecodingError("0x9c8: cross-field key not registered") }
                for field in baseFields { composition.affectedBaseFields.set(field, true) }
            }
        }
        try super.set(target, revision: revision, id: id, count: count, value: value, invalidateDependents: invalidateDependents)
    }
    override func onMoveIn(_ id: ChangeAtomId) {
        if composition.newToBaseNodeId.get(id) == nil { composition.composedNodeToParent.set(id, fieldId) }
    }
    override func moveKey(_ target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int) throws {
        throw JSONDecodingError("moving cross-field keys during compose is unsupported")
    }
}

extension FieldChangeset {
    func composed<M: CrossFieldManager>(with next: FieldChangeset, metadata: RevisionMetadataSource, manager: M, composeChild: NodeChangeComposer) throws -> FieldChangeset where M.Value == MoveEffect {
        switch (self, next) {
        case (.sequence(let first), .sequence(let second)): return .sequence(try composeSequence(first, second, metadata: metadata, manager: manager, composeChild: composeChild))
        case (.optional(let first), .optional(let second)): return .optional(try composeOptional(first, second, composeChild: composeChild))
        case (.generic(let first), .generic(let second)): return .generic(try composeGenericChange(first, second, composeChild: composeChild))
        case (.noChange, .noChange): return .noChange
        default: throw JSONDecodingError("incompatible field changes")
        }
    }
}
func mergeAtomTrees<Value>(_ first: ChangeAtomIdBTree<Value>, _ second: ChangeAtomIdBTree<Value>) throws -> ChangeAtomIdBTree<Value> {
    try BTree.union(first, second) { _, first, _ in first }
}

extension ModularChangeFamily {
    /// modularChangeFamily.ts: balanced composition preserves source evaluation order.
    public func compose(_ changes: [TaggedChange<ModularChangeset>]) throws -> ModularChangeset {
        let (infos, maxId) = getRevInfoFromTaggedChanges(changes)
        func reduce(_ start: Int, _ end: Int) throws -> ModularChangeset {
            if start == end { return ModularChangeset(context: context) }
            if end - start == 1 { return changes[start].change }
            let middle = start + (end - start) / 2
            let left = try reduce(start, middle)
            let right = try reduce(middle, end)
            return try composePair(left, right, infos: infos, maxId: maxId)
        }
        return try reduce(0, changes.count)
    }
    private func composePair(_ input1: ModularChangeset, _ input2: ModularChangeset, infos: [RevisionInfo], maxId: Double) throws -> ModularChangeset {
        let first = try effectiveModularChange(input1)
        let second = try effectiveModularChange(input2)
        let metadata = RevisionMetadataSource(infos)
        let nodes = try mergeAtomTrees(first.nodeChanges, second.nodeChanges)
        let parents = try mergeAtomTrees(first.nodeToParent, second.nodeToParent)
        let table = ComposeTable(first: first, second: second, parents: parents, context: context)
        let fields = try composeFieldMaps(first.fieldChanges, second.fieldChanges, parent: nil, table: table, metadata: metadata)
        while !table.shared.invalidatedFields.isEmpty || !table.nodeIdsToCompose.isEmpty || !table.affectedBaseFields.isEmpty || !table.affectedNewFields.isEmpty {
            var pairIndex = 0
            while pairIndex < table.nodeIdsToCompose.count {
                let (a, b) = table.nodeIdsToCompose[pairIndex]
                try composeNodesById(a, b, nodes: nodes, table: table, metadata: metadata)
                pairIndex += 1
            }
            table.nodeIdsToCompose.removeAll(keepingCapacity: true)
            try composeAffectedFields(table.affectedBaseFields, source: first, areBase: true, fields: fields, nodes: nodes, table: table, metadata: metadata)
            try composeAffectedFields(table.affectedNewFields, source: second, areBase: false, fields: fields, nodes: nodes, table: table, metadata: metadata)
            for field in table.shared.takeInvalidatedFields() {
                guard let fieldContext = table.contexts[field] else { throw JSONDecodingError("0x8cc: missing compose context") }
                fieldContext.composed.change = try fieldContext.first.composed(with: fieldContext.second, metadata: metadata, manager: ComposeManager(table: table, field: field, fieldId: fieldContext.fieldId, allowInvalidation: false)) { first, second in
                    if let first, let second, table.newToBaseNodeId.get(second) == nil {
                        table.newToBaseNodeId.set(second, first)
                        table.nodeIdsToCompose.append((first, second))
                    }
                    guard let id = first ?? second else { throw JSONDecodingError("0xb22: cannot compose absent nodes") }
                    return id
                }
            }
        }
        let keys = try RangeMap.union(first.crossFieldKeys, second.crossFieldKeys)
        let aliases = try mergeAtomTrees(first.nodeAliases, second.nodeAliases)
        for (new, old) in table.newToBaseNodeId.entries {
            guard let old else { throw JSONDecodingError("missing node alias") }
            if new != old {
                aliases.set(new, old)
                aliases.delete(old)
            }
        }
        var result = ModularChangeset(context: context)
        result.fieldChanges = fields
        result.nodeChanges = nodes
        result.nodeToParent = parents
        result.nodeAliases = aliases
        result.crossFieldKeys = keys
        result.maxId = maxId
        result.revisions = infos
        result.noChangeConstraint = input1.noChangeConstraint ?? input2.noChangeConstraint
        result.noChangeConstraintOnRevert = input1.noChangeConstraintOnRevert ?? input2.noChangeConstraintOnRevert
        try composeDetachedNodes(input1, input2, result: &result)
        return normalizedModularChangeset(result)
    }
    private func composeFieldMaps(_ first: FieldChangeMap?, _ second: FieldChangeMap?, parent: ChangeAtomId?, table: ComposeTable, metadata: RevisionMetadataSource) throws -> FieldChangeMap {
        guard let first, let second else { return first ?? second ?? FieldChangeMap() }
        let fields = FieldChangeMap()
        for (key, field) in first.entries {
            if let next = second[key] { fields[key] = try composeFieldChanges(field, next, id: FieldId(nodeId: parent, field: key), table: table, metadata: metadata) }
            else { fields[key] = field }
        }
        for (key, field) in second.entries where first[key] == nil { fields[key] = field }
        return fields
    }
    private func composeFieldChanges(_ first: FieldChange, _ second: FieldChange, id: FieldId, table: ComposeTable, metadata: RevisionMetadataSource) throws -> FieldChange {
        let (kind, a, b) = try normalizeFieldChanges(first, second)
        let payload = try a.composed(with: b, metadata: metadata, manager: ComposeManager(table: table, field: first, fieldId: id)) { first, second in
            if let first, let second {
                table.newToBaseNodeId.set(second, first)
                table.nodeIdsToCompose.append((first, second))
            }
            guard let id = first ?? second else { throw JSONDecodingError("0xb23: cannot compose absent nodes") }
            return id
        }
        let field = FieldChange(fieldKind: kind, change: payload)
        table.contexts[first] = ComposeFieldContext(fieldId: id, first: a, second: b, composed: field)
        table.newFieldToBaseField[second] = first
        return field
    }
    private func composeNodesById(_ first: ChangeAtomId, _ second: ChangeAtomId, nodes: ChangeAtomIdBTree<NodeChangeset>, table: ComposeTable, metadata: RevisionMetadataSource) throws {
        let a = try normalizeNodeId(first, aliases: table.baseChange.nodeAliases)
        let b = try normalizeNodeId(second, aliases: table.newChange.nodeAliases)
        let nodeA = try nodeChangeFromId(table.baseChange, id: a)
        let nodeB = try nodeChangeFromId(table.newChange, id: b)
        let fields = try composeFieldMaps(nodeA.fieldChanges, nodeB.fieldChanges, parent: a, table: table, metadata: metadata)
        let node = NodeChangeset(fieldChanges: fields.isEmpty ? nil : fields, nodeExistsConstraint: nodeA.nodeExistsConstraint ?? nodeB.nodeExistsConstraint, nodeExistsConstraintOnRevert: nodeA.nodeExistsConstraintOnRevert ?? nodeB.nodeExistsConstraintOnRevert)
        let parent = try getParentFieldId(table.baseChange, nodeId: a)
        nodes.delete(a)
        nodes.delete(b)
        table.composedNodeToParent.delete(a)
        table.composedNodeToParent.delete(b)
        nodes.set(first, node)
        table.composedNodeToParent.set(first, parent)
        table.composedNodes.insert(node)
    }
    private func composeAffectedFields(_ affected: BTree<FieldId, Bool>, source: ModularChangeset, areBase: Bool, fields: FieldChangeMap, nodes: ChangeAtomIdBTree<NodeChangeset>, table: ComposeTable, metadata: RevisionMetadataSource) throws {
        var next = affected.entries.first
        while let (key, _) = next {
            let id = try normalizeFieldId(key, aliases: source.nodeAliases)
            let field = try fieldChangeFromId(source, id: id)
            if table.contexts[field] == nil && table.newFieldToBaseField[field] == nil {
                let empty = FieldChange(fieldKind: field.fieldKind, change: emptyFieldChange(field.fieldKind, context: context))
                let composed = try composeFieldChanges(areBase ? field : empty, areBase ? empty : field, id: id, table: table, metadata: metadata)
                if let nodeId = id.nodeId {
                    let composedId = table.newToBaseNodeId.get(nodeId) ?? nodeId
                    let canonical = try normalizeNodeId(composedId, aliases: table.baseChange.nodeAliases)
                    guard var node = nodes.get(canonical) else { throw JSONDecodingError("0x9ca: unknown affected node") }
                    if !table.composedNodes.contains(node) {
                        node = node.copy()
                        node.fieldChanges = node.fieldChanges?.copy()
                        nodes.set(composedId, node)
                    }
                    if node.fieldChanges == nil { node.fieldChanges = FieldChangeMap() }
                    node.fieldChanges?[id.field] = composed
                } else { fields[id.field] = composed }
            }
            next = affected.getPairOrNextHigher(key, inclusive: false)
        }
        affected.clear()
    }
    private func composeDetachedNodes(_ first: ModularChangeset, _ second: ModularChangeset, result: inout ModularChangeset) throws {
        let builds: ChangeAtomIdBTree<any TreeChunk> = try mergeAtomTrees(first.builds ?? newChangeAtomIdBTree(context: context), second.builds ?? newChangeAtomIdBTree(context: context))
        let destroys: ChangeAtomIdBTree<Int> = try mergeAtomTrees(first.destroys ?? newChangeAtomIdBTree(context: context), second.destroys ?? newChangeAtomIdBTree(context: context))
        let refreshers: ChangeAtomIdBTree<any TreeChunk> = try mergeAtomTrees(first.refreshers ?? newChangeAtomIdBTree(context: context), second.refreshers ?? newChangeAtomIdBTree(context: context))
        for (created, removed, code) in [(second.builds, first.destroys, "0x89b"), (first.builds, second.destroys, "0x9f0")] {
            if let created, let removed {
                for (id, chunk) in created.entries {
                    if let count = removed.get(id) {
                        guard let chunk, count == chunk.topLevelLength else { throw JSONDecodingError("\(code): build/destroy lengths differ") }
                        builds.delete(id)
                        destroys.delete(id)
                    }
                }
            }
        }
        result.builds = builds
        result.destroys = destroys
        result.refreshers = refreshers
    }
}
