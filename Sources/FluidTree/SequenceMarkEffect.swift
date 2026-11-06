/// Enumerable properties used by the upstream sequence mark objects. Values
/// remain strongly typed; this compact order records JS construction/spread semantics.
public enum SequenceProperty: UInt8, Sendable {
    case type, id, revision, finalEndpoint, idOverride, attach, detach, count, cellId, changes
    var isEffect: Bool { self != .count && self != .cellId && self != .changes }
    var name: String {
        switch self {
        case .type: return "type"
        case .id: return "id"
        case .revision: return "revision"
        case .finalEndpoint: return "finalEndpoint"
        case .idOverride: return "idOverride"
        case .attach: return "attach"
        case .detach: return "detach"
        case .count: return "count"
        case .cellId: return "cellId"
        case .changes: return "changes"
        }
    }
}

/// feature-libraries/sequence-field/types.ts. Object provenance is not semantic
/// equality, but is preserved for the harness's separate structural contract.
public struct SequenceMarkEffect: Equatable, Sendable {
    public indirect enum Kind: Equatable, Sendable {
        case rename(idOverride: ChangeAtomId)
        case attachAndDetach(attach: SequenceMarkEffect, detach: SequenceMarkEffect)
        case noop
        case insert(id: Double, revision: RevisionTag?)
        case remove(id: Double, revision: RevisionTag?, idOverride: ChangeAtomId?)
        case moveIn(id: Double, revision: RevisionTag?, finalEndpoint: ChangeAtomId?)
        case moveOut(id: Double, revision: RevisionTag?, finalEndpoint: ChangeAtomId?, idOverride: ChangeAtomId?)
    }
    public var kind: Kind
    public var propertyOrder: [SequenceProperty]
    var extraEndpoint: ChangeAtomId?
    var extraOverride: ChangeAtomId?
    public init(kind: Kind, propertyOrder: [SequenceProperty]) {
        self.kind = kind
        self.propertyOrder = propertyOrder
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.kind == rhs.kind }
    public static var noop: Self { .init(kind: .noop, propertyOrder: []) }
    public static func insert(id: Double, revision: RevisionTag?) -> Self {
        .init(kind: .insert(id: id, revision: revision), propertyOrder: [.type, .id, .revision])
    }
    public static func remove(id: Double, revision: RevisionTag?, idOverride: ChangeAtomId?) -> Self {
        .init(kind: .remove(id: id, revision: revision, idOverride: idOverride), propertyOrder: [.type, .id, .revision] + (idOverride == nil ? [] : [.idOverride]))
    }
    public static func moveIn(id: Double, revision: RevisionTag?, finalEndpoint: ChangeAtomId?) -> Self {
        .init(kind: .moveIn(id: id, revision: revision, finalEndpoint: finalEndpoint), propertyOrder: [.type, .id, .revision] + (finalEndpoint == nil ? [] : [.finalEndpoint]))
    }
    public static func moveOut(id: Double, revision: RevisionTag?, finalEndpoint: ChangeAtomId?, idOverride: ChangeAtomId?) -> Self {
        .init(kind: .moveOut(id: id, revision: revision, finalEndpoint: finalEndpoint, idOverride: idOverride), propertyOrder: [.type, .id, .revision] + (finalEndpoint == nil ? [] : [.finalEndpoint]) + (idOverride == nil ? [] : [.idOverride]))
    }
    public static func rename(idOverride: ChangeAtomId) -> Self {
        .init(kind: .rename(idOverride: idOverride), propertyOrder: [.type, .idOverride])
    }
    public static func attachAndDetach(attach: Self, detach: Self) -> Self {
        .init(kind: .attachAndDetach(attach: attach, detach: detach), propertyOrder: [.type, .attach, .detach])
    }
    func preservingProperties(_ replacement: Self) -> Self {
        var result = replacement
        result.propertyOrder = propertyOrder
        result.extraEndpoint = extraEndpoint
        result.extraOverride = extraOverride
        return result
    }
}
