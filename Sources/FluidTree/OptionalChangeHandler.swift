/// feature-libraries/optional-field/optionalField.ts: optionalChangeHandler.
public struct OptionalChangeHandler {
    public init() {}
    public func createEmpty() -> OptionalChangeset { OptionalChangeset() }
    public func isEmpty(_ change: OptionalChangeset) -> Bool { change.isEmpty }
    public func getCrossFieldKeys(_ change: OptionalChangeset) -> [CrossFieldKeyRange] { [] }
    public func getNestedChanges(_ change: OptionalChangeset) -> [ChildChangeInfo] {
        change.childChanges.map { child in
            let root: ChangeAtomId?
            if case .detached(let atom) = child.register { root = atom } else { root = nil }
            return ChildChangeInfo(nodeId: child.change, inputRootId: root, detachId: child.register == .active ? change.valueReplace?.dst : nil)
        }
    }
    public func relevantRemovedRoots(_ change: OptionalChangeset, fromChild: (ChangeAtomId) throws -> [DeltaDetachedNodeId]) rethrows -> [DeltaDetachedNodeId] {
        var seen: Set<ChangeAtomId> = []
        var roots: [DeltaDetachedNodeId] = []
        for move in change.moves where seen.insert(move.src).inserted {
            roots.append(DeltaDetachedNodeId(move.src))
        }
        for child in change.childChanges {
            if case .detached(let atom) = child.register, seen.insert(atom).inserted {
                roots.append(DeltaDetachedNodeId(atom))
            }
            roots.append(contentsOf: try fromChild(child.change))
        }
        if case .detached(let atom) = change.valueReplace?.src, !seen.contains(atom) {
            roots.append(DeltaDetachedNodeId(atom))
        }
        return roots
    }
    public func intoDelta(_ change: OptionalChangeset, fromChild: (ChangeAtomId) throws -> DeltaFieldMap) rethrows -> FieldChangeDelta {
        var delta = FieldChangeDelta()
        var mark = DeltaMark(count: 1)
        var noop = true
        if let replace = change.valueReplace, replace.isEffectful {
            if !replace.isEmpty { mark.detach = DeltaDetachedNodeId(replace.dst) }
            if case .detached(let source) = replace.src { mark.attach = DeltaDetachedNodeId(source) }
            noop = false
        }
        if !change.moves.isEmpty {
            delta.rename = change.moves.map { DeltaDetachedNodeRename(count: 1, oldId: DeltaDetachedNodeId($0.src), newId: DeltaDetachedNodeId($0.dst)) }
        }
        var globals: [DeltaDetachedNodeChanges] = []
        for child in change.childChanges {
            let fields = try fromChild(child.change)
            switch child.register {
            case .active:
                mark.fields = fields
                noop = false
            case .detached(let atom):
                globals.append(DeltaDetachedNodeChanges(id: DeltaDetachedNodeId(atom), fields: fields))
            }
        }
        if !globals.isEmpty { delta.global = globals }
        if !noop { delta.local = DeltaFieldChanges(marks: [mark]) }
        return delta
    }
}
