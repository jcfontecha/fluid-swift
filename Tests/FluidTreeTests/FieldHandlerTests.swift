import Testing
import FluidJS
@testable import FluidTree

@Test func sequenceHandlerKeepsMoveNodeIdentitySeparateFromCellOverride() throws {
    let child = ChangeAtomId(localId: 20, revision: .root)
    let node = ChangeAtomId(localId: 1, revision: .root)
    let override = ChangeAtomId(localId: 40, revision: .root)
    let change = [SequenceMark(count: 1, effect: .moveOut(id: 1, revision: .root, finalEndpoint: nil, idOverride: override), changes: child)]
    let handler = SequenceFieldChangeHandler()
    #expect(try handler.getNestedChanges(change) == [ChildChangeInfo(nodeId: child, inputRootId: nil, detachId: node)])
    let delta = try handler.intoDelta(change) { _ in DeltaFieldMap() }
    #expect(delta.local?.marks.first?.detach == DeltaDetachedNodeId(node))
    #expect(delta.local?.marks.first?.fields == nil)
}

@Test func optionalHandlerPreservesEmptyChildDeltaAndDeduplicatesOnlyDirectRoots() throws {
    let root = ChangeAtomId(localId: 1, revision: .root)
    let child = ChangeAtomId(localId: 8, revision: .root)
    let change = OptionalChangeset(moves: [OptionalMove(root, child)], childChanges: [OptionalChildChange(.active, child), OptionalChildChange(.detached(root), child)], valueReplace: OptionalReplace(isEmpty: false, src: .detached(root), dst: child))
    let handler = OptionalChangeHandler()
    let delta = try handler.intoDelta(change) { _ in DeltaFieldMap() }
    #expect(delta.local?.marks.first?.fields != nil)
    #expect(delta.global?.count == 1)
    let roots = handler.relevantRemovedRoots(change) { _ in [DeltaDetachedNodeId(root)] }
    #expect(roots == [DeltaDetachedNodeId(root), DeltaDetachedNodeId(root), DeltaDetachedNodeId(root)])
}

@Test func optionalFilterRejectsRemovingDetachWithoutAttach() throws {
    let change = OptionalFieldEditor().set(wasEmpty: false, fill: ChangeAtomId(localId: 1), detach: ChangeAtomId(localId: 2))
    #expect(throws: (any Error).self) {
        try filterOptional(change, preserveOtherEdits: true, filterDetach: { _, count, _, _ in
            RangeQueryResult(length: count, value: FilterDetachResult(action: .remove))
        }, filterAttach: { _, count, _, _ in
            RangeQueryResult(length: count, value: FilterAttachResult(action: .preserve))
        })
    }
}
