import FluidJS

extension SequenceMarkEffect {
    func detachedNodeId() throws -> ChangeAtomId {
        if case .moveOut(let id, let revision, _, _) = self.kind { return ChangeAtomId(localId: id, revision: revision) }
        guard let id = detachOutput else { throw JSONDecodingError("expected detached node ID") }
        return id
    }
}

/// feature-libraries/sequence-field/sequenceFieldChangeHandler.ts and utils.ts.
public struct SequenceFieldChangeHandler {
    public init() {}
    public func createEmpty() -> [SequenceMark] { [] }
    public func isEmpty(_ change: [SequenceMark]) -> Bool {
        change.allSatisfy { $0.changes == nil && $0.effect == .noop }
    }
    public func getNestedChanges(_ change: [SequenceMark]) throws -> [ChildChangeInfo] {
        try change.compactMap { mark in
            guard let child = mark.changes else { return nil }
            return ChildChangeInfo(nodeId: child, inputRootId: mark.cellId, detachId: mark.effect.isDetach ? try mark.effect.detachedNodeId() : nil)
        }
    }
    public func getCrossFieldKeys(_ change: [SequenceMark]) -> [CrossFieldKeyRange] {
        change.flatMap { crossFieldKeys($0.effect, count: $0.count) }
    }
    private func crossFieldKeys(_ effect: SequenceMarkEffect, count: Int) -> [CrossFieldKeyRange] {
        switch effect.kind {
        case .insert(let id, let revision):
            return [.init(key: .init(target: .source, revision: revision, localId: id), count: count), .init(key: .init(target: .destination, revision: revision, localId: id), count: count)]
        case .moveIn(let id, let revision, _):
            return [.init(key: .init(target: .destination, revision: revision, localId: id), count: count)]
        case .moveOut(let id, let revision, _, _):
            return [.init(key: .init(target: .source, revision: revision, localId: id), count: count)]
        case .attachAndDetach(let attach, let detach):
            return crossFieldKeys(attach, count: count) + crossFieldKeys(detach, count: count)
        default: return []
        }
    }
    public func relevantRemovedRoots(_ change: [SequenceMark], fromChild: (ChangeAtomId) throws -> [DeltaDetachedNodeId]) rethrows -> [DeltaDetachedNodeId] {
        var roots: [DeltaDetachedNodeId] = []
        for mark in change {
            let effect: SequenceMarkEffect
            if case .attachAndDetach(let attach, _) = mark.effect.kind { effect = attach } else { effect = mark.effect }
            var insert = false
            if case .insert = effect.kind { insert = true }
            if let cell = mark.cellId, insert || mark.effect.isDetach || mark.changes != nil {
                for offset in 0..<mark.count { roots.append(DeltaDetachedNodeId(cell.offset(offset))) }
            }
            if let child = mark.changes { roots.append(contentsOf: try fromChild(child)) }
        }
        return roots
    }
    /// sequenceFieldToDelta.ts: Rename changes empty-cell identity, not detached-node identity.
    public func intoDelta(_ change: [SequenceMark], fromChild: (ChangeAtomId) throws -> DeltaFieldMap) throws -> FieldChangeDelta {
        var local: [DeltaMark] = []
        var global: [DeltaDetachedNodeChanges] = []
        var rename: [DeltaDetachedNodeRename] = []
        for mark in change {
            var delta = DeltaMark(count: mark.count)
            if let child = mark.changes {
                let fields = try fromChild(child)
                if !fields.isEmpty {
                    if let cell = mark.cellId {
                        global.append(.init(id: DeltaDetachedNodeId(cell), fields: fields))
                    } else {
                        delta.fields = fields
                    }
                }
            }
            if mark.cellId == nil && !mark.outputIsEmpty {
                local.append(delta)
                continue
            }
            switch mark.effect.kind {
            case .attachAndDetach(let attach, let detach):
                guard let cell = mark.cellId else { throw JSONDecodingError("0x81e: attach/detach requires input cell") }
                if case .moveIn = attach.kind, case .moveOut = detach.kind {
                    guard mark.changes == nil else { throw JSONDecodingError("0x81f: paired moves cannot have changes") }
                    continue
                }
                let output = try detach.detachedNodeId()
                let oldId = DeltaDetachedNodeId(try attach.isMove ? attach.endpoint() : cell)
                if cell != output { rename.append(.init(count: mark.count, oldId: oldId, newId: DeltaDetachedNodeId(output))) }
                if let fields = delta.fields { global.append(.init(id: oldId, fields: fields)) }
            case .moveIn:
                local.append(DeltaMark(count: mark.count, attach: DeltaDetachedNodeId(try mark.effect.endpoint())))
            case .remove:
                let output = try mark.effect.detachedNodeId()
                if let cell = mark.cellId {
                    if cell != output { rename.append(.init(count: mark.count, oldId: DeltaDetachedNodeId(cell), newId: DeltaDetachedNodeId(output))) }
                    if let fields = delta.fields { global.append(.init(id: DeltaDetachedNodeId(cell), fields: fields)) }
                } else {
                    delta.detach = DeltaDetachedNodeId(output)
                    local.append(delta)
                }
            case .moveOut:
                let output = DeltaDetachedNodeId(try mark.effect.detachedNodeId())
                if let cell = mark.cellId {
                    rename.append(.init(count: mark.count, oldId: DeltaDetachedNodeId(cell), newId: output))
                } else {
                    delta.detach = output
                    local.append(delta)
                }
            case .insert:
                guard let cell = mark.cellId else { throw JSONDecodingError("0x821: active insert requires cell ID") }
                let buildId = DeltaDetachedNodeId(cell)
                delta.attach = buildId
                if let fields = delta.fields {
                    global.append(.init(id: buildId, fields: fields))
                    delta.fields = nil
                }
                local.append(delta)
            case .noop:
                if mark.cellId == nil { local.append(delta) }
            case .rename:
                guard mark.cellId != nil else { throw JSONDecodingError("0x9f9: rename requires empty cells") }
            }
        }
        while let last = local.last, last.attach == nil && last.detach == nil && last.fields == nil { local.removeLast() }
        var delta = FieldChangeDelta()
        if !local.isEmpty { delta.local = DeltaFieldChanges(marks: local) }
        if !global.isEmpty { delta.global = global }
        if !rename.isEmpty { delta.rename = rename }
        return delta
    }
}

/// feature-libraries/sequence-field/prune.ts.
public func pruneSequence(_ change: [SequenceMark], pruneChild: (ChangeAtomId) throws -> ChangeAtomId?) rethrows -> [SequenceMark] {
    let factory = MarkListFactory()
    for var mark in change {
        if let child = mark.changes { mark.changes = try pruneChild(child) }
        factory.push(mark)
    }
    return factory.list
}
