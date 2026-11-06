import Testing
@testable import FluidTree

@Test func revisionReplacementKeepsOverlappingRangesContiguous() throws {
    let input = ChangeAtomId(localId: 1, revision: .root)
    for offset in 0..<3 {
        let replacer = DefaultRevisionReplacer(updatedRevision: .compressed(-1), obsoleteRevisions: [.root])
        _ = try replacer.getUpdatedAtomId(input.offset(offset), count: 1)
        #expect(try replacer.getUpdatedAtomId(input, count: 3) == ChangeAtomId(localId: 1, revision: .compressed(-1)))
        #expect(try replacer.getUpdatedAtomId(input.offset(1), count: 2) == ChangeAtomId(localId: 2, revision: .compressed(-1)))
    }
}

@Test func revisionReplacementMatchesUpstreamNoncontiguousFailure() throws {
    let replacer = DefaultRevisionReplacer(updatedRevision: .compressed(-3), obsoleteRevisions: [.root, .compressed(-1)])
    _ = try replacer.getUpdatedAtomId(ChangeAtomId(localId: 2, revision: .compressed(-1)), count: 100)
    _ = try replacer.getUpdatedAtomId(ChangeAtomId(localId: 2, revision: .root))
    #expect(throws: (any Error).self) {
        try replacer.getUpdatedAtomId(ChangeAtomId(localId: 1, revision: .root), count: 2)
    }
}

@Test func sequenceRevisionReplacementUpdatesAllIdentityRanges() throws {
    let replacer = DefaultRevisionReplacer(updatedRevision: .compressed(-1), obsoleteRevisions: [.root])
    let original = SequenceMark(count: 2, effect: .moveOut(id: 1, revision: .root, finalEndpoint: ChangeAtomId(localId: 8, revision: .root), idOverride: ChangeAtomId(localId: 12, revision: .root)), cellId: ChangeAtomId(localId: 20, revision: .root))
    let result = try replaceSequenceRevisions([original], replacer: replacer)
    #expect(result == [SequenceMark(count: 2, effect: .moveOut(id: 1, revision: .compressed(-1), finalEndpoint: ChangeAtomId(localId: 8, revision: .compressed(-1)), idOverride: ChangeAtomId(localId: 12, revision: .compressed(-1))), cellId: ChangeAtomId(localId: 20, revision: .compressed(-1)))])
}
