import FluidJS

extension ChangeAtomId {
    func offset(_ count: Int) -> ChangeAtomId {
        var result = self
        result.localId += Double(count)
        return result
    }
}

/// feature-libraries/sequence-field/utils.ts: splitting and merging preserve every identity range.
extension SequenceMarkEffect {
    func offset(_ count: Int) -> SequenceMarkEffect {
        let amount = Double(count)
        switch kind {
        case .noop: return self
        case .rename(let id): return preservingProperties(.rename(idOverride: id.offset(count)))
        case .insert(let id, let revision): return preservingProperties(.insert(id: id + amount, revision: revision))
        case .remove(let id, let revision, let override): return preservingProperties(.remove(id: id + amount, revision: revision, idOverride: override?.offset(count)))
        case .moveIn(let id, let revision, let endpoint): return preservingProperties(.moveIn(id: id + amount, revision: revision, finalEndpoint: endpoint?.offset(count)))
        case .moveOut(let id, let revision, let endpoint, let override): return preservingProperties(.moveOut(id: id + amount, revision: revision, finalEndpoint: endpoint?.offset(count), idOverride: override?.offset(count)))
        case .attachAndDetach(let attach, let detach): return preservingProperties(.attachAndDetach(attach: attach.offset(count), detach: detach.offset(count)))
        }
    }

    var detachOutput: ChangeAtomId? {
        switch kind {
        case .remove(let id, let revision, let override), .moveOut(let id, let revision, _, let override):
            return override ?? ChangeAtomId(localId: id, revision: revision, propertyOrder: .revisionFirst)
        case .rename(let override): return override
        case .attachAndDetach(_, let detach): return detach.detachOutput
        default: return nil
        }
    }
}

extension SequenceMark {
    func split(_ length: Int) throws -> (SequenceMark, SequenceMark) {
        guard length > 0 && length < count else {
            throw JSONDecodingError("0xb2d: unable to split mark due to lengths")
        }
        var first = self
        var second = self
        first.count = length
        second.count -= length
        second.effect = effect.offset(length)
        second.cellId = cellId?.offset(length)
        return (first, second)
    }

    var isImpactful: Bool {
        switch effect.kind {
        case .noop: return false
        case .insert: return cellId != nil
        case .remove: return cellId == nil || cellId != effect.detachOutput
        default: return true
        }
    }
}

/// feature-libraries/sequence-field/markListFactory.ts.
public final class MarkListFactory {
    private var offset = 0
    public private(set) var list: [SequenceMark] = []
    public init() {}

    public func pushOffset(_ count: Int) {
        offset += count
    }

    public func push(_ mark: SequenceMark) {
        if mark.effect == .noop && mark.changes == nil && mark.cellId == nil {
            pushOffset(mark.count)
            return
        }
        if offset > 0 {
            list.append(SequenceMark(count: offset))
            offset = 0
        }
        if let last = list.last, last.changes == nil, mark.changes == nil,
           last.cellId?.offset(last.count) == mark.cellId,
           last.effect.offset(last.count) == mark.effect {
            list[list.count - 1].count += mark.count
        } else {
            list.append(mark)
        }
    }
}

func normalizeCellRename(cellId: ChangeAtomId, count: Int, attach: SequenceMarkEffect, detach: SequenceMarkEffect) -> SequenceMark {
    switch (attach.kind, detach.kind) {
    case (.moveIn, .moveOut):
        if let output = detach.detachOutput {
            return SequenceMark(count: count, effect: .rename(idOverride: output), cellId: cellId, propertyOrder: [.type, .count, .cellId, .idOverride])
        }
    case (.insert, _):
        return SequenceMark(count: count, effect: detach, cellId: cellId)
    default:
        break
    }
    return SequenceMark(count: count, effect: .attachAndDetach(attach: attach, detach: detach), cellId: cellId)
}

