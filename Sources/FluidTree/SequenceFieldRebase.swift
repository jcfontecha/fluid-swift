import FluidJS

/// feature-libraries/modular-schema/fieldChangeHandler.ts.
public enum NodeAttachState: Equatable {
    case attached
    case detached
}
public typealias NodeChangeRebaser = (ChangeAtomId?, ChangeAtomId?, NodeAttachState?) throws -> ChangeAtomId?

/// feature-libraries/sequence-field/rebase.ts.
public func rebaseSequence<M: CrossFieldManager>(_ change: [SequenceMark], over base: [SequenceMark], metadata: RevisionMetadataSource, manager: M, rebaseChild: NodeChangeRebaser) throws -> [SequenceMark] where M.Value == MoveEffect {
    let factory = MarkListFactory()
    let queue = RebaseQueue(base: base, change: change, metadata: metadata, manager: manager)
    while try !queue.isEmpty() {
        let (baseMark, newMark) = try queue.pop()
        var current = newMark
        if current.changes != nil || baseMark.changes != nil {
            let state: NodeAttachState = baseMark.emptiesCells ? .detached : baseMark.fillsCells ? .attached : baseMark.cellId == nil ? .attached : .detached
            current.changes = try rebaseChild(current.changes, baseMark.changes, state)
        }
        if let moved = try movedData(baseMark, manager: manager)?.rebasedChanges {
            guard current.changes == nil else {
                throw JSONDecodingError("0x8dc: collision of new node changes")
            }
            current.changes = moved
            manager.onMoveIn(moved)
        }
        factory.push(try rebaseMarkIgnoreChild(current, base: baseMark, manager: manager))
    }
    return factory.list
}

/// feature-libraries/sequence-field/rebase.ts: RebaseQueue.
final class RebaseQueue<M: CrossFieldManager> where M.Value == MoveEffect {
    private let base: MarkQueue<M>
    private let change: MarkQueue<M>
    private let baseKnowledge: Set<RevisionTag?>
    private let newKnowledge: Set<RevisionTag?>
    private let metadata: RevisionMetadataSource
    private let manager: M
    init(base: [SequenceMark], change: [SequenceMark], metadata: RevisionMetadataSource, manager: M) {
        self.base = MarkQueue(base, manager: manager)
        self.change = MarkQueue(change, manager: manager)
        baseKnowledge = Set(base.compactMap(\.cellId).map(\.revision))
        newKnowledge = Set(change.compactMap(\.cellId).map(\.revision))
        self.metadata = metadata
        self.manager = manager
    }
    func isEmpty() throws -> Bool {
        try base.isEmpty() && change.isEmpty()
    }
    func pop() throws -> (SequenceMark, SequenceMark) {
        let old = try base.peek()
        let new = try change.peek()
        guard old != nil || new != nil else {
            throw JSONDecodingError("0x722: cannot pop from empty queue")
        }
        guard let old else {
            let next = try change.dequeue()
            return (next.inputNoop, next)
        }
        guard let new else { return try dequeueBase() }
        if let oldId = old.cellId, let newId = new.cellId {
            switch try compareCellPositionsUsingTombstones(oldId, newId, oldKnowledge: baseKnowledge, newKnowledge: newKnowledge, metadata: metadata) {
            case .sameCell: return try dequeueBoth(old, new)
            case .oldThenNew: return try dequeueBase()
            case .newThenOld: return try dequeueNew()
            }
        }
        if new.cellId != nil { return try dequeueNew() }
        if old.cellId != nil { return try dequeueBase() }
        return try dequeueBoth(old, new)
    }
    private func dequeueBase() throws -> (SequenceMark, SequenceMark) {
        let old = try base.dequeue()
        var new = old.inputNoop
        if let effect = try movedEffect(old, manager: manager) {
            new = try addMovedMarkEffect(new, effect)
        }
        return (old, new)
    }
    private func dequeueNew() throws -> (SequenceMark, SequenceMark) {
        let new = try change.dequeue()
        return (new.inputNoop, new)
    }
    private func dequeueBoth(_ old: SequenceMark, _ new: SequenceMark) throws -> (SequenceMark, SequenceMark) {
        let length = min(old.count, new.count)
        let sizedOld = try base.dequeueUpTo(length)
        var sizedNew = try change.dequeueUpTo(length)
        if let effect = try movedEffect(sizedOld, manager: manager) {
            sizedNew = try addMovedMarkEffect(sizedNew, effect)
        }
        return (sizedOld, sizedNew)
    }
}

private func addMovedMarkEffect(_ mark: SequenceMark, _ effect: SequenceMarkEffect) throws -> SequenceMark {
    if case .moveOut(let id, let revision, let endpoint, _) = effect.kind {
        switch mark.effect.kind {
        case .moveIn(let id, let revision, let endpoint):
            var result = mark
            var converted = mark.effect
            converted.kind = .insert(id: id, revision: revision)
            converted.extraEndpoint = endpoint
            result.effect = converted
            return result
        case .rename(let override):
            var order = effect.propertyOrder + [.count]
            if !order.contains(.idOverride) { order.append(.idOverride) }
            return SequenceMark(count: mark.count, effect: .moveOut(id: id, revision: revision, finalEndpoint: endpoint, idOverride: override), propertyOrder: order)
        case .attachAndDetach(let attach, let detach):
            if case .moveIn = attach.kind { return SequenceMark(count: mark.count, effect: detach) }
        default: break
        }
    }
    if mark.effect == .noop && mark.cellId != nil {
        var result = mark
        result.effect = effect
        return result
    }
    throw JSONDecodingError("0x818: unexpected move source/destination combination")
}

