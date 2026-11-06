import FluidJS

/// feature-libraries/sequence-field/moveEffectTable.ts.
public struct MoveEffect: Equatable {
    public var modifyAfter: ChangeAtomId?
    public var movedEffect: SequenceMarkEffect?
    public var rebasedChanges: ChangeAtomId?
    public var endpoint: ChangeAtomId?
    public var truncatedEndpoint: ChangeAtomId?
    public var truncatedEndpointForInner: ChangeAtomId?
    var basis: Double?
    // rebase.ts sendEffectToDest writes this distinct property in its split branch.
    // Preserve the upstream behavior rather than silently correcting it.
    var movedMark: SequenceMarkEffect?
    public init(modifyAfter: ChangeAtomId? = nil, movedEffect: SequenceMarkEffect? = nil, rebasedChanges: ChangeAtomId? = nil, endpoint: ChangeAtomId? = nil, truncatedEndpoint: ChangeAtomId? = nil, truncatedEndpointForInner: ChangeAtomId? = nil) {
        self.modifyAfter = modifyAfter
        self.movedEffect = movedEffect
        self.rebasedChanges = rebasedChanges
        self.endpoint = endpoint
        self.truncatedEndpoint = truncatedEndpoint
        self.truncatedEndpointForInner = truncatedEndpointForInner
    }
}

func setMoveEffect<M: CrossFieldManager>(_ manager: M, target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int, effect: MoveEffect, invalidate: Bool = true) throws where M.Value == MoveEffect {
    var value = effect
    value.basis = id
    try manager.set(target, revision: revision, id: id, count: count, value: value, invalidateDependents: invalidate)
}

func getMoveEffect<M: CrossFieldManager>(_ manager: M, target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int, addDependency: Bool = true) throws -> CrossFieldRange<MoveEffect> where M.Value == MoveEffect {
    let result = manager.get(target, revision: revision, id: id, count: count, addDependency: addDependency)
    guard var value = result.value else {
        return result
    }
    guard let basis = value.basis, id >= basis else {
        throw JSONDecodingError("0x812: expected positive move-effect basis shift")
    }
    if basis != id {
        let shift = Int(id - basis)
        value.basis = id
        value.endpoint = value.endpoint?.offset(shift)
        value.truncatedEndpoint = value.truncatedEndpoint?.offset(shift)
        value.truncatedEndpointForInner = value.truncatedEndpointForInner?.offset(shift)
        value.movedEffect = value.movedEffect?.offset(shift)
    }
    return CrossFieldRange(length: result.length, value: value)
}

func firstMoveEffectLength<M: CrossFieldManager>(_ effect: SequenceMarkEffect, count: Int, manager: M) throws -> Int where M.Value == MoveEffect {
    switch effect.kind {
    case .moveIn(let id, let revision, _):
        return try getMoveEffect(manager, target: .destination, revision: revision, id: id, count: count).length
    case .moveOut(let id, let revision, _, _):
        return try getMoveEffect(manager, target: .source, revision: revision, id: id, count: count).length
    case .attachAndDetach(let attach, let detach):
        return try min(firstMoveEffectLength(attach, count: count, manager: manager), firstMoveEffectLength(detach, count: count, manager: manager))
    default:
        return count
    }
}