extension SequenceMarkEffect {
    var isAttach: Bool {
        switch kind {
        case .insert, .moveIn: return true
        default: return false
        }
    }
    var isDetach: Bool {
        switch kind {
        case .remove, .moveOut: return true
        default: return false
        }
    }
    var isMove: Bool {
        switch kind {
        case .moveIn, .moveOut: return true
        default: return false
        }
    }
    var revision: RevisionTag? {
        switch kind {
        case .insert(_, let tag), .remove(_, let tag, _), .moveIn(_, let tag, _), .moveOut(_, let tag, _, _): return tag
        default: return nil
        }
    }
    var moveIn: SequenceMarkEffect? {
        switch kind {
        case .moveIn: return self
        case .attachAndDetach(let attach, _): return attach.moveIn
        default: return nil
        }
    }
    func endpoint() throws -> ChangeAtomId {
        switch kind {
        case .moveIn(let id, let tag, let final), .moveOut(let id, let tag, let final, _):
            return final ?? ChangeAtomId(localId: id, revision: tag, propertyOrder: .revisionFirst, includesRevision: true)
        default: throw JSONDecodingError("expected move effect")
        }
    }
    func isNewAttach(cellId: ChangeAtomId?) -> Bool {
        if case .attachAndDetach(let attach, _) = self.kind {
            return attach.isNewAttach(cellId: cellId)
        }
        return isAttach && cellId != nil && revision == cellId?.revision
    }
}

extension SequenceMark {
    var outputIsEmpty: Bool {
        switch effect.kind {
        case .noop: return cellId != nil
        case .insert, .moveIn: return false
        default: return true
        }
    }
    var emptiesCells: Bool { cellId == nil && outputIsEmpty }
    var fillsCells: Bool { cellId != nil && !outputIsEmpty }
    var outputCellId: ChangeAtomId? {
        if let detach = effect.detachOutput { return detach }
        return fillsCells ? nil : cellId
    }
    var inputNoop: SequenceMark { SequenceMark(count: count, cellId: cellId) }
}

extension SequenceMarkEffect {
    func atomId() throws -> ChangeAtomId {
        switch kind {
        case .insert(let id, let revision), .remove(let id, let revision, _), .moveIn(let id, let revision, _), .moveOut(let id, let revision, _, _):
            return ChangeAtomId(localId: id, revision: revision)
        default: throw JSONDecodingError("effect has no atom ID")
        }
    }
    func withFinalEndpoint(_ endpoint: ChangeAtomId?) throws -> SequenceMarkEffect {
        var result = self
        switch kind {
        case .moveIn(let id, let revision, _): result.kind = .moveIn(id: id, revision: revision, finalEndpoint: endpoint)
        case .moveOut(let id, let revision, _, let override): result.kind = .moveOut(id: id, revision: revision, finalEndpoint: endpoint, idOverride: override)
        default: throw JSONDecodingError("expected move endpoint")
        }
        if endpoint == nil { result.propertyOrder.removeAll { $0 == .finalEndpoint } }
        else if !result.propertyOrder.contains(.finalEndpoint) { result.propertyOrder.append(.finalEndpoint) }
        return result
    }
    func withIdOverride(_ override: ChangeAtomId) throws -> SequenceMarkEffect {
        var result = self
        switch kind {
        case .remove(let id, let revision, _): result.kind = .remove(id: id, revision: revision, idOverride: override)
        case .moveOut(let id, let revision, let endpoint, _): result.kind = .moveOut(id: id, revision: revision, finalEndpoint: endpoint, idOverride: override)
        case .attachAndDetach(let attach, let detach):
            result.kind = .attachAndDetach(attach: attach, detach: try detach.withIdOverride(override))
            return result
        default: throw JSONDecodingError("0x9f2: unexpected mark type")
        }
        if !result.propertyOrder.contains(.idOverride) { result.propertyOrder.append(.idOverride) }
        return result
    }
    var crossFieldTarget: CrossFieldTarget? {
        switch kind {
        case .moveIn: return .destination
        case .moveOut: return .source
        default: return nil
        }
    }
}

extension SequenceMark {
    var settled: SequenceMark {
        if isImpactful { return self }
        var copy = self
        copy.effect = .noop
        return copy
    }
    var hasCellEffect: Bool { (cellId != nil) != outputIsEmpty }
    var isImpactfulCellRename: Bool {
        if case .attachAndDetach = effect.kind { return isImpactful }
        return effect.isDetach && cellId != nil && isImpactful
    }
    func attachAndDetach() throws -> (SequenceMarkEffect, SequenceMarkEffect) {
        if case .attachAndDetach(let attach, let detach) = effect.kind { return (attach, detach) }
        guard effect.isDetach else {
            throw JSONDecodingError("expected cell rename")
        }
        let atom = try effect.atomId()
        var attach = SequenceMarkEffect.insert(id: atom.localId, revision: atom.revision)
        var detach = effect
        // asAttachAndDetach destructures revision before spreading the detach,
        // then appends it back after the other effect properties.
        detach.propertyOrder.removeAll { $0 == .revision }
        if atom.revision != nil { detach.propertyOrder.append(.revision) }
        else { attach.propertyOrder.removeAll { $0 == .revision } }
        return (attach, detach)
    }
}
