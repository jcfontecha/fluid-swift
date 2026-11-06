import FluidJS

public typealias NodeChangeComposer = (ChangeAtomId?, ChangeAtomId?) throws -> ChangeAtomId

/// feature-libraries/sequence-field/compose.ts.
public func composeSequence<M: CrossFieldManager>(_ base: [SequenceMark], _ change: [SequenceMark], metadata: RevisionMetadataSource, manager: M, composeChild: NodeChangeComposer) throws -> [SequenceMark] where M.Value == MoveEffect {
    let factory = MarkListFactory()
    let queue = ComposeQueue(base: base, change: change, metadata: metadata, manager: manager)
    while try !queue.isEmpty() {
        let (baseMark, newMark) = try queue.pop()
        let old = baseMark.settled
        let new = newMark.settled
        var nodeChange: ChangeAtomId?
        if let changes = new.changes {
            manager.onMoveIn(changes)
            if let source = old.effect.moveIn {
                let endpoint = try source.endpoint()
                var effect = try getMoveEffect(manager, target: .source, revision: endpoint.revision, id: endpoint.localId, count: 1, addDependency: false).value ?? MoveEffect()
                effect.modifyAfter = changes
                try setMoveEffect(manager, target: .source, revision: endpoint.revision, id: endpoint.localId, count: 1, effect: effect)
            } else {
                nodeChange = try composeChild(old.changes, changes)
            }
        } else if old.changes != nil {
            nodeChange = try composeChild(old.changes, nil)
        }
        var result = try composeMarksIgnoreChild(old, new, manager: manager)
        result.changes = nodeChange
        result.effect = try withUpdatedEndpoint(result.effect, count: old.count, manager: manager)
        factory.push(result)
    }
    return factory.list
}

/// feature-libraries/sequence-field/compose.ts: ComposeQueue.
public final class ComposeQueue<M: CrossFieldManager> where M.Value == MoveEffect {
    private let base: MarkQueue<M>
    private let change: MarkQueue<M>
    private let baseKnowledge: Set<RevisionTag?>
    private let newKnowledge: Set<RevisionTag?>
    private let metadata: RevisionMetadataSource
    private let manager: M
    public init(base: [SequenceMark], change: [SequenceMark], metadata: RevisionMetadataSource, manager: M) {
        self.base = MarkQueue(base, manager: manager)
        self.change = MarkQueue(change, manager: manager)
        baseKnowledge = Set(base.compactMap(\.outputCellId).map(\.revision))
        newKnowledge = Set(change.compactMap(\.cellId).map(\.revision))
        self.metadata = metadata
        self.manager = manager
    }
    public func isEmpty() throws -> Bool {
        try base.isEmpty() && change.isEmpty()
    }
    public func pop() throws -> (SequenceMark, SequenceMark) {
        let old = try base.peek()
        let new = try change.peek()
        guard let old else { return try dequeueNew() }
        guard let new else { return try dequeueBase() }
        if old.outputIsEmpty, let newCell = new.cellId {
            guard let oldCell = old.outputCellId else {
                throw JSONDecodingError("0xb29: expected defined output ID")
            }
            if old.emptiesCells && oldCell.revision == nil {
                guard new.effect.isNewAttach(cellId: new.cellId) else {
                    throw JSONDecodingError("0x695: transaction reattach requires revision")
                }
                return try dequeueNew()
            }
            switch try compareCellPositionsUsingTombstones(oldCell, newCell, oldKnowledge: baseKnowledge, newKnowledge: newKnowledge, metadata: metadata) {
            case .sameCell: return try dequeueBoth(old, new)
            case .oldThenNew: return try dequeueBase()
            case .newThenOld: return try dequeueNew()
            }
        }
        if old.outputIsEmpty { return try dequeueBase() }
        if new.cellId != nil { return try dequeueNew() }
        return try dequeueBoth(old, new)
    }
    private func dequeueBase() throws -> (SequenceMark, SequenceMark) {
        let old = try base.dequeue()
        return (old, SequenceMark(count: old.count, cellId: old.outputCellId, changes: try movedChanges(old.effect)))
    }
    private func dequeueNew() throws -> (SequenceMark, SequenceMark) {
        let new = try change.dequeue()
        return (new.inputNoop, new)
    }
    private func dequeueBoth(_ old: SequenceMark, _ new: SequenceMark) throws -> (SequenceMark, SequenceMark) {
        let length = min(old.count, new.count)
        let sizedOld = try base.dequeueUpTo(length)
        var sizedNew = try change.dequeueUpTo(length)
        if let changes = try movedChanges(sizedOld.effect) {
            guard sizedNew.changes == nil else {
                throw JSONDecodingError("0x8da: node changeset collision")
            }
            sizedNew.changes = changes
        }
        return (sizedOld, sizedNew)
    }
    private func movedChanges(_ effect: SequenceMarkEffect) throws -> ChangeAtomId? {
        if case .attachAndDetach(_, let detach) = effect.kind { return try movedChanges(detach) }
        guard case .moveOut(let id, let revision, _, _) = effect.kind else { return nil }
        return try getMoveEffect(manager, target: .source, revision: revision, id: id, count: 1).value?.modifyAfter
    }
}

