import Testing
import FluidJS
@testable import FluidTree

@Test func modularValidatorRejectsWrongParentAndMissingCrossFieldKeys() throws {
    let family = ModularChangeFamily()
    let builder = family.buildEditor { _ in }
    _ = try builder.generateId(64)
    let marks = SequenceFieldEditor().insert(0, count: 1, firstId: ChangeAtomId(localId: 0, revision: .root), revision: .root)
    let change = try builder.buildChanges([.field(path: FieldUpPath(parent: UpPath(parentField: "a", parentIndex: 0), field: "children"), change: FieldChange(fieldKind: .sequence, change: .sequence(marks)), revision: .root)])
    try family.validator(change)
    var wrong = change
    wrong.nodeToParent = change.nodeToParent.clone()
    wrong.nodeToParent.set(ChangeAtomId(localId: 64, revision: .root), FieldId(field: "wrong"))
    #expect(throws: (any Error).self) { try family.validator(wrong) }
    var missing = change
    missing.crossFieldKeys = newCrossFieldKeyTable(context: change.context)
    #expect(throws: (any Error).self) { try family.validator(missing) }
}

@Test func refreshersExcludeBuiltRangesAndRequireMissingRoots() throws {
    let chunk = try BasicChunk(json: JSON.parse(#"[{"type":"N","fields":[]},{"type":"N","fields":[]}]"#))
    var change = ModularChangeset()
    change.builds = newChangeAtomIdBTree(context: change.context)
    change.builds?.set(ChangeAtomId(localId: 10, revision: .root), chunk)
    let built = DeltaDetachedNodeId(ChangeAtomId(localId: 11, revision: .root))
    let missing = DeltaDetachedNodeId(ChangeAtomId(localId: 40, revision: .root))
    var fetched: [DeltaDetachedNodeId] = []
    let refreshed = try updateRefreshers(change, getDetachedNode: { id in
        fetched.append(id)
        return chunk
    }, removedRoots: [built, missing])
    #expect(fetched == [missing])
    #expect(refreshed.refreshers?.count == 1)
    #expect(change.refreshers == nil)
    #expect(throws: (any Error).self) { try updateRefreshers(change, getDetachedNode: { _ in nil }, removedRoots: [missing]) }
    #expect(try updateRefreshers(change, getDetachedNode: { _ in nil }, removedRoots: [missing], requireRefreshers: false).refreshers == nil)
}
