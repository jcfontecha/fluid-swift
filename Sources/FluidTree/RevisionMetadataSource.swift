import FluidJS

/// core/rebase/types.ts.
public struct RevisionInfo: Equatable {
    public var revision: RevisionTag
    public var rollbackOf: RevisionTag?
    var includesRollbackOf: Bool
    public init(revision: RevisionTag, rollbackOf: RevisionTag? = nil, includesRollbackOf: Bool? = nil) {
        self.includesRollbackOf = includesRollbackOf ?? (rollbackOf != nil)
        self.revision = revision
        self.rollbackOf = rollbackOf
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.revision == rhs.revision && lhs.rollbackOf == rhs.rollbackOf }
}

/// core/rebase/utils.ts: revisionMetadataSourceFromInfo.
public struct RevisionMetadataSource {
    public let infos: [RevisionInfo]
    public init(_ infos: [RevisionInfo]) {
        self.infos = infos
    }
    public func getIndex(_ revision: RevisionTag) -> Int? {
        infos.firstIndex { $0.revision == revision }
    }
    public func tryGetInfo(_ revision: RevisionTag?) -> RevisionInfo? {
        guard let revision, let index = getIndex(revision) else { return nil }
        return infos[index]
    }
    public func hasRollback(_ revision: RevisionTag) -> Bool {
        infos.contains { $0.rollbackOf == revision }
    }
}

/// feature-libraries/sequence-field/utils.ts.
enum CellOrder {
    case sameCell
    case oldThenNew
    case newThenOld
}

func compareCellPositionsUsingTombstones(_ old: ChangeAtomId, _ new: ChangeAtomId, oldKnowledge: Set<RevisionTag?>, newKnowledge: Set<RevisionTag?>, metadata: RevisionMetadataSource) throws -> CellOrder {
    if old == new { return .sameCell }
    let oldKnowsNew = oldKnowledge.contains(new.revision)
    let newKnowsOld = newKnowledge.contains(old.revision)
    if oldKnowsNew && newKnowsOld {
        guard old.revision == new.revision else {
            throw JSONDecodingError("0x8a0: inconsistent cell ordering")
        }
        return .newThenOld
    }
    if newKnowsOld { return .newThenOld }
    if oldKnowsNew { return .oldThenNew }
    guard let newRevision = new.revision else { return .newThenOld }
    guard let oldRevision = old.revision else {
        throw JSONDecodingError("0x8a1: old mark cell should have a revision")
    }
    let oldIndex = metadata.getIndex(oldRevision)
    let newIndex = metadata.getIndex(newRevision)
    if let oldIndex, let newIndex {
        return newIndex > oldIndex ? .newThenOld : .oldThenNew
    }
    guard oldIndex != nil || newIndex != nil else {
        throw JSONDecodingError("0x8a2: invalid cell ordering scenario")
    }
    return oldIndex == nil ? .newThenOld : .oldThenNew
}
