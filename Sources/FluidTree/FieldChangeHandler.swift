import FluidJS

/// core/tree/delta.ts. Detached node IDs are distinct from empty-cell IDs.
public struct DeltaDetachedNodeId: Equatable, Hashable {
    public var major: RevisionTag?
    public var minor: Double
    public init(_ atom: ChangeAtomId) {
        major = atom.revision
        minor = atom.localId
    }
}
public typealias DeltaFieldMap = OrderedMap<JSString, DeltaFieldChanges>
public struct DeltaMark: Equatable {
    public var count: Int
    public var fields: DeltaFieldMap?
    public var detach: DeltaDetachedNodeId?
    public var attach: DeltaDetachedNodeId?
    public init(count: Int, fields: DeltaFieldMap? = nil, detach: DeltaDetachedNodeId? = nil, attach: DeltaDetachedNodeId? = nil) {
        self.count = count
        self.fields = fields
        self.detach = detach
        self.attach = attach
    }
}
public struct DeltaFieldChanges: Equatable {
    public var marks: [DeltaMark]
    public init(marks: [DeltaMark]) { self.marks = marks }
}
public struct DeltaDetachedNodeChanges: Equatable {
    public var id: DeltaDetachedNodeId
    public var fields: DeltaFieldMap
    public init(id: DeltaDetachedNodeId, fields: DeltaFieldMap) {
        self.id = id
        self.fields = fields
    }
}
public struct DeltaDetachedNodeRename: Equatable {
    public var count: Int
    public var oldId: DeltaDetachedNodeId
    public var newId: DeltaDetachedNodeId
    public init(count: Int, oldId: DeltaDetachedNodeId, newId: DeltaDetachedNodeId) {
        self.count = count
        self.oldId = oldId
        self.newId = newId
    }
}
/// feature-libraries/modular-schema/fieldChangeHandler.ts.
public struct FieldChangeDelta: Equatable {
    public var local: DeltaFieldChanges?
    public var global: [DeltaDetachedNodeChanges]?
    public var rename: [DeltaDetachedNodeRename]?
    public init() {}
}
public struct ChildChangeInfo: Equatable {
    public var nodeId: ChangeAtomId
    public var inputRootId: ChangeAtomId?
    public var detachId: ChangeAtomId?
    public init(nodeId: ChangeAtomId, inputRootId: ChangeAtomId?, detachId: ChangeAtomId?) {
        self.nodeId = nodeId
        self.inputRootId = inputRootId
        self.detachId = detachId
    }
}
/// feature-libraries/modular-schema/modularChangeTypes.ts.
public struct CrossFieldKey: Hashable {
    public var target: CrossFieldTarget
    public var revision: RevisionTag?
    public var localId: Double
    public init(target: CrossFieldTarget, revision: RevisionTag?, localId: Double) {
        self.target = target
        self.revision = revision
        self.localId = localId
    }
}
public struct CrossFieldKeyRange: Equatable {
    public var key: CrossFieldKey
    public var count: Int
    public init(key: CrossFieldKey, count: Int) {
        self.key = key
        self.count = count
    }
}