private func composeMarksIgnoreChild<M: CrossFieldManager>(_ old: SequenceMark, _ new: SequenceMark, manager: M) throws -> SequenceMark where M.Value == MoveEffect {
    if old.effect == .noop { return new }
    if new.effect == .noop { return old }
    if case .rename = old.effect.kind {
        if case .rename(let output) = new.effect.kind {
            var result = old
            result.effect = .rename(idOverride: output)
            return result
        }
        guard new.effect.isAttach || new.isImpactfulCellRename else {
            throw JSONDecodingError("0x9f1: unexpected mark type")
        }
        var result = new
        result.cellId = old.cellId
        return result
    }
    if case .rename(let output) = new.effect.kind {
        var result = old
        result.effect = try old.effect.withIdOverride(output)
        return result
    }
    if new.isImpactfulCellRename {
        let (newAttach, newDetach) = try new.attachAndDetach()
        guard let newCell = new.cellId else {
            throw JSONDecodingError("0x9f3: impactful cell rename requires empty cell")
        }
        if old.emptiesCells {
            var result = SequenceMark(count: old.count, effect: newDetach)
            if case .moveIn = newAttach.kind, case .moveOut = newDetach.kind {
                guard case .moveOut = old.effect.kind else {
                    throw JSONDecodingError("0x808: unexpected mark type")
                }
                let newDetachId = try newDetach.atomId().fromTuple()
                try setEndpointProperty(manager, target: .destination, id: old.effect.endpoint(), count: old.count, endpoint: newDetachId, property: \.truncatedEndpointForInner)
                if let endpoint = try composedEndpoint(manager, target: .source, id: old.effect.atomId(), count: old.count) {
                    result.effect = try changeFinalEndpoint(result.effect, endpoint: endpoint)
                    try setEndpointProperty(manager, target: .destination, id: endpoint, count: old.count, endpoint: newDetachId, property: \.truncatedEndpoint)
                }
            }
            return result
        }
        if old.isImpactfulCellRename {
            guard let oldCell = old.cellId else {
                throw JSONDecodingError("0x9f4: impactful cell rename requires empty cell")
            }
            var (attach, _) = try old.attachAndDetach()
            var detach = newDetach
            try handleMovePivot(count: old.count, attach: &attach, detach: &detach, manager: manager)
            if new.outputCellId == oldCell { return SequenceMark(count: old.count, cellId: oldCell) }
            return normalizeCellRename(cellId: oldCell, count: old.count, attach: attach, detach: detach)
        }
        return normalizeCellRename(cellId: newCell, count: new.count, attach: newAttach, detach: newDetach)
    }
    if old.isImpactfulCellRename {
        let (attach, detach) = try old.attachAndDetach()
        if new.fillsCells {
            var result = SequenceMark(count: old.count, effect: attach, cellId: old.cellId)
            if case .moveIn = attach.kind, case .moveOut = detach.kind {
                guard case .moveIn = new.effect.kind else {
                    throw JSONDecodingError("0x809: unexpected mark type")
                }
                let originalAttachId = try attach.atomId().fromTuple()
                try setEndpointProperty(manager, target: .source, id: new.effect.endpoint(), count: old.count, endpoint: originalAttachId, property: \.truncatedEndpointForInner)
                if let endpoint = try composedEndpoint(manager, target: .destination, id: new.effect.atomId(), count: new.count) {
                    result.effect = try changeFinalEndpoint(result.effect, endpoint: endpoint)
                    try setEndpointProperty(manager, target: .source, id: endpoint, count: old.count, endpoint: originalAttachId, property: \.truncatedEndpoint)
                }
            }
            return result
        }
        throw JSONDecodingError("0x80a: unexpected mark type")
    }
    if !old.hasCellEffect && !new.hasCellEffect {
        return SequenceMark(count: new.count, cellId: old.cellId)
    }
    if !old.hasCellEffect { return new }
    if !new.hasCellEffect { return old }
    if let oldCell = old.cellId {
        guard new.effect.isDetach && old.effect.isAttach else {
            throw JSONDecodingError("0x71c: expected attach followed by detach")
        }
        var attach = old.effect
        var detach = new.effect
        try handleMovePivot(count: old.count, attach: &attach, detach: &detach, manager: manager)
        if new.outputCellId == oldCell { return SequenceMark(count: old.count, cellId: oldCell) }
        return normalizeCellRename(cellId: oldCell, count: old.count, attach: attach, detach: detach)
    }
    return SequenceMark(count: old.count)
}