private func rebaseMarkIgnoreChild<M: CrossFieldManager>(_ mark: SequenceMark, base: SequenceMark, manager: M) throws -> SequenceMark where M.Value == MoveEffect {
    var result = mark
    if base.effect.isDetach {
        if base.cellId != nil { result.cellId = nil }
        guard !result.effect.isNewAttach(cellId: result.cellId) else {
            throw JSONDecodingError("0x69d: new attach over emptied cell")
        }
        guard let cellId = base.effect.detachOutput else {
            throw JSONDecodingError("detach requires output cell ID")
        }
        if case .moveOut = base.effect.kind {
            let (remains, follows) = separateEffectsForMove(result.effect)
            let endpoint = try base.effect.endpoint()
            if let follows {
                try sendEffectToDest(follows, endpoint: endpoint, count: base.count, manager: manager)
            }
            if let changes = result.changes {
                var effect = try getMoveEffect(manager, target: .destination, revision: endpoint.revision, id: endpoint.localId, count: 1, addDependency: false).value ?? MoveEffect()
                effect.rebasedChanges = changes
                try setMoveEffect(manager, target: .destination, revision: endpoint.revision, id: endpoint.localId, count: 1, effect: effect)
            }
            result = SequenceMark(count: base.count, effect: remains ?? .noop)
        }
        guard result.cellId == nil else {
            throw JSONDecodingError("0x69f: expected attached mark")
        }
        result.cellId = cellId
    } else if base.fillsCells {
        if case .attachAndDetach(_, let detach) = result.effect.kind {
            result = SequenceMark(count: result.count, effect: detach, changes: result.changes)
        } else {
            result.cellId = nil
        }
    } else if case .attachAndDetach(let attach, let detach) = base.effect.kind {
        guard let cellId = base.cellId else {
            throw JSONDecodingError("0x81a: attach and detach should target empty cells")
        }
        result = try rebaseMarkIgnoreChild(result, base: SequenceMark(count: base.count, effect: attach, cellId: cellId), manager: manager)
        result = try rebaseMarkIgnoreChild(result, base: SequenceMark(count: base.count, effect: detach), manager: manager)
    } else if case .rename(let output) = base.effect.kind {
        result.cellId = output
    }
    return result
}

private func separateEffectsForMove(_ effect: SequenceMarkEffect) -> (SequenceMarkEffect?, SequenceMarkEffect?) {
    switch effect.kind {
    case .remove(let id, let revision, let override):
        return (override.map { .rename(idOverride: $0) }, .remove(id: id, revision: revision, idOverride: nil))
    case .moveOut(let id, let revision, let endpoint, let override):
        return (override.map { .rename(idOverride: $0) }, .moveOut(id: id, revision: revision, finalEndpoint: endpoint, idOverride: nil))
    case .attachAndDetach(let attach, let detach): return (attach, detach)
    case .moveIn, .rename: return (effect, nil)
    case .noop: return (nil, nil)
    case .insert(let id, let revision):
        return (.moveIn(id: id, revision: revision, finalEndpoint: nil), .moveOut(id: id, revision: revision, finalEndpoint: nil, idOverride: nil))
    }
}

private func sendEffectToDest<M: CrossFieldManager>(_ effect: SequenceMarkEffect, endpoint: ChangeAtomId, count: Int, manager: M) throws where M.Value == MoveEffect {
    let entry = try getMoveEffect(manager, target: .destination, revision: endpoint.revision, id: endpoint.localId, count: count, addDependency: false)
    var value = entry.value ?? MoveEffect()
    if entry.length < count {
        value.movedMark = effect
        try setMoveEffect(manager, target: .destination, revision: endpoint.revision, id: endpoint.localId, count: entry.length, effect: value)
        try sendEffectToDest(effect.offset(entry.length), endpoint: endpoint.offset(entry.length), count: count - entry.length, manager: manager)
    } else {
        value.movedEffect = effect
        try setMoveEffect(manager, target: .destination, revision: endpoint.revision, id: endpoint.localId, count: count, effect: value)
    }
}

private func movedData<M: CrossFieldManager>(_ base: SequenceMark, manager: M) throws -> MoveEffect? where M.Value == MoveEffect {
    guard case .moveIn(let id, let revision, _) = base.effect.moveIn?.kind else { return nil }
    return try getMoveEffect(manager, target: .destination, revision: revision, id: id, count: base.count).value
}

private func movedEffect<M: CrossFieldManager>(_ base: SequenceMark, manager: M) throws -> SequenceMarkEffect? where M.Value == MoveEffect {
    guard case .moveIn(let id, let revision, _) = base.effect.moveIn?.kind else { return nil }
    let entry = try getMoveEffect(manager, target: .destination, revision: revision, id: id, count: base.count)
    guard entry.length == base.count else {
        throw JSONDecodingError("0x6f3: effect should cover entire mark")
    }
    if case .moveOut(let id, let revision, _, _) = entry.value?.movedEffect?.kind {
        try manager.moveKey(.source, revision: revision, id: id, count: base.count)
    }
    return entry.value?.movedEffect
}
