import Testing
@testable import FluidTree

@Test func genericFieldRebaseCallsChildrenWithUnspecifiedAttachment() throws {
    let first = newGenericChangeset()
    let second = newGenericChangeset()
    first.set(2, ChangeAtomId(localId: 1, revision: .root))
    second.set(4, ChangeAtomId(localId: 2, revision: .root))
    var callbacks = 0
    let result = try rebaseGenericChange(first, over: second) { change, base, state in
        #expect(state == nil)
        callbacks += 1
        return change ?? base
    }
    #expect(callbacks == 2)
    #expect(result.entries.map(\.0) == [2, 4])
    let delta = try GenericChangeHandler().intoDelta(result) { _ in DeltaFieldMap() }
    #expect(delta.local?.marks.map(\.count) == [2, 1, 1, 1])
}
