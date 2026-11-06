import FluidJS

/// feature-libraries/sequence-field/types.ts: a run of cells and its effect.
public struct SequenceMark: Equatable, Sendable {
    public var count: Int
    private var storedEffect: SequenceMarkEffect
    private var storedCellId: ChangeAtomId?
    private var storedChanges: ChangeAtomId?
    public var propertyOrder: [SequenceProperty] {
        didSet { storedEffect.propertyOrder = propertyOrder.filter(\.isEffect) }
    }
    public var effect: SequenceMarkEffect {
        get { storedEffect }
        set {
            storedEffect = newValue
            if newValue == .noop {
                propertyOrder = [.count] + (storedCellId == nil ? [] : [.cellId]) + (storedChanges == nil ? [] : [.changes])
            } else {
                propertyOrder.removeAll { $0.isEffect && !newValue.propertyOrder.contains($0) }
                for property in newValue.propertyOrder where !propertyOrder.contains(property) { propertyOrder.append(property) }
            }
        }
    }
    public var cellId: ChangeAtomId? {
        get { storedCellId }
        set {
            storedCellId = newValue
            if newValue == nil { propertyOrder.removeAll { $0 == .cellId } }
            else if !propertyOrder.contains(.cellId) { propertyOrder.append(.cellId) }
        }
    }
    public var changes: ChangeAtomId? {
        get { storedChanges }
        set {
            storedChanges = newValue
            if newValue == nil { propertyOrder.removeAll { $0 == .changes } }
            else if !propertyOrder.contains(.changes) { propertyOrder.append(.changes) }
        }
    }
    public init(count: Int, effect: SequenceMarkEffect = .noop, cellId: ChangeAtomId? = nil, changes: ChangeAtomId? = nil, propertyOrder: [SequenceProperty]? = nil) {
        self.count = count
        storedEffect = effect
        storedCellId = cellId
        storedChanges = changes
        self.propertyOrder = propertyOrder ?? (effect.propertyOrder + [.count] + (cellId == nil ? [] : [.cellId]) + (changes == nil ? [] : [.changes]))
        storedEffect.propertyOrder = self.propertyOrder.filter(\.isEffect)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.count == rhs.count && lhs.storedEffect == rhs.storedEffect && lhs.cellId == rhs.cellId && lhs.changes == rhs.changes
    }
}

/// feature-libraries/sequence-field/sequenceFieldEditor.ts.
public struct SequenceFieldEditor {
    public init() {}

    public func buildChildChanges(_ changes: [(Int, ChangeAtomId)]) throws -> [SequenceMark] {
        var marks: [SequenceMark] = []
        var currentIndex = 0
        for (index, change) in changes {
            guard index >= currentIndex else {
                throw JSONDecodingError("0xabe: Child changes must be in order")
            }
            if index > currentIndex {
                marks.append(SequenceMark(count: index - currentIndex))
            }
            marks.append(SequenceMark(count: 1, changes: change))
            currentIndex = index + 1
        }
        return marks
    }

    public func insert(_ index: Int, count: Int, firstId: ChangeAtomId, revision: RevisionTag?) -> [SequenceMark] {
        at(index, SequenceMark(count: count, effect: .insert(id: firstId.localId, revision: revision), cellId: firstId, propertyOrder: [.type, .id, .count, .cellId, .revision]))
    }

    public func remove(_ index: Int, count: Int, id: Double, revision: RevisionTag?) -> [SequenceMark] {
        count == 0 ? [] : at(index, SequenceMark(count: count, effect: .remove(id: id, revision: revision, idOverride: nil), propertyOrder: [.type, .count, .id, .revision]))
    }

    public func revive(_ index: Int, count: Int, detachEvent: ChangeAtomId, revision: RevisionTag?) throws -> [SequenceMark] {
        guard detachEvent.revision != nil else {
            throw JSONDecodingError("0x724: Detach event must have a revision")
        }
        return count == 0 ? [] : insert(index, count: count, firstId: detachEvent, revision: revision)
    }

    public func moveOut(_ index: Int, count: Int, id: Double, revision: RevisionTag?) -> [SequenceMark] {
        at(index, SequenceMark(count: count, effect: .moveOut(id: id, revision: revision, finalEndpoint: nil, idOverride: nil), propertyOrder: [.type, .id, .count, .revision]))
    }

    public func moveIn(_ index: Int, count: Int, moveId: Double, attachCellId: ChangeAtomId, revision: RevisionTag?) -> [SequenceMark] {
        at(index, SequenceMark(count: count, effect: .moveIn(id: moveId, revision: revision, finalEndpoint: nil), cellId: attachCellId, propertyOrder: [.type, .id, .count, .cellId, .revision]))
    }

    public func move(_ index: Int, count: Int, destination: Int, detachCellId: Double, attachCellId: ChangeAtomId, revision: RevisionTag?) -> [SequenceMark] {
        moveMarks(index, count: count, destination: destination, id: detachCellId, attachCellId: attachCellId, revision: revision, idOverride: nil)
    }

    public func returnNodes(_ index: Int, count: Int, destination: Int, detachCellId: ChangeAtomId, attachCellId: ChangeAtomId, revision: RevisionTag?) -> [SequenceMark] {
        moveMarks(index, count: count, destination: destination, id: attachCellId.localId, attachCellId: attachCellId, revision: revision, idOverride: detachCellId)
    }

    private func at(_ index: Int, _ mark: SequenceMark) -> [SequenceMark] {
        index == 0 ? [mark] : [SequenceMark(count: index), mark]
    }

    private func moveMarks(_ index: Int, count: Int, destination: Int, id: Double, attachCellId: ChangeAtomId, revision: RevisionTag?, idOverride: ChangeAtomId?) -> [SequenceMark] {
        if count == 0 {
            return []
        }
        let attach = SequenceMark(count: count, effect: .moveIn(id: id, revision: revision, finalEndpoint: nil), cellId: attachCellId, propertyOrder: [.type, .id, .count, .cellId, .revision])
        let detach = SequenceMark(count: count, effect: .moveOut(id: id, revision: revision, finalEndpoint: nil, idOverride: idOverride), propertyOrder: [.type, .id] + (idOverride == nil ? [] : [.idOverride]) + [.count, .revision])
        var marks: [SequenceMark] = []
        func offset(_ count: Int) {
            if count > 0 {
                marks.append(SequenceMark(count: count))
            }
        }
        offset(min(index, destination))
        if destination <= index {
            marks.append(attach)
            offset(index - destination)
            marks.append(detach)
        } else if index + count <= destination {
            marks.append(detach)
            offset(destination - index - count)
            marks.append(attach)
        } else {
            // utils.ts splitMark: split IDs, including detached-cell overrides.
            let length = destination - index
            var first = detach
            first.count = length
            var secondOverride = idOverride
            if secondOverride != nil {
                secondOverride?.localId += Double(length)
            }
            let second = SequenceMark(count: count - length, effect: .moveOut(id: id + Double(length), revision: revision, finalEndpoint: nil, idOverride: secondOverride), propertyOrder: detach.propertyOrder)
            marks.append(first)
            marks.append(attach)
            marks.append(second)
        }
        return marks
    }
}
