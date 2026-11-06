import FluidJS

func newFieldIdKeyBTree<Value>(context: BTreeStorageContext) -> BTree<FieldId, Value> {
    BTree(context: context, compare: { first, second in
        let revision = comparePartialRevisions(first.nodeId?.revision, second.nodeId?.revision)
        if revision != 0 { return revision }
        switch (first.nodeId?.localId, second.nodeId?.localId) {
        case (nil, .some): return -1
        case (.some, nil): return 1
        case (.some(let a), .some(let b)):
            if a != b { return a < b ? -1 : 1 }
        default: break
        }
        if first.field == second.field { return 0 }
        return first.field.utf16.lexicographicallyPrecedes(second.field.utf16) ? -1 : 1
    })
}

private final class RebaseFieldContext {
    let baseChange: FieldChange
    let newChange: FieldChange
    let rebasedChange: FieldChange
    let fieldId: FieldId
    var baseNodeIds: [ChangeAtomId] = []
    init(base: FieldChange, new: FieldChange, rebased: FieldChange, fieldId: FieldId) {
        baseChange = base
        newChange = new
        rebasedChange = rebased
        self.fieldId = fieldId
    }
}
private final class RebaseTable {
    let shared: CrossFieldTable<MoveEffect, FieldChange>
    let baseChange: ModularChangeset
    let newChange: ModularChangeset
    var contexts: [FieldChange: RebaseFieldContext] = [:]
    let baseToRebasedNodeId: ChangeAtomIdBTree<ChangeAtomId>
    var rebasedFields: Set<FieldChange> = []
    let rebasedNodeToParent: ChangeAtomIdBTree<FieldId>
    let rebasedCrossFieldKeys: CrossFieldKeyTable
    var nodeIdPairs: [(ChangeAtomId, ChangeAtomId, NodeAttachState?)] = []
    let affectedBaseFields: BTree<FieldId, Bool>
    var fieldsWithUnattachedChild = OrderedMap<FieldChange, Bool>()
    init(change: ModularChangeset, base: ModularChangeset, context: BTreeStorageContext) {
        shared = CrossFieldTable(context: context)
        newChange = change
        baseChange = base
        baseToRebasedNodeId = newChangeAtomIdBTree(context: context)
        rebasedNodeToParent = change.nodeToParent.clone()
        rebasedCrossFieldKeys = change.crossFieldKeys.clone()
        affectedBaseFields = newFieldIdKeyBTree(context: context)
    }
}

/// feature-libraries/modular-schema/modularChangeFamily.ts: RebaseManager.
private final class RebaseManager: CrossFieldManagerI<MoveEffect, FieldChange> {
    private let rebaseTable: RebaseTable
    private let fieldId: FieldId
    init(table: RebaseTable, field: FieldChange, fieldId: FieldId, allowInvalidation: Bool = true) {
        rebaseTable = table
        self.fieldId = fieldId
        super.init(table: table.shared, field: field, allowInvalidation: allowInvalidation, onMoveIn: { _ in }, moveKey: { _, _, _, _ in })
    }
    override func set(_ target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int, value: MoveEffect, invalidateDependents: Bool) throws {
        if invalidateDependents && allowInvalidation {
            let key = CrossFieldKey(target: target, revision: revision, localId: id)
            guard try getFieldsForCrossFieldKey(rebaseTable.newChange, key: key, count: count).isEmpty else { throw JSONDecodingError("0x9c6: modifying new cross-field key unsupported") }
            let fields = try getFieldsForCrossFieldKey(rebaseTable.baseChange, key: key, count: count)
            guard !fields.isEmpty else { throw JSONDecodingError("0x9c7: cross-field key not registered") }
            for field in fields { rebaseTable.affectedBaseFields.set(field, true) }
        }
        try super.set(target, revision: revision, id: id, count: count, value: value, invalidateDependents: invalidateDependents)
    }
    override func onMoveIn(_ id: ChangeAtomId) { rebaseTable.rebasedNodeToParent.set(id, fieldId) }
    override func moveKey(_ target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int) {
        rebaseTable.rebasedCrossFieldKeys.set(CrossFieldKey(target: target, revision: revision, localId: id), count: count, value: fieldId)
    }
}

