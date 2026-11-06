import FluidJS

/// feature-libraries/modular-schema/modularChangeUtils.ts: isChangesetValid.
/// This is an explicit validation operation, not extra work in production algebra.
public func validateModularChangeset(_ change: ModularChangeset, ignoreCrossFieldTable: Bool = false) throws {
    for (id, _) in change.nodeChanges.entries where change.nodeAliases.has(id) {
        throw JSONDecodingError("node change table contains a non-canonical ID")
    }
    for (id, _) in change.nodeToParent.entries where change.nodeAliases.has(id) {
        throw JSONDecodingError("node parentage table contains a non-canonical ID")
    }
    let unreachable = change.nodeToParent.clone()
    func validateFields(_ fields: FieldChangeMap, parent: ChangeAtomId?) throws {
        for (key, field) in fields.entries {
            let fieldId = try normalizeFieldId(FieldId(nodeId: parent, field: key), aliases: change.nodeAliases)
            for child in try field.change.nestedChanges() {
                let node = try normalizeNodeId(child.nodeId, aliases: change.nodeAliases)
                guard let actualParent = change.nodeToParent.get(node) else { throw JSONDecodingError("node is missing from parent table") }
                guard try normalizeFieldId(actualParent, aliases: change.nodeAliases) == fieldId else { throw JSONDecodingError("inconsistent node location") }
                guard unreachable.has(node) else { throw JSONDecodingError("node is reachable in multiple locations") }
                unreachable.delete(node)
            }
            if !ignoreCrossFieldTable {
                for range in field.change.crossFieldKeys {
                    let fields = try getFieldsForCrossFieldKey(change, key: range.key, count: range.count)
                    guard !fields.isEmpty else { throw JSONDecodingError("cross-field key is missing from table") }
                    guard fields.allSatisfy({ $0 == fieldId }) else { throw JSONDecodingError("cross-field key points to wrong field") }
                }
            }
        }
    }
    try validateFields(change.fieldChanges, parent: nil)
    for (id, node) in change.nodeChanges.entries {
        guard let node else { throw JSONDecodingError("missing node change") }
        if let fields = node.fieldChanges { try validateFields(fields, parent: id.fromTuple()) }
    }
    guard unreachable.isEmpty else { throw JSONDecodingError("unreachable nodes found") }
    for (id, _) in change.nodeChanges.entries where !change.nodeToParent.has(id) { throw JSONDecodingError("unparented node change") }
    for (id, _) in change.nodeToParent.entries where !change.nodeChanges.has(id) { throw JSONDecodingError("parented node has no change entry") }
}

extension ModularChangeFamily {
    public func validator(_ change: ModularChangeset) throws { try validateModularChangeset(change) }
    public func hasSchemaChange(_ change: ModularChangeset) -> Bool { false }
    public func buildProcessor(_ process: @escaping (ModularChangeset, ModularChangeFamily) throws -> ModularChangeset) -> (ModularChangeset) throws -> ModularChangeset {
        { change in try process(change, self) }
    }
}

/// feature-libraries/modular-schema/modularChangeFamily.ts: updateRefreshers.
public func updateRefreshers(_ change: ModularChangeset, getDetachedNode: (DeltaDetachedNodeId) throws -> (any TreeChunk)?, removedRoots: [DeltaDetachedNodeId], requireRefreshers: Bool = true) throws -> ModularChangeset {
    let refreshers: ChangeAtomIdBTree<any TreeChunk> = newChangeAtomIdBTree(context: change.context)
    var lengths: [RevisionTag?: BTree<Double, Int>] = [:]
    if let builds = change.builds {
        for (id, chunk) in builds.entries {
            guard let chunk else { throw JSONDecodingError("missing build chunk") }
            let tree = lengths[id.revision] ?? BTree<Double, Int>(context: change.context, compare: { $0 < $1 ? -1 : $0 > $1 ? 1 : 0 })
            tree.set(id.localId, chunk.topLevelLength)
            lengths[id.revision] = tree
        }
    }
    for root in removedRoots {
        if let (start, count) = lengths[root.major]?.getPairOrNextLower(root.minor), let count, root.minor < start + Double(count) { continue }
        if let chunk = try getDetachedNode(root) { refreshers.set(ChangeAtomId(localId: root.minor, revision: root.major), chunk) }
        else if requireRefreshers { throw JSONDecodingError("0x8cd: detached node should exist") }
    }
    var result = change
    result.refreshers = refreshers
    return normalizedModularChangeset(result)
}
