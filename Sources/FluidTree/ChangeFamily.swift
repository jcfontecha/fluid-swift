import FluidJS

/// core/rebase/changeRebaser.ts: ChangeRebaser (the members EditManager and the branch graph use).
public protocol ChangeRebaser {
    associatedtype Change
    func compose(_ changes: [TaggedChange<Change>]) throws -> Change
    func invert(_ change: TaggedChange<Change>, isRollback: Bool, revision: RevisionTag) throws -> Change
    func rebase(_ change: TaggedChange<Change>, over: TaggedChange<Change>, metadata: RevisionMetadataSource, ignoreNoChangeViolation: Bool) throws -> Change
}

/// core/change-family/changeFamily.ts: ChangeFamily.
public protocol ChangeFamily: AnyObject {
    associatedtype Editor
    associatedtype Rebaser: ChangeRebaser
    var rebaser: Rebaser { get }
    func buildEditor(mintRevisionTag: @escaping () throws -> RevisionTag, changeReceiver: @escaping (TaggedChange<Rebaser.Change>) throws -> Void) -> Editor
    /// Returns normally for a well-formed change; throws the validation message otherwise.
    func validator(_ change: Rebaser.Change) throws
    func hasSchemaChange(_ change: Rebaser.Change) -> Bool
}

/// core/rebase/changeRebaser.ts: tagChange.
public func tagChange<Change>(_ change: Change, _ revision: RevisionTag?) -> TaggedChange<Change> {
    TaggedChange(change: change, revision: revision)
}

/// core/rebase/changeRebaser.ts: tagRollbackInverse.
public func tagRollbackInverse<Change>(_ inverseChange: Change, revision: RevisionTag?, rollbackOf: RevisionTag?) -> TaggedChange<Change> {
    TaggedChange(change: inverseChange, revision: revision, rollbackOf: rollbackOf)
}

/// core/rebase/changeRebaser.ts: makeAnonChange.
public func makeAnonChange<Change>(_ change: Change) -> TaggedChange<Change> {
    TaggedChange(change: change, revision: nil)
}

/// core/rebase/changeRebaser.ts: mapTaggedChange.
public func mapTaggedChange<In, Out>(_ input: TaggedChange<In>, _ change: Out) -> TaggedChange<Out> {
    TaggedChange(change: change, revision: input.revision, rollbackOf: input.rollbackOf)
}

/// modularChangeFamily.ts: `ModularChangeFamily implements ChangeFamily, ChangeRebaser`; its
/// `rebaser` getter returns the family itself.
extension ModularChangeFamily: ChangeRebaser, ChangeFamily {
    public typealias Change = ModularChangeset
    public var rebaser: ModularChangeFamily { self }
    /// modularChangeFamily.ts buildEditor ignores `mintRevisionTag`.
    public func buildEditor(mintRevisionTag: @escaping () throws -> RevisionTag, changeReceiver: @escaping (TaggedChange<ModularChangeset>) throws -> Void) -> ModularEditBuilder {
        buildEditor(changeReceiver: changeReceiver)
    }
}