extension ModularChangeFamily {
    /// modularChangeFamily.ts: rebase, including affected fields and amendment.
    public func rebase(_ tagged: TaggedChange<ModularChangeset>, over taggedBase: TaggedChange<ModularChangeset>, metadata: RevisionMetadataSource, ignoreNoChangeViolation: Bool = false) throws -> ModularChangeset {
        let change = tagged.change
        let base = try effectiveModularChange(taggedBase.change)
        let table = RebaseTable(change: change, base: base, context: context)
        let nodes = change.nodeChanges.clone()
        var fields = try rebaseFieldMap(change.fieldChanges, over: base.fieldChanges, parent: nil, table: table, metadata: metadata)
        var pairIndex = 0
        while pairIndex < table.nodeIdPairs.count {
            let (newId, baseId, _) = table.nodeIdPairs[pairIndex]
            let node = try rebaseNodeChange(newId, baseId: baseId, table: table, metadata: metadata)
            nodes.set(try normalizeNodeId(newId, aliases: change.nodeAliases), node)
            pairIndex += 1
        }
        // BTree iteration sees fields added by earlier cross-field callbacks.
        var affected = table.affectedBaseFields.entries.first
        while let (id, _) = affected {
            let baseNode = try id.nodeId.map { try normalizeNodeId($0, aliases: base.nodeAliases) }
            let baseField = try fieldChangeFromId(base, id: FieldId(nodeId: baseNode, field: id.field))
            if table.contexts[baseField] == nil {
                let empty = FieldChange(fieldKind: baseField.fieldKind, change: emptyFieldChange(baseField.fieldKind, context: context))
                let nodeId = baseNode.map { table.baseToRebasedNodeId.get($0) ?? $0 }
                let fieldId = FieldId(nodeId: nodeId, field: id.field)
                let payload = try empty.change.rebased(over: baseField.change, metadata: metadata, manager: RebaseManager(table: table, field: baseField, fieldId: fieldId)) { child, _, _ in
                    guard child == nil else { throw JSONDecodingError("0x9c3: unexpected new child") }
                    return nil
                }
                let rebased = FieldChange(fieldKind: baseField.fieldKind, change: payload)
                table.contexts[baseField] = RebaseFieldContext(base: baseField, new: empty, rebased: rebased, fieldId: fieldId)
                table.rebasedFields.insert(rebased)
                try attachRebasedField(rebased, id: fieldId, fields: &fields, nodes: nodes, table: table, metadata: metadata)
            }
            affected = table.affectedBaseFields.getPairOrNextHigher(id, inclusive: false)
        }
        for field in table.fieldsWithUnattachedChild.keys {
            table.shared.removeInvalidated(field)
            try rebaseInvalidatedField(field, table: table, metadata: metadata, allowInvalidation: true)
        }
        for field in table.shared.takeInvalidatedFields() {
            try rebaseInvalidatedField(field, table: table, metadata: metadata, allowInvalidation: false)
        }
        var result = change
        result.fieldChanges = fields
        result.nodeChanges = nodes
        result.nodeToParent = table.rebasedNodeToParent
        result.crossFieldKeys = table.rebasedCrossFieldKeys
        result.maxId = max(change.maxId ?? -1, base.maxId ?? -1)
        var violations = change.constraintViolationCount ?? 0
        if let constraint = change.noChangeConstraint, !constraint.violated && !ignoreNoChangeViolation {
            result.noChangeConstraint = NoChangeConstraint(violated: true)
            violations += 1
        }
        try updateConstraintsForFields(fields, parentState: .attached, change: result, violations: &violations)
        result.constraintViolationCount = violations
        return try pruneModularChangeset(normalizedModularChangeset(result))
    }
    private func rebaseFieldMap(_ fields: FieldChangeMap, over base: FieldChangeMap, parent: ChangeAtomId?, table: RebaseTable, metadata: RevisionMetadataSource) throws -> FieldChangeMap {
        var result = FieldChangeMap()
        for (key, field) in fields.entries {
            let id = FieldId(nodeId: parent, field: key)
            guard let baseField = base[key] else {
                result[key] = field
                continue
            }
            let (kind, new, old) = try normalizeFieldChanges(field, baseField)
            let payload = try new.rebased(over: old, metadata: metadata, manager: RebaseManager(table: table, field: baseField, fieldId: id)) { child, baseChild, state in
                if let child, let baseChild { table.nodeIdPairs.append((child, baseChild, state)) }
                return child
            }
            let rebased = FieldChange(fieldKind: kind, change: payload)
            result[key] = rebased
            table.contexts[baseField] = RebaseFieldContext(base: baseField, new: field, rebased: rebased, fieldId: id)
            table.rebasedFields.insert(rebased)
        }
        return result
    }
    private func rebaseNodeChange(_ newId: ChangeAtomId, baseId: ChangeAtomId, table: RebaseTable, metadata: RevisionMetadataSource) throws -> NodeChangeset {
        let new = try nodeChangeFromId(table.newChange, id: newId)
        let base = try nodeChangeFromId(table.baseChange, id: baseId)
        var fields = new.fieldChanges
        if let newFields = fields, let baseFields = base.fieldChanges {
            fields = try rebaseFieldMap(newFields, over: baseFields, parent: newId, table: table, metadata: metadata)
        }
        let result = NodeChangeset(fieldChanges: fields?.isEmpty == false ? fields : nil, nodeExistsConstraint: new.nodeExistsConstraint, nodeExistsConstraintOnRevert: new.nodeExistsConstraintOnRevert)
        table.baseToRebasedNodeId.set(try normalizeNodeId(baseId, aliases: table.baseChange.nodeAliases), newId)
        return result
    }
    private func rebaseInvalidatedField(_ field: FieldChange, table: RebaseTable, metadata: RevisionMetadataSource, allowInvalidation: Bool) throws {
        guard let fieldContext = table.contexts[field] else { throw JSONDecodingError("0x852: missing rebase context") }
        let (_, new, base) = try normalizeFieldChanges(fieldContext.newChange, fieldContext.baseChange)
        fieldContext.rebasedChange.change = try new.rebased(over: base, metadata: metadata, manager: RebaseManager(table: table, field: field, fieldId: fieldContext.fieldId, allowInvalidation: allowInvalidation)) { child, baseChild, _ in
            if let child { return child }
            if let baseChild {
                let normalized = try normalizeNodeId(baseChild, aliases: table.baseChange.nodeAliases)
                if fieldContext.baseNodeIds.contains(normalized) { return normalized }
            }
            return nil
        }
    }
    private func attachRebasedField(_ field: FieldChange, id: FieldId, fields: inout FieldChangeMap, nodes: ChangeAtomIdBTree<NodeChangeset>, table: RebaseTable, metadata: RevisionMetadataSource) throws {
        guard let nodeId = id.nodeId else {
            fields[id.field] = field
            return
        }
        if let node = nodes.get(nodeId) {
            if node.fieldChanges == nil { node.fieldChanges = FieldChangeMap() }
            guard node.fieldChanges?[id.field] == nil else { throw JSONDecodingError("0x9c4: expected empty field") }
            node.fieldChanges?[id.field] = field
            return
        }
        var newFields = FieldChangeMap()
        newFields[id.field] = field
        nodes.set(nodeId, NodeChangeset(fieldChanges: newFields))
        table.baseToRebasedNodeId.set(nodeId, nodeId)
        let parentId = try getParentFieldId(table.baseChange, nodeId: nodeId)
        try attachRebasedNode(nodeId, parent: parentId, fields: &fields, nodes: nodes, table: table, metadata: metadata)
    }
    private func attachRebasedNode(_ nodeId: ChangeAtomId, parent: FieldId, fields: inout FieldChangeMap, nodes: ChangeAtomIdBTree<NodeChangeset>, table: RebaseTable, metadata: RevisionMetadataSource) throws {
        let baseField = try fieldChangeFromId(table.baseChange, id: parent)
        let rebasedId = FieldId(nodeId: parent.nodeId.map { table.baseToRebasedNodeId.get($0) ?? $0 }, field: parent.field)
        table.rebasedNodeToParent.set(nodeId, rebasedId)
        if let fieldContext = table.contexts[baseField] {
            fieldContext.baseNodeIds.append(nodeId)
            table.fieldsWithUnattachedChild[baseField] = true
            return
        }
        let empty = FieldChange(fieldKind: baseField.fieldKind, change: emptyFieldChange(baseField.fieldKind, context: context))
        let payload = try empty.change.rebased(over: baseField.change, metadata: metadata, manager: RebaseManager(table: table, field: baseField, fieldId: rebasedId)) { _, baseChild, _ in
            guard let baseChild else { return nil }
            let normalized = try normalizeNodeId(baseChild, aliases: table.baseChange.nodeAliases)
            return normalized == nodeId ? nodeId : nil
        }
        let rebased = FieldChange(fieldKind: baseField.fieldKind, change: payload)
        table.rebasedFields.insert(rebased)
        table.contexts[baseField] = RebaseFieldContext(base: baseField, new: empty, rebased: rebased, fieldId: rebasedId)
        try attachRebasedField(rebased, id: rebasedId, fields: &fields, nodes: nodes, table: table, metadata: metadata)
    }
}
