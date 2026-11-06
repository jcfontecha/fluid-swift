import FluidJS

/// feature-libraries/modular-schema/modularChangeFamily.ts.
public final class ModularChangeFamily {
    public let context: BTreeStorageContext
    public let minimumClientVersion: FluidClientVersion
    public init(context: BTreeStorageContext = BTreeStorageContext(), minimumClientVersion: FluidClientVersion = .v2_0) {
        self.context = context
        self.minimumClientVersion = minimumClientVersion
    }
    public func invert(_ change: TaggedChange<ModularChangeset>, isRollback: Bool, revision: RevisionTag) throws -> ModularChangeset {
        try invertModularChange(change, isRollback: isRollback, revision: revision, context: context)
    }
}

extension FieldChangeset {
    func inverted<M: CrossFieldManager>(isRollback: Bool, allocator: DefaultAtomIdAliasAllocator, revision: RevisionTag, manager: M) throws -> FieldChangeset where M.Value == ChangeAtomId {
        switch self {
        case .sequence(let change): return .sequence(try invertSequence(change, isRollback: isRollback, allocator: allocator, revision: revision, manager: manager))
        case .optional(let change): return .optional(try invertOptional(change, isRollback: isRollback, allocator: allocator, revision: revision))
        case .generic: return self
        case .noChange: return self
        }
    }
    func rebased<M: CrossFieldManager>(over: FieldChangeset, metadata: RevisionMetadataSource, manager: M, rebaseChild: NodeChangeRebaser) throws -> FieldChangeset where M.Value == MoveEffect {
        switch (self, over) {
        case (.sequence(let change), .sequence(let base)): return .sequence(try rebaseSequence(change, over: base, metadata: metadata, manager: manager, rebaseChild: rebaseChild))
        case (.optional(let change), .optional(let base)): return .optional(try rebaseOptional(change, over: base, rebaseChild: rebaseChild))
        case (.generic(let change), .generic(let base)): return .generic(try rebaseGenericChange(change, over: base, rebaseChild: rebaseChild))
        case (.noChange, .noChange): return .noChange
        default: throw JSONDecodingError("incompatible field changes")
        }
    }
    func pruned(pruneChild: (ChangeAtomId) throws -> ChangeAtomId?) throws -> FieldChangeset {
        switch self {
        case .sequence(let change): return .sequence(try pruneSequence(change, pruneChild: pruneChild))
        case .optional(let change): return .optional(try pruneOptional(change, pruneChild: pruneChild))
        case .generic(let change): return .generic(try pruneGenericChange(change, pruneChild: pruneChild))
        case .noChange: return self
        }
    }
}
func emptyFieldChange(_ kind: FieldKindIdentifier, context: BTreeStorageContext) -> FieldChangeset {
    switch kind {
    case .sequence: return .sequence([])
    case .optional, .required: return .optional(OptionalChangeset())
    case .generic: return .generic(newGenericChangeset(context: context))
    case .identifier, .forbidden: return .noChange
    }
}
func normalizeFieldChanges(_ first: FieldChange, _ second: FieldChange) throws -> (FieldKindIdentifier, FieldChangeset, FieldChangeset) {
    let kind = first.fieldKind == .generic ? second.fieldKind : first.fieldKind
    return (kind, try first.change.converted(to: kind), try second.change.converted(to: kind))
}
