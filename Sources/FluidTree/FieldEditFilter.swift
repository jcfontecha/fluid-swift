import FluidJS

/// util/rangeMap.ts and feature-libraries/modular-schema/fieldChangeHandler.ts.
public struct RangeQueryResult<Value> {
    public var length: Int
    public var value: Value
    public init(length: Int, value: Value) {
        self.length = length
        self.value = value
    }
}
public enum EditFilterStatus {
    case remove
    case preserve
    case preserveWithoutMove
}
public struct FilterDetachResult {
    public var action: EditFilterStatus
    public var shouldRemoveChild: Bool?
    public init(action: EditFilterStatus, shouldRemoveChild: Bool? = nil) {
        self.action = action
        self.shouldRemoveChild = shouldRemoveChild
    }
}
public struct FilterAttachResult {
    public var action: EditFilterStatus
    public var nodeId: ChangeAtomId?
    public var newAttachId: ChangeAtomId?
    public init(action: EditFilterStatus, nodeId: ChangeAtomId? = nil, newAttachId: ChangeAtomId? = nil) {
        self.action = action
        self.nodeId = nodeId
        self.newAttachId = newAttachId
    }
}
public typealias FilterDetachFunc = (ChangeAtomId, Int, ChangeAtomId?, ChangeAtomId?) throws -> RangeQueryResult<FilterDetachResult>
public typealias FilterAttachFunc = (ChangeAtomId, Int, ChangeAtomId?, ChangeAtomId?) throws -> RangeQueryResult<FilterAttachResult>

/// feature-libraries/optional-field/optionalField.ts: filterEdits.
public func filterOptional(_ change: OptionalChangeset, preserveOtherEdits: Bool, filterDetach: FilterDetachFunc, filterAttach: FilterAttachFunc) throws -> OptionalChangeset {
    var result = change
    if let replace = change.valueReplace {
        if replace.isEffectful {
            let detachResult = try replace.effectfulDst.map { try filterDetach($0, 1, nil, nil).value }
            let attachResult: EditFilterStatus?
            if case .detached(let source) = replace.src { attachResult = try filterAttach(source, 1, nil, nil).value.action } else { attachResult = nil }
            if detachResult?.action == .remove {
                guard replace.src == nil || attachResult == .remove else {
                    throw JSONDecodingError("0xd0e: cannot remove detach without attach")
                }
                result.valueReplace = nil
                if detachResult?.shouldRemoveChild == true { result.childChanges.removeAll { $0.register == .active } }
            } else if attachResult == .remove {
                result.valueReplace?.src = nil
            }
        } else if !preserveOtherEdits {
            result.valueReplace = nil
        }
    }
    if !preserveOtherEdits { result.moves = [] }
    return result
}

/// feature-libraries/sequence-field/filterEdits.ts.
public func filterSequence(_ change: [SequenceMark], preserveOtherEdits: Bool, filterDetach: FilterDetachFunc, filterAttach: FilterAttachFunc) throws -> [SequenceMark] {
    let factory = MarkListFactory()
    let queue = MarkQueueBase(change)
    while let mark = try queue.peek() {
        let filtered = try filterSequenceMark(mark, preserveOtherEdits: preserveOtherEdits, filterDetach: filterDetach, filterAttach: filterAttach)
        guard filtered.count > 0 && filtered.count <= mark.count else { throw JSONDecodingError("invalid filtered mark length") }
        factory.push(filtered)
        _ = try queue.dequeueUpTo(filtered.count)
    }
    return factory.list
}

private func filterSequenceMark(_ mark: SequenceMark, preserveOtherEdits: Bool, filterDetach: FilterDetachFunc, filterAttach: FilterAttachFunc) throws -> SequenceMark {
    var noop = mark
    noop.effect = .noop
    switch mark.effect.kind {
    case .insert, .moveIn:
        guard let cell = mark.cellId else { return preserveOtherEdits ? mark : noop }
        let atom = try mark.effect.atomId()
        let endpoint: ChangeAtomId?
        if case .moveIn(_, _, let final) = mark.effect.kind { endpoint = final } else { endpoint = nil }
        let response = try filterAttach(mark.effect.isMove ? atom : cell, mark.count, nil, endpoint)
        var result: SequenceMark
        switch response.value.action {
        case .preserve: result = mark
        case .remove: result = noop
        case .preserveWithoutMove:
            result = SequenceMark(count: response.length, effect: .insert(id: atom.localId, revision: atom.revision), cellId: response.value.newAttachId ?? endpoint ?? atom, changes: response.value.nodeId)
        }
        result.count = response.length
        return result
    case .remove, .moveOut:
        let endpoint: ChangeAtomId?
        if case .moveOut(_, _, let final, _) = mark.effect.kind { endpoint = final } else { endpoint = nil }
        let response = try filterDetach(mark.effect.detachedNodeId(), mark.count, mark.cellId, endpoint)
        var result: SequenceMark
        switch response.value.action {
        case .preserve: result = mark
        case .remove:
            result = noop
            if response.value.shouldRemoveChild == true { result.changes = nil }
        case .preserveWithoutMove:
            guard let output = mark.effect.detachOutput else { throw JSONDecodingError("missing detach output") }
            result = SequenceMark(count: mark.count, effect: .remove(id: output.localId, revision: output.revision, idOverride: nil), changes: mark.changes)
        }
        result.count = response.length
        return result
    case .attachAndDetach(let attach, _):
        guard case .moveIn(let id, let revision, let endpoint) = attach.kind else { throw JSONDecodingError("0xd3c: expected MoveIn + Remove") }
        guard mark.cellId != nil else { return preserveOtherEdits ? mark : noop }
        let response = try filterAttach(ChangeAtomId(localId: id, revision: revision), mark.count, mark.outputCellId, endpoint)
        var result = response.value.action == .preserve ? mark : noop
        result.count = response.length
        return result
    case .noop, .rename:
        return preserveOtherEdits ? mark : noop
    }
}
