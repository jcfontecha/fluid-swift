import FluidJS

/// feature-libraries/changeAtomIdBTree.ts: tuple keys are represented by a typed atom.
public typealias ChangeAtomIdBTree<Value> = BTree<ChangeAtomId, Value>
public func newChangeAtomIdBTree<Value>(context: BTreeStorageContext = BTreeStorageContext()) -> ChangeAtomIdBTree<Value> {
    BTree(context: context, compare: { a, b in
        let revision = comparePartialRevisions(a.revision, b.revision)
        return revision != 0 ? revision : a.localId < b.localId ? -1 : a.localId > b.localId ? 1 : 0
    })
}

/// feature-libraries/default-schema/defaultFieldKinds.ts and genericFieldKind.ts.
public enum FieldKindIdentifier: String {
    case sequence = "Sequence"
    case optional = "Optional"
    case required = "Value"
    case identifier = "Identifier"
    case forbidden = "Forbidden"
    case generic = "ModularEditBuilder.Generic"
}

/// feature-libraries/modular-schema/modularChangeTypes.ts: typed field payloads.
public enum FieldChangeset {
    case sequence([SequenceMark])
    case optional(OptionalChangeset)
    case generic(GenericChangeset)
    case noChange

    public func converted(to kind: FieldKindIdentifier) throws -> FieldChangeset {
        guard case .generic(let changes) = self else { return self }
        if kind == .generic { return self }
        let children = try changes.entries.map { index, node in
            guard let node else { throw JSONDecodingError("generic change requires node ID") }
            return (index, node)
        }
        switch kind {
        case .sequence: return .sequence(try SequenceFieldEditor().buildChildChanges(children))
        case .optional, .required: return .optional(try OptionalFieldEditor().buildChildChanges(children))
        case .identifier, .forbidden: throw JSONDecodingError("0xb0d: child changes not supported")
        case .generic: return self
        }
    }
    public var isEmpty: Bool {
        switch self {
        case .sequence(let change): return SequenceFieldChangeHandler().isEmpty(change)
        case .optional(let change): return change.isEmpty
        case .generic(let change): return change.isEmpty
        case .noChange: return true
        }
    }
    public func nestedChanges() throws -> [ChildChangeInfo] {
        switch self {
        case .sequence(let change): return try SequenceFieldChangeHandler().getNestedChanges(change)
        case .optional(let change): return OptionalChangeHandler().getNestedChanges(change)
        case .generic(let change): return try GenericChangeHandler().getNestedChanges(change)
        case .noChange: return []
        }
    }
    public var crossFieldKeys: [CrossFieldKeyRange] {
        if case .sequence(let change) = self { return SequenceFieldChangeHandler().getCrossFieldKeys(change) }
        return []
    }
}
public final class FieldChange: Hashable {
    public static func == (lhs: FieldChange, rhs: FieldChange) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    public var fieldKind: FieldKindIdentifier
    public var change: FieldChangeset
    public init(fieldKind: FieldKindIdentifier, change: FieldChangeset) {
        self.fieldKind = fieldKind
        self.change = change
    }
}
/// JavaScript Map identity is observable when a composed node shares a field map.
public final class FieldChangeMap {
    private var data = OrderedMap<JSString, FieldChange>()
    public init() {}
    public var entries: [(JSString, FieldChange)] { data.entries }
    public var keys: [JSString] { data.keys }
    public var count: Int { data.count }
    public var isEmpty: Bool { data.isEmpty }
    public subscript(_ key: JSString) -> FieldChange? {
        get { data[key] }
        set { data[key] = newValue }
    }
    public func copy() -> FieldChangeMap {
        let result = FieldChangeMap()
        result.data = data
        return result
    }
}
public struct FieldId: Hashable {
    public var nodeId: ChangeAtomId?
    public var field: JSString
    public init(nodeId: ChangeAtomId? = nil, field: JSString) {
        self.nodeId = nodeId
        self.field = field
    }
}
public struct NodeExistsConstraint: Equatable {
    public var violated: Bool
    public init(violated: Bool) { self.violated = violated }
}
public struct NoChangeConstraint: Equatable {
    public var violated: Bool
    public init(violated: Bool) { self.violated = violated }
}
enum NodeProperty { case fieldChanges, nodeExistsConstraint, nodeExistsConstraintOnRevert }
public final class NodeChangeset: Hashable {
    public static func == (lhs: NodeChangeset, rhs: NodeChangeset) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    var propertyOrder: [NodeProperty] = []
    public var fieldChanges: FieldChangeMap? { didSet { presence(.fieldChanges, fieldChanges != nil) } }
    public var nodeExistsConstraint: NodeExistsConstraint? { didSet { presence(.nodeExistsConstraint, nodeExistsConstraint != nil) } }
    public var nodeExistsConstraintOnRevert: NodeExistsConstraint? { didSet { presence(.nodeExistsConstraintOnRevert, nodeExistsConstraintOnRevert != nil) } }
    private func presence(_ key: NodeProperty, _ present: Bool) {
        if !present { propertyOrder.removeAll { $0 == key } }
        else if !propertyOrder.contains(key) { propertyOrder.append(key) }
    }
    func copy() -> NodeChangeset {
        let result = NodeChangeset(fieldChanges: fieldChanges, nodeExistsConstraint: nodeExistsConstraint, nodeExistsConstraintOnRevert: nodeExistsConstraintOnRevert)
        result.propertyOrder = propertyOrder
        return result
    }
    public init(fieldChanges: FieldChangeMap? = nil, nodeExistsConstraint: NodeExistsConstraint? = nil, nodeExistsConstraintOnRevert: NodeExistsConstraint? = nil) {
        self.fieldChanges = fieldChanges
        self.nodeExistsConstraint = nodeExistsConstraint
        self.nodeExistsConstraintOnRevert = nodeExistsConstraintOnRevert
        presence(.fieldChanges, fieldChanges != nil)
        presence(.nodeExistsConstraint, nodeExistsConstraint != nil)
        presence(.nodeExistsConstraintOnRevert, nodeExistsConstraintOnRevert != nil)
    }
}

