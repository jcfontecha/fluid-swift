import FluidJS

/// codec/versioned: pinned writer compatibility thresholds used by SharedTree.
public struct FluidClientVersion: Comparable, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
    public static let v2_0 = FluidClientVersion(major: 2, minor: 0)
    public static let v2_43 = FluidClientVersion(major: 2, minor: 43)
    public static let v2_80 = FluidClientVersion(major: 2, minor: 80)
    public static let v2_117 = FluidClientVersion(major: 2, minor: 117)
    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch) }
}

/// util/idAllocator.ts.
public final class IdAllocator {
    private var maximum: Double
    public init(maxId: Double = -1) { maximum = maxId }
    public func allocate(_ count: Double = 1) throws -> Double {
        guard count > 0 else { throw JSONDecodingError("0x5cf: must allocate at least one ID") }
        let first = maximum + 1
        maximum += count
        return first
    }
    public func getMaxId() -> Double { maximum }
}

/// core/tree/pathTree.ts: upward authored paths.
public final class UpPath {
    public let parent: UpPath?
    public let parentField: JSString
    public let parentIndex: Int
    public init(parent: UpPath? = nil, parentField: JSString, parentIndex: Int) {
        self.parent = parent
        self.parentField = parentField
        self.parentIndex = parentIndex
    }
}
public struct FieldUpPath {
    public let parent: UpPath?
    public let field: JSString
    public init(parent: UpPath? = nil, field: JSString) {
        self.parent = parent
        self.field = field
    }
}
public enum EditDescription {
    case field(path: FieldUpPath, change: FieldChange, revision: RevisionTag)
    case global(builds: ChangeAtomIdBTree<any TreeChunk>?, revision: RevisionTag)
    var revision: RevisionTag {
        switch self {
        case .field(_, _, let revision), .global(_, let revision): return revision
        }
    }
}

/// core/change-family/editBuilder.ts.
public class EditBuilder<Change> {
    private let receiver: (TaggedChange<Change>) throws -> Void
    public init(receiver: @escaping (TaggedChange<Change>) throws -> Void) { self.receiver = receiver }
    func applyChange(_ change: TaggedChange<Change>) throws { try receiver(change) }
    public func enterTransaction() {}
    public func exitTransaction() throws {}
}

