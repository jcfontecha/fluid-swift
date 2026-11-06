import FluidJS

/// feature-libraries/sequence-field/invert.ts.
public func invertSequence<M: CrossFieldManager>(_ marks: [SequenceMark], isRollback: Bool, allocator: DefaultAtomIdAliasAllocator, revision: RevisionTag?, manager: M) throws -> [SequenceMark] where M.Value == ChangeAtomId {
    let factory = MarkListFactory()
    for mark in marks {
        for inverse in try invertMark(mark, isRollback: isRollback, allocator: allocator, revision: revision, manager: manager) {
            factory.push(inverse)
        }
    }
    return factory.list
}

private func invertMark<M: CrossFieldManager>(_ mark: SequenceMark, isRollback: Bool, allocator: DefaultAtomIdAliasAllocator, revision: RevisionTag?, manager: M) throws -> [SequenceMark] where M.Value == ChangeAtomId {
    if !mark.isImpactful {
        guard mark.changes == nil || mark.count == 1 else {
            throw JSONDecodingError("0x66c: modify mark must have length one")
        }
        return [SequenceMark(count: mark.count, cellId: mark.cellId, changes: mark.changes, propertyOrder: [.count] + (mark.changes == nil ? [] : [.changes]) + (mark.cellId == nil ? [] : [.cellId]))]
    }
    func alias(_ id: Double, _ originalRevision: RevisionTag?) throws -> Double {
        try allocator.getAlias(originalRevision, localId: id)
    }
    func endpoint(_ id: ChangeAtomId?) throws -> ChangeAtomId? {
        try id.map { ChangeAtomId(localId: try alias($0.localId, $0.revision), revision: revision) }
    }
    switch mark.effect.kind {
    case .noop:
        return [mark]
    case .rename(let output):
        guard let input = mark.cellId else {
            throw JSONDecodingError("0x9f5: rename must have cell ID")
        }
        return [SequenceMark(count: mark.count, effect: isRollback ? .rename(idOverride: input) : .noop, cellId: output, changes: mark.changes, propertyOrder: (isRollback ? [.type, .count, .cellId, .idOverride] : [.count, .cellId]) + (mark.changes == nil ? [] : [.changes]))]
    case .remove(let id, let originalRevision, _):
        guard originalRevision != nil else {
            throw JSONDecodingError("0x5a1: unable to revert undefined revision")
        }
        let newId = try alias(id, originalRevision)
        let effect: SequenceMarkEffect = mark.cellId == nil
            ? .insert(id: newId, revision: revision)
            : .remove(id: newId, revision: revision, idOverride: isRollback ? mark.cellId : nil)
        return [SequenceMark(count: mark.count, effect: effect, cellId: mark.effect.detachOutput, changes: mark.changes, propertyOrder: [.type, .id, .cellId, .count, .revision] + (isRollback && mark.cellId != nil ? [.idOverride] : []) + (mark.changes == nil ? [] : [.changes]))]
    case .insert(let id, let originalRevision):
        guard let input = mark.cellId else {
            throw JSONDecodingError("0x80c: active insert must target empty cells")
        }
        return [SequenceMark(count: mark.count, effect: .remove(id: try alias(id, originalRevision), revision: revision, idOverride: isRollback ? input : nil), changes: mark.changes, propertyOrder: [.type, .count, .id, .revision] + (isRollback ? [.idOverride] : []) + (mark.changes == nil ? [] : [.changes]))]
    case .moveOut(let id, let originalRevision, let final, _):
        if let changes = mark.changes {
            guard mark.count == 1 else {
                throw JSONDecodingError("0x6ed: mark with changes must target one cell")
            }
            let target = final ?? ChangeAtomId(localId: id, revision: originalRevision)
            try manager.set(.destination, revision: target.revision, id: target.localId, count: mark.count, value: changes, invalidateDependents: true)
        }
        let newId = try alias(id, originalRevision)
        var effect = SequenceMarkEffect.moveIn(id: newId, revision: revision, finalEndpoint: try endpoint(final))
        if let input = mark.cellId {
            effect = .attachAndDetach(attach: effect, detach: .remove(id: newId, revision: revision, idOverride: isRollback ? input : nil))
        }
        return [SequenceMark(count: mark.count, effect: effect, cellId: mark.effect.detachOutput)]
    case .moveIn(let id, let originalRevision, let final):
        guard let input = mark.cellId else {
            throw JSONDecodingError("0x89e: move-in must target empty cells")
        }
        let inverse = SequenceMark(count: mark.count, effect: .moveOut(id: try alias(id, originalRevision), revision: revision, finalEndpoint: try endpoint(final), idOverride: isRollback ? input : nil), propertyOrder: [.type, .id, .count, .revision] + (isRollback ? [.idOverride] : []) + (final == nil ? [] : [.finalEndpoint]))
        return try applyMovedChanges(inverse, originalRevision: originalRevision, originalId: id, manager: manager)
    case .attachAndDetach(let attach, let detach):
        let attachMark = SequenceMark(count: mark.count, effect: attach, cellId: mark.cellId, propertyOrder: [.count, .cellId] + attach.propertyOrder)
        let detachMark = SequenceMark(count: mark.count, effect: detach, changes: mark.changes, propertyOrder: [.count, .cellId, .changes] + detach.propertyOrder)
        let attachInverses = try invertMark(attachMark, isRollback: isRollback, allocator: allocator, revision: revision, manager: manager)
        let detachInverses = try invertMark(detachMark, isRollback: isRollback, allocator: allocator, revision: revision, manager: manager)
        guard !detachInverses.isEmpty else {
            return attachInverses
        }
        guard detachInverses.count == 1, var remaining = detachInverses.first else {
            throw JSONDecodingError("0x80d: only move-ins should split during inversion")
        }
        var inverses: [SequenceMark] = []
        for attachInverse in attachInverses {
            var current = remaining
            if attachInverse.count != remaining.count {
                (current, remaining) = try remaining.split(attachInverse.count)
            }
            if attachInverse.effect == .noop {
                if let changes = attachInverse.changes {
                    guard current.changes == nil else {
                        throw JSONDecodingError("0x80f: unexpected node changes")
                    }
                    current.changes = changes
                }
                inverses.append(current)
                continue
            }
            guard let cell = current.cellId else {
                throw JSONDecodingError("0x9f6: expected empty cell")
            }
            var inverse = normalizeCellRename(cellId: cell, count: attachInverse.count, attach: current.effect, detach: attachInverse.effect)
            inverse.changes = remaining.changes
            if let changes = attachInverse.changes {
                guard inverse.changes == nil else {
                    throw JSONDecodingError("0x811: unexpected node changes")
                }
                inverse.changes = changes
            }
            inverses.append(inverse)
        }
        return inverses
    }
}

private func applyMovedChanges<M: CrossFieldManager>(_ mark: SequenceMark, originalRevision: RevisionTag?, originalId: Double, manager: M) throws -> [SequenceMark] where M.Value == ChangeAtomId {
    let entry = manager.get(.destination, revision: originalRevision, id: originalId, count: mark.count, addDependency: true)
    guard entry.length > 0 && entry.length <= mark.count else {
        throw JSONDecodingError("invalid cross-field query length")
    }
    if entry.length < mark.count {
        var (first, second) = try mark.split(entry.length)
        first.changes = entry.value
        return [first] + (try applyMovedChanges(second, originalRevision: originalRevision, originalId: originalId + Double(first.count), manager: manager))
    }
    var result = mark
    if let changes = entry.value {
        manager.onMoveIn(changes)
        result.changes = changes
    }
    return [result]
}
