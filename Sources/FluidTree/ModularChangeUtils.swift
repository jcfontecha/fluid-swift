import FluidJS

/// core/rebase/types.ts.
public struct TaggedChange<Change> {
    public var change: Change
    public var revision: RevisionTag?
    public var rollbackOf: RevisionTag?
    public init(change: Change, revision: RevisionTag? = nil, rollbackOf: RevisionTag? = nil) {
        self.change = change
        self.revision = revision
        self.rollbackOf = rollbackOf
    }
}

func revisionInfoFromTaggedChange(_ change: TaggedChange<ModularChangeset>) -> [RevisionInfo] {
    if let revisions = change.change.revisions { return revisions }
    return change.revision.map { [RevisionInfo(revision: $0, rollbackOf: change.rollbackOf)] } ?? []
}
func getRevInfoFromTaggedChanges(_ changes: [TaggedChange<ModularChangeset>]) -> (infos: [RevisionInfo], maxId: Double) {
    var seen: Set<RevisionTag> = []
    var infos: [RevisionInfo] = []
    var maxId: Double = -1
    for change in changes {
        maxId = max(maxId, change.change.maxId ?? -1)
        for info in revisionInfoFromTaggedChange(change) where seen.insert(info.revision).inserted { infos.append(info) }
    }
    for revision in infos.compactMap(\.rollbackOf).reversed() where !seen.contains(revision) { infos.append(RevisionInfo(revision: revision)) }
    return (infos, maxId)
}

/// modularChangeUtils.ts: makeModularChangeset drops empty optional metadata.
func normalizedModularChangeset(_ input: ModularChangeset) -> ModularChangeset {
    var change = input
    if change.maxId.map({ $0 < 0 }) == true { change.maxId = nil }
    if change.revisions?.isEmpty == true { change.revisions = nil }
    if change.constraintViolationCount.map({ $0 <= 0 }) == true { change.constraintViolationCount = nil }
    if change.builds?.isEmpty == true { change.builds = nil }
    if change.destroys?.isEmpty == true { change.destroys = nil }
    if change.refreshers?.isEmpty == true { change.refreshers = nil }
    return change
}

func makeChangesetInversions(_ change: inout ModularChangeset) throws {
    let parents: ChangeAtomIdBTree<FieldId> = newChangeAtomIdBTree(context: change.context)
    let keys = newCrossFieldKeyTable(context: change.context)
    func populate(_ fields: FieldChangeMap, parent: ChangeAtomId?) throws {
        for (key, field) in fields.entries {
            let fieldId = FieldId(nodeId: parent, field: key)
            for range in field.change.crossFieldKeys { keys.set(range.key, count: range.count, value: fieldId) }
            for child in try field.change.nestedChanges() {
                parents.set(try normalizeNodeId(child.nodeId, aliases: change.nodeAliases), fieldId)
            }
        }
    }
    try populate(change.fieldChanges, parent: nil)
    for (id, node) in change.nodeChanges.entries {
        guard let node else { throw JSONDecodingError("missing node") }
        if let fields = node.fieldChanges { try populate(fields, parent: id.fromTuple()) }
    }
    change.nodeToParent = parents
    change.crossFieldKeys = keys
}

func updateConstraintsForFields(_ fields: FieldChangeMap, parentState: NodeAttachState, change: ModularChangeset, violations: inout Int) throws {
    for (_, field) in fields.entries {
        for child in try field.change.nestedChanges() {
            let state: NodeAttachState = parentState == .detached || child.inputRootId != nil ? .detached : .attached
            let node = try nodeChangeFromId(change, id: child.nodeId)
            if let constraint = node.nodeExistsConstraint, constraint.violated != (state == .detached) {
                node.nodeExistsConstraint = NodeExistsConstraint(violated: state == .detached)
                violations += state == .detached ? 1 : -1
            }
            if let fields = node.fieldChanges { try updateConstraintsForFields(fields, parentState: state, change: change, violations: &violations) }
        }
    }
}

func fieldMapFromNodeId(_ change: ModularChangeset, nodeId: ChangeAtomId?) throws -> FieldChangeMap {
    guard let nodeId else { return change.fieldChanges }
    guard let fields = try nodeChangeFromId(change, id: nodeId).fieldChanges else { throw JSONDecodingError("0x9c9: node requires field changes") }
    return fields
}
func fieldChangeFromId(_ change: ModularChangeset, id: FieldId) throws -> FieldChange {
    guard let field = try fieldMapFromNodeId(change, nodeId: id.nodeId)[id.field] else { throw JSONDecodingError("0xb25: missing field") }
    return field
}
func getParentFieldId(_ change: ModularChangeset, nodeId: ChangeAtomId) throws -> FieldId {
    let id = try normalizeNodeId(nodeId, aliases: change.nodeAliases)
    guard let parent = change.nodeToParent.get(id) else { throw JSONDecodingError("0x9cb: missing parent field") }
    return try normalizeFieldId(parent, aliases: change.nodeAliases)
}
func getFieldsForCrossFieldKey(_ change: ModularChangeset, key: CrossFieldKey, count: Int) throws -> [FieldId] {
    try change.crossFieldKeys.getAll(key, count: count).compactMap { entry in
        try entry.value.map { try normalizeFieldId($0, aliases: change.nodeAliases) }
    }
}