private func handleMovePivot<M: CrossFieldManager>(count: Int, attach: inout SequenceMarkEffect, detach: inout SequenceMarkEffect, manager: M) throws where M.Value == MoveEffect {
    guard case .moveIn = attach.kind, case .moveOut = detach.kind else { return }
    let source = try attach.endpoint()
    let destination = try detach.endpoint()
    try setEndpointProperty(manager, target: .source, id: source, count: count, endpoint: destination, property: \.endpoint)
    let attachId = try attach.atomId()
    let first = try getMoveEffect(manager, target: .destination, revision: attachId.revision, id: attachId.localId, count: count)
    guard first.length == count else { throw JSONDecodingError("0x934: effect should cover entire mark") }
    if let endpoint = first.value?.truncatedEndpointForInner {
        try setEndpointProperty(manager, target: .destination, id: destination, count: count, endpoint: endpoint, property: \.truncatedEndpoint)
    }
    try setEndpointProperty(manager, target: .destination, id: destination, count: count, endpoint: source, property: \.endpoint)
    let detachId = try detach.atomId()
    let second = try getMoveEffect(manager, target: .source, revision: detachId.revision, id: detachId.localId, count: count)
    guard second.length == count else { throw JSONDecodingError("0x934: effect should cover entire mark") }
    if let endpoint = second.value?.truncatedEndpointForInner {
        try setEndpointProperty(manager, target: .source, id: source, count: count, endpoint: endpoint, property: \.truncatedEndpoint)
    }
    attach = try attach.withFinalEndpoint(nil)
    detach = try detach.withFinalEndpoint(nil)
}

private func setEndpointProperty<M: CrossFieldManager>(_ manager: M, target: CrossFieldTarget, id: ChangeAtomId, count: Int, endpoint: ChangeAtomId, property: WritableKeyPath<MoveEffect, ChangeAtomId?>) throws where M.Value == MoveEffect {
    let entry = try getMoveEffect(manager, target: target, revision: id.revision, id: id.localId, count: count, addDependency: property != \.endpoint)
    var value = entry.value ?? MoveEffect()
    value[keyPath: property] = endpoint
    try setMoveEffect(manager, target: target, revision: id.revision, id: id.localId, count: entry.length, effect: value)
    if entry.length < count {
        try setEndpointProperty(manager, target: target, id: id.offset(entry.length), count: count - entry.length, endpoint: endpoint.offset(entry.length), property: property)
    }
}

private func withUpdatedEndpoint<M: CrossFieldManager>(_ effect: SequenceMarkEffect, count: Int, manager: M) throws -> SequenceMarkEffect where M.Value == MoveEffect {
    if case .attachAndDetach(let attach, let detach) = effect.kind {
        return try .attachAndDetach(attach: withUpdatedEndpoint(attach, count: count, manager: manager), detach: withUpdatedEndpoint(detach, count: count, manager: manager))
    }
    guard let target = effect.crossFieldTarget else { return effect }
    guard let endpoint = try composedEndpoint(manager, target: target, id: effect.atomId(), count: count) else { return effect }
    return try changeFinalEndpoint(effect, endpoint: endpoint)
}

private func changeFinalEndpoint(_ effect: SequenceMarkEffect, endpoint: ChangeAtomId) throws -> SequenceMarkEffect {
    try effect.withFinalEndpoint(endpoint == effect.atomId() ? nil : endpoint)
}

private func composedEndpoint<M: CrossFieldManager>(_ manager: M, target: CrossFieldTarget, id: ChangeAtomId, count: Int) throws -> ChangeAtomId? where M.Value == MoveEffect {
    let entry = try getMoveEffect(manager, target: target, revision: id.revision, id: id.localId, count: count)
    guard entry.length == count else { throw JSONDecodingError("0x815: effect should cover entire mark") }
    return entry.value?.truncatedEndpoint ?? entry.value?.endpoint
}