/// feature-libraries/modular-schema/modularChangeFamily.ts: ModularEditBuilder.
public final class ModularEditBuilder: EditBuilder<ModularChangeset> {
    private let family: ModularChangeFamily
    private var transactionDepth = 0
    private var allocator = IdAllocator()
    public init(family: ModularChangeFamily, receiver: @escaping (TaggedChange<ModularChangeset>) throws -> Void) {
        self.family = family
        super.init(receiver: receiver)
    }
    public override func enterTransaction() {
        transactionDepth += 1
        if transactionDepth == 1 { allocator = IdAllocator() }
    }
    public override func exitTransaction() throws {
        guard transactionDepth > 0 else { throw JSONDecodingError("0x5b9: cannot exit nonexistent transaction") }
        transactionDepth -= 1
        if transactionDepth == 0 { allocator = IdAllocator() }
    }
    public func generateId(_ count: Double = 1) throws -> Double { try allocator.allocate(count) }
    public func buildTrees(firstId: Double, content: any TreeChunk, revision: RevisionTag) -> EditDescription {
        guard content.topLevelLength != 0 else { return .global(builds: nil, revision: revision) }
        content.referenceAdded()
        let builds: ChangeAtomIdBTree<any TreeChunk> = newChangeAtomIdBTree(context: family.context)
        builds.set(ChangeAtomId(localId: firstId, revision: revision), content)
        return .global(builds: builds, revision: revision)
    }
    public func buildChanges(_ edits: [EditDescription]) throws -> ModularChangeset {
        var revisions: [RevisionInfo] = []
        var seen: Set<RevisionTag> = []
        var changes: [TaggedChange<ModularChangeset>] = []
        for edit in edits {
            if seen.insert(edit.revision).inserted { revisions.append(RevisionInfo(revision: edit.revision)) }
            var change = ModularChangeset(context: family.context)
            switch edit {
            case .global(let builds, let revision):
                change.builds = builds
                change.maxId = allocator.getMaxId()
                change.revisions = [RevisionInfo(revision: revision)]
            case .field(let path, let field, let revision):
                try wrapField(path: path, field: field, localKeys: field.change.crossFieldKeys, revision: revision, result: &change)
            }
            changes.append(TaggedChange(change: normalizedModularChangeset(change)))
        }
        var result = try family.compose(changes)
        result.revisions = revisions
        if allocator.getMaxId() >= 0 { result.maxId = allocator.getMaxId() }
        return result
    }
    public func submitChanges(_ edits: [EditDescription], revision: RevisionTag) throws {
        try applyChange(TaggedChange(change: buildChanges(edits), revision: revision))
    }
    public func submitChange(path: FieldUpPath, field: FieldChange, revision: RevisionTag) throws {
        var change = ModularChangeset(context: family.context)
        try wrapField(path: path, field: field, localKeys: field.change.crossFieldKeys, revision: revision, result: &change)
        try applyChange(TaggedChange(change: normalizedModularChangeset(change), revision: revision))
    }
    public func addNodeExistsConstraint(path: UpPath, revision: RevisionTag) throws {
        try addNodeConstraint(path: path, revision: revision, onRevert: false)
    }
    public func addNodeExistsConstraintOnRevert(path: UpPath, revision: RevisionTag) throws {
        try addNodeConstraint(path: path, revision: revision, onRevert: true)
    }
    private func addNodeConstraint(path: UpPath, revision: RevisionTag, onRevert: Bool) throws {
        let node = NodeChangeset(nodeExistsConstraint: onRevert ? nil : NodeExistsConstraint(violated: false), nodeExistsConstraintOnRevert: onRevert ? NodeExistsConstraint(violated: false) : nil)
        var change = ModularChangeset(context: family.context)
        try wrapNode(path: path, node: node, revision: revision, result: &change)
        try applyChange(TaggedChange(change: normalizedModularChangeset(change), revision: revision))
    }
    public func addNoChangeConstraint(revision: RevisionTag) throws { try addDocumentConstraint(revision: revision, onRevert: false) }
    public func addNoChangeConstraintOnRevert(revision: RevisionTag) throws { try addDocumentConstraint(revision: revision, onRevert: true) }
    private func addDocumentConstraint(revision: RevisionTag, onRevert: Bool) throws {
        guard family.minimumClientVersion >= .v2_80 else { throw JSONDecodingError("no-change constraints require client version 2.80.0") }
        var change = ModularChangeset(context: family.context)
        if onRevert { change.noChangeConstraintOnRevert = NoChangeConstraint(violated: false) }
        else { change.noChangeConstraint = NoChangeConstraint(violated: false) }
        try applyChange(TaggedChange(change: change, revision: revision))
    }
    private func wrapField(path: FieldUpPath, field: FieldChange, localKeys: [CrossFieldKeyRange], childId: ChangeAtomId? = nil, revision: RevisionTag, result: inout ModularChangeset) throws {
        let fields = FieldChangeMap()
        fields[path.field] = field
        let parentId = try path.parent.map { _ in ChangeAtomId(localId: try allocator.allocate(), revision: revision) }
        let fieldId = FieldId(nodeId: parentId, field: path.field)
        for range in localKeys { result.crossFieldKeys.set(range.key, count: range.count, value: fieldId) }
        if let childId { result.nodeToParent.set(childId, fieldId) }
        if let parent = path.parent, let parentId {
            try wrapNode(path: parent, node: NodeChangeset(fieldChanges: fields), nodeId: parentId, revision: revision, result: &result)
        } else {
            result.fieldChanges = fields
            result.maxId = allocator.getMaxId()
            result.revisions = [RevisionInfo(revision: revision)]
        }
    }
    private func wrapNode(path: UpPath, node: NodeChangeset, nodeId: ChangeAtomId? = nil, revision: RevisionTag, result: inout ModularChangeset) throws {
        let id = try nodeId ?? ChangeAtomId(localId: allocator.allocate(), revision: revision)
        result.nodeChanges.set(id, node)
        let generic = newGenericChangeset([(path.parentIndex, id)], context: family.context)
        let field = FieldChange(fieldKind: .generic, change: .generic(generic))
        try wrapField(path: FieldUpPath(parent: path.parent, field: path.parentField), field: field, localKeys: [], childId: id, revision: revision, result: &result)
    }
}

extension ModularChangeFamily {
    public func buildEditor(changeReceiver: @escaping (TaggedChange<ModularChangeset>) throws -> Void) -> ModularEditBuilder {
        ModularEditBuilder(family: self, receiver: changeReceiver)
    }
}
