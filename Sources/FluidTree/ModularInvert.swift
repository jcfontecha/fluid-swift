import FluidJS

private final class InvertTable {
    let shared: CrossFieldTable<ChangeAtomId, FieldChange>
    var contexts: [FieldChange: (fieldId: FieldId, inverted: FieldChange)] = [:]
    init(context: BTreeStorageContext) { shared = CrossFieldTable(context: context) }
}

/// feature-libraries/modular-schema/invert.ts: InvertManager.
private final class InvertManager: CrossFieldManagerI<ChangeAtomId, FieldChange> {
    init(table: InvertTable, field: FieldChange) {
        super.init(table: table.shared, field: field, onMoveIn: { _ in }, moveKey: { _, _, _, _ in
            throw JSONDecodingError("0x9c5: keys should not be moved during invert")
        })
    }
}

/// feature-libraries/modular-schema/invert.ts.
func invertModularChange(_ tagged: TaggedChange<ModularChangeset>, isRollback: Bool, revision: RevisionTag, context: BTreeStorageContext) throws -> ModularChangeset {
    let change = tagged.change
    guard change.destroys == nil else { throw JSONDecodingError("0x89a: cannot invert destroys") }
    var result = ModularChangeset(context: context)
    result.revisions = [RevisionInfo(revision: revision, rollbackOf: isRollback ? tagged.revision : nil, includesRollbackOf: isRollback)]
    if isRollback, let builds = change.builds {
        result.destroys = try builds.mapValuesAs { chunk, _ in
            guard let chunk else { throw JSONDecodingError("missing chunk") }
            return chunk.topLevelLength
        }
    }
    if (change.constraintViolationCount ?? 0) > 0 {
        result.maxId = change.maxId
        return normalizedModularChangeset(result)
    }
    let allocator = DefaultAtomIdAliasAllocator()
    let infos = getRevInfoFromTaggedChanges([tagged]).infos
    if let maximum = change.maxId {
        for info in infos { try allocator.reserve(info.revision, maxLocalId: maximum) }
    }
    let table = InvertTable(context: context)
    func invertFields(_ fields: FieldChangeMap, parent: ChangeAtomId?) throws -> FieldChangeMap {
        var inverted = FieldChangeMap()
        for (key, field) in fields.entries {
            let fieldId = FieldId(nodeId: parent, field: key)
            let payload = try field.change.inverted(isRollback: isRollback, allocator: allocator, revision: revision, manager: InvertManager(table: table, field: field))
            let value = FieldChange(fieldKind: field.fieldKind, change: payload)
            inverted[key] = value
            table.contexts[field] = (fieldId, value)
        }
        return inverted
    }
    result.fieldChanges = try invertFields(change.fieldChanges, parent: nil)
    for (id, node) in change.nodeChanges.entries {
        guard let node else { throw JSONDecodingError("missing node") }
        let inverse = NodeChangeset()
        if !isRollback {
            inverse.nodeExistsConstraintOnRevert = node.nodeExistsConstraint
            inverse.nodeExistsConstraint = node.nodeExistsConstraintOnRevert
        }
        if let fields = node.fieldChanges { inverse.fieldChanges = try invertFields(fields, parent: id) }
        result.nodeChanges.set(id, inverse)
    }
    for field in table.shared.takeInvalidatedFields() {
        guard let fieldContext = table.contexts[field] else { throw JSONDecodingError("0x851: missing inverted field context") }
        fieldContext.inverted.change = try field.change.inverted(isRollback: isRollback, allocator: allocator, revision: revision, manager: InvertManager(table: table, field: field))
    }
    result.nodeAliases = change.nodeAliases
    try makeChangesetInversions(&result)
    var violations = 0
    if !isRollback { try updateConstraintsForFields(result.fieldChanges, parentState: .attached, change: result, violations: &violations) }
    result.constraintViolationCount = violations
    result.maxId = allocator.getMaxId()
    if !isRollback {
        result.noChangeConstraint = change.noChangeConstraintOnRevert
        result.noChangeConstraintOnRevert = change.noChangeConstraint
    }
    return normalizedModularChangeset(result)
}