/// Chunked-forest dependency used by the modular family. Concrete chunks and
/// their batch codecs own cursor/storage representation, not the change family.
public protocol TreeChunk: AnyObject {
    var topLevelLength: Int { get }
    func referenceAdded()
    func referenceRemoved()
    func isShared() -> Bool
}

public typealias CrossFieldKeyTable = RangeMap<CrossFieldKey, FieldId>
public func newCrossFieldKeyTable(context: BTreeStorageContext = BTreeStorageContext()) -> CrossFieldKeyTable {
    RangeMap(offsetKey: { key, offset in
        CrossFieldKey(target: key.target, revision: key.revision, localId: key.localId + Double(offset))
    }, subtractKeys: { a, b in
        if a.target != b.target { return a.target == .source ? -.infinity : .infinity }
        return subtractChangeAtomIds(ChangeAtomId(localId: a.localId, revision: a.revision), ChangeAtomId(localId: b.localId, revision: b.revision))
    }, context: context)
}

/// feature-libraries/modular-schema/modularChangeTypes.ts.
public struct ModularChangeset {
    public let context: BTreeStorageContext
    public var fieldChanges: FieldChangeMap
    public var nodeChanges: ChangeAtomIdBTree<NodeChangeset>
    public var nodeToParent: ChangeAtomIdBTree<FieldId>
    public var nodeAliases: ChangeAtomIdBTree<ChangeAtomId>
    public var crossFieldKeys: CrossFieldKeyTable
    public var maxId: Double?
    public var revisions: [RevisionInfo]?
    public var constraintViolationCount: Int?
    public var noChangeConstraint: NoChangeConstraint?
    public var noChangeConstraintOnRevert: NoChangeConstraint?
    public var builds: ChangeAtomIdBTree<any TreeChunk>?
    public var destroys: ChangeAtomIdBTree<Int>?
    public var refreshers: ChangeAtomIdBTree<any TreeChunk>?
    public init(context: BTreeStorageContext = BTreeStorageContext()) {
        self.context = context
        fieldChanges = FieldChangeMap()
        nodeChanges = newChangeAtomIdBTree(context: context)
        nodeToParent = newChangeAtomIdBTree(context: context)
        nodeAliases = newChangeAtomIdBTree(context: context)
        crossFieldKeys = newCrossFieldKeyTable(context: context)
    }
}

/// feature-libraries/modular-schema/modularChangeUtils.ts.
public func normalizeNodeId(_ id: ChangeAtomId, aliases: ChangeAtomIdBTree<ChangeAtomId>) throws -> ChangeAtomId {
    let visited: ChangeAtomIdBTree<Bool> = newChangeAtomIdBTree(context: aliases.context)
    var current = id
    while true {
        visited.set(current, true)
        guard let next = aliases.get(current) else { return current }
        guard !visited.has(next) else { throw JSONDecodingError("0xd42: node alias loop") }
        current = next
    }
}
public func nodeChangeFromId(_ change: ModularChangeset, id: ChangeAtomId) throws -> NodeChangeset {
    let canonical = try normalizeNodeId(id, aliases: change.nodeAliases)
    guard let node = change.nodeChanges.get(canonical) else { throw JSONDecodingError("0x9ca: unknown node ID") }
    return node
}
public func normalizeFieldId(_ id: FieldId, aliases: ChangeAtomIdBTree<ChangeAtomId>) throws -> FieldId {
    FieldId(nodeId: try id.nodeId.map { try normalizeNodeId($0, aliases: aliases) }, field: id.field)
}
