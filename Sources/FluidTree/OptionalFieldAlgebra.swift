import FluidJS

/// feature-libraries/optional-field/optionalField.ts: optionalChangeRebaser.compose.
public func composeOptional(_ first: OptionalChangeset, _ second: OptionalChangeset, composeChild: NodeChangeComposer) throws -> OptionalChangeset {
    var forward = ChangeAtomIdMap<ChangeAtomId>()
    var backward = ChangeAtomIdMap<ChangeAtomId>()
    for move in first.moves {
        forward[move.src] = move.dst
        backward[move.dst] = move.src
    }
    let firstSrc = first.valueReplace?.src
    let firstDst = first.valueReplace?.effectfulDst
    func original(_ id: RegisterId) -> RegisterId {
        switch id {
        case .active: return firstSrc ?? .active
        case .detached(let atom):
            if atom == firstDst { return .active }
            return .detached(backward[atom] ?? atom)
        }
    }
    let composedSrc = second.valueReplace?.src.map(original) ?? (second.valueReplace == nil ? firstSrc : nil)
    let secondChildren = RegisterMap<ChangeAtomId>()
    for child in second.childChanges { secondChildren.set(original(child.register), child.change) }
    var result = OptionalChangeset()
    for child in first.childChanges {
        result.childChanges.append(OptionalChildChange(child.register, try composeChild(child.change, secondChildren.get(child.register))))
        secondChildren.delete(child.register)
    }
    for (register, change) in secondChildren.entries {
        result.childChanges.append(OptionalChildChange(register, try composeChild(nil, change)))
    }
    for move in second.moves {
        if let source = backward[move.src] {
            result.moves.append(OptionalMove(source, move.dst))
            forward[source] = nil
            backward[move.src] = nil
        } else if move.src != firstDst {
            result.moves.append(move)
        }
    }
    for (source, destination) in forward.entries where composedSrc != .detached(source) {
        result.moves.append(OptionalMove(source, destination))
    }
    if case .detached(let source) = firstSrc, let replacement = second.valueReplace,
       replacement.isEffectful && source != replacement.dst {
        result.moves.append(OptionalMove(source, replacement.dst))
    }
    guard let initial = first.valueReplace ?? second.valueReplace else { return result }
    let destination: ChangeAtomId
    if let replacement = second.valueReplace {
        if first.valueReplace == nil || firstSrc == .active || replacement.src == first.valueReplace.map({ .detached($0.dst) }) {
            destination = replacement.dst
        } else if let originalDst = first.valueReplace?.dst {
            destination = second.moves.first { $0.src == originalDst }?.dst ?? originalDst
        } else {
            throw JSONDecodingError("0x8cf: missing replace destination")
        }
    } else {
        guard let originalDst = first.valueReplace?.dst else {
            throw JSONDecodingError("0x8ce: missing replace destination")
        }
        destination = second.moves.first { $0.src == originalDst }?.dst ?? originalDst
    }
    result.valueReplace = OptionalReplace(isEmpty: initial.isEmpty, src: composedSrc, dst: destination, sourceFirst: false)
    return result
}

private func optionalForwardMap(_ change: OptionalChangeset) -> RegisterMap<RegisterId> {
    let map = RegisterMap<RegisterId>()
    for move in change.moves { map.set(.detached(move.src), .detached(move.dst)) }
    if let replace = change.valueReplace {
        if let destination = replace.effectfulDst { map.set(.active, .detached(destination)) }
        if let source = replace.src { map.set(source, .active) }
    }
    return map
}

/// feature-libraries/optional-field/optionalField.ts: optionalChangeRebaser.invert.
public func invertOptional(_ change: OptionalChangeset, isRollback: Bool, allocator: DefaultAtomIdAliasAllocator, revision: RevisionTag?) throws -> OptionalChangeset {
    let map = optionalForwardMap(change)
    var result = OptionalChangeset(
        moves: change.moves.map { OptionalMove($0.dst, $0.src) },
        childChanges: change.childChanges.map { OptionalChildChange(map.get($0.register) ?? $0.register, $0.change) })
    if let replace = change.valueReplace {
        if replace.isEffectful {
            let destination: ChangeAtomId
            if isRollback, case .detached(let source) = replace.src {
                destination = source
            } else {
                destination = ChangeAtomId(localId: try allocator.allocate(), revision: revision)
            }
            result.valueReplace = OptionalReplace(isEmpty: replace.src == nil, src: replace.isEmpty ? nil : .detached(replace.dst), dst: destination, sourceFirst: false)
        } else if !isRollback && replace.src == .active {
            result.valueReplace = OptionalReplace(isEmpty: false, src: .active, dst: ChangeAtomId(localId: try allocator.allocate(), revision: revision))
        }
    }
    return result
}

/// feature-libraries/optional-field/optionalField.ts: optionalChangeRebaser.rebase.
public func rebaseOptional(_ change: OptionalChangeset, over base: OptionalChangeset, rebaseChild: NodeChangeRebaser) throws -> OptionalChangeset {
    let forward = optionalForwardMap(base)
    var baseMoves = ChangeAtomIdMap<ChangeAtomId>()
    for move in base.moves { baseMoves[move.src] = move.dst }
    let baseChildren = RegisterMap<ChangeAtomId>()
    for child in base.childChanges { baseChildren.set(child.register, child.change) }
    var result = OptionalChangeset(moves: change.moves.map { OptionalMove($0.src, baseMoves[$0.src] ?? $0.dst) })
    func rebase(_ register: RegisterId, _ change: ChangeAtomId?, _ base: ChangeAtomId?) throws {
        let rebased = forward.get(register) ?? register
        if let child = try rebaseChild(change, base, rebased == .active ? .attached : .detached) {
            result.childChanges.append(OptionalChildChange(rebased, child))
        }
    }
    for child in change.childChanges {
        let base = baseChildren.get(child.register)
        if base != nil { baseChildren.delete(child.register) }
        try rebase(child.register, child.change, base)
    }
    for (register, base) in baseChildren.entries { try rebase(register, nil, base) }
    if let replace = change.valueReplace {
        result.valueReplace = OptionalReplace(
            isEmpty: base.valueReplace.map { $0.src == nil } ?? replace.isEmpty,
            src: replace.src.map { forward.get($0) ?? $0 }, dst: replace.dst, sourceFirst: false)
    }
    return result
}

public func pruneOptional(_ change: OptionalChangeset, pruneChild: (ChangeAtomId) throws -> ChangeAtomId?) rethrows -> OptionalChangeset {
    var result = change
    result.childrenFirst = false
    result.childChanges = try change.childChanges.compactMap { child in
        try pruneChild(child.change).map { OptionalChildChange(child.register, $0) }
    }
    return result
}

public func replaceOptionalRevisions(_ change: OptionalChangeset, replace: (ChangeAtomId) throws -> ChangeAtomId) rethrows -> OptionalChangeset {
    func register(_ id: RegisterId) throws -> RegisterId {
        if case .detached(let atom) = id { return .detached(try replace(atom)) }
        return id
    }
    var result = OptionalChangeset()
    result.childrenFirst = true
    if let value = change.valueReplace {
        let destination = try replace(value.dst)
        let source = try value.src.map(register)
        result.valueReplace = OptionalReplace(isEmpty: value.isEmpty, src: source, dst: destination, sourceFirst: value.sourceFirst)
    }
    result.childChanges = try change.childChanges.map { OptionalChildChange(try register($0.register), try replace($0.change)) }
    result.moves = try change.moves.map { OptionalMove(try replace($0.src), try replace($0.dst)) }
    return result
}
