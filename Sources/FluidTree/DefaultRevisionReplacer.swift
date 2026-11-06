import FluidJS

/// core/rebase: RevisionReplacer contract.
public protocol RevisionReplacer {
    var updatedRevision: RevisionTag { get }
    func isObsolete(_ revision: RevisionTag?) -> Bool
    func getUpdatedAtomId(_ id: ChangeAtomId, count: Int) throws -> ChangeAtomId
}

/// feature-libraries/modular-schema/defaultRevisionReplacer.ts.
public final class DefaultRevisionReplacer: RevisionReplacer {
    public let updatedRevision: RevisionTag
    private let obsoleteRevisions: Set<RevisionTag?>
    private var updatedLocalIds = ChangeAtomIdRangeMap<Double>(offsetValue: { value, offset in value + Double(offset) })
    private var localIds = ChangeAtomIdRangeMap<Bool>()
    private var maxSeen: Double = -1
    public init(updatedRevision: RevisionTag, obsoleteRevisions: Set<RevisionTag?>) {
        self.updatedRevision = updatedRevision
        self.obsoleteRevisions = obsoleteRevisions
    }
    public func isObsolete(_ revision: RevisionTag?) -> Bool { obsoleteRevisions.contains(revision) }
    public func getUpdatedAtomId(_ id: ChangeAtomId, count: Int = 1) throws -> ChangeAtomId {
        guard count >= 1 else { throw JSONDecodingError("0xcc9: count must be at least one") }
        guard isObsolete(id.revision) else { return id }
        var updated = id
        updated.revision = updatedRevision
        if !updated.includesRevision { updated.propertyOrder = .localIdFirst }
        updated.includesRevision = true
        var continuing: Double?
        var remaining = count
        var start = id
        while remaining > 0 {
            let prior = updatedLocalIds.getFirst(start, count: remaining)
            let newId: Double
            if let known = prior.value {
                newId = known
                if let continuing, continuing != known { throw JSONDecodingError("0xccb: non-contiguous range") }
            } else {
                let defaultId = continuing ?? start.localId
                newId = areAllUnallocated(defaultId, count: prior.length) ? defaultId : maxSeen + 1
                maxSeen = max(maxSeen, newId + Double(prior.length) - 1)
                localIds.set(ChangeAtomId(localId: newId), count: prior.length, value: true)
                updatedLocalIds.set(start, count: prior.length, value: newId)
                if let continuing, newId != continuing { throw JSONDecodingError("0xcca: non-contiguous range") }
            }
            if continuing == nil { updated.localId = newId }
            continuing = newId + Double(prior.length)
            start = start.offset(prior.length)
            remaining -= prior.length
        }
        return updated
    }
    private func areAllUnallocated(_ id: Double, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let entry = localIds.getFirst(ChangeAtomId(localId: id + Double(offset)), count: count - offset)
            if entry.value != nil { return false }
            offset += entry.length
        }
        return true
    }
}

/// feature-libraries/sequence-field/replaceRevisions.ts.
public func replaceSequenceRevisions<R: RevisionReplacer>(_ change: [SequenceMark], replacer: R) throws -> [SequenceMark] {
    let factory = MarkListFactory()
    for var mark in change {
        mark.effect = try replaceEffectRevisions(mark.effect, count: mark.count, replacer: replacer)
        if let cell = mark.cellId { mark.cellId = try replacer.getUpdatedAtomId(cell, count: mark.count) }
        if let child = mark.changes { mark.changes = try replacer.getUpdatedAtomId(child, count: 1) }
        factory.push(mark)
    }
    return factory.list
}

private func replaceEffectRevisions<R: RevisionReplacer>(_ effect: SequenceMarkEffect, count: Int, replacer: R) throws -> SequenceMarkEffect {
    func replace(_ id: ChangeAtomId) throws -> ChangeAtomId { try replacer.getUpdatedAtomId(id, count: count) }
    switch effect.kind {
    case .noop: return effect
    case .rename(let target): return .rename(idOverride: try replace(target))
    case .attachAndDetach(let attach, let detach):
        return try .attachAndDetach(attach: replaceEffectRevisions(attach, count: count, replacer: replacer), detach: replaceEffectRevisions(detach, count: count, replacer: replacer))
    default:
        // Upstream allocates overrides, then endpoints, then the effect's own ID.
        let override: ChangeAtomId?
        switch effect.kind {
        case .remove(_, _, let target), .moveOut(_, _, _, let target): override = try target.map(replace)
        default: override = nil
        }
        let endpoint: ChangeAtomId?
        switch effect.kind {
        case .moveIn(_, _, let target), .moveOut(_, _, let target, _): endpoint = try target.map(replace)
        default: endpoint = nil
        }
        let original = try effect.atomId()
        let atom = try replacer.isObsolete(original.revision) ? replace(original) : original
        switch effect.kind {
        case .insert: return .insert(id: atom.localId, revision: atom.revision)
        case .remove: return .remove(id: atom.localId, revision: atom.revision, idOverride: override)
        case .moveIn: return .moveIn(id: atom.localId, revision: atom.revision, finalEndpoint: endpoint)
        case .moveOut: return .moveOut(id: atom.localId, revision: atom.revision, finalEndpoint: endpoint, idOverride: override)
        default: throw JSONDecodingError("unexpected revision replacement effect")
        }
    }
}
