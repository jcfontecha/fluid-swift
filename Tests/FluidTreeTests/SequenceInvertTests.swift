import Foundation
import FluidIdCompressor
import Testing
import FluidJS
@testable import FluidTree

private final class InvertManager: CrossFieldManager {
    typealias Value = ChangeAtomId
    var data: [ChangeAtomId: ChangeAtomId] = [:]
    func get(_ target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int, addDependency: Bool) -> CrossFieldRange<ChangeAtomId> {
        CrossFieldRange(length: 1, value: data[ChangeAtomId(localId: id, revision: revision)])
    }
    func set(_ target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int, value: ChangeAtomId, invalidateDependents: Bool) {
        data[ChangeAtomId(localId: id, revision: revision)] = value
    }
    func onMoveIn(_ id: ChangeAtomId) {}
    func moveKey(_ target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int) {}
}

@Test func sequenceInverseDistinguishesUndoAndRollback() throws {
    let editor = SequenceFieldEditor()
    let atom = ChangeAtomId(localId: 0, revision: .root)
    let marks = editor.insert(2, count: 3, firstId: atom, revision: .root)
    for rollback in [false, true] {
        let ids = DefaultAtomIdAliasAllocator()
        try ids.reserve(.root, maxLocalId: 63)
        let inverse = try invertSequence(marks, isRollback: rollback, allocator: ids, revision: .compressed(-1), manager: InvertManager())
        #expect(inverse == [SequenceMark(count: 2), SequenceMark(count: 3, effect: .remove(id: 0, revision: .compressed(-1), idOverride: rollback ? atom : nil))])
    }
}

@Test func inverseMovesChildChangesToOriginalDestination() throws {
    let child = ChangeAtomId(localId: 12, revision: .root)
    let ids = DefaultAtomIdAliasAllocator()
    try ids.reserve(.root, maxLocalId: 63)
    let manager = InvertManager()
    let marks = [
        SequenceMark(count: 1, effect: .moveOut(id: 0, revision: .root, finalEndpoint: nil, idOverride: nil), changes: child),
        SequenceMark(count: 2),
        SequenceMark(count: 1, effect: .moveIn(id: 0, revision: .root, finalEndpoint: nil), cellId: ChangeAtomId(localId: 8, revision: .root)),
    ]
    let inverse = try invertSequence(marks, isRollback: true, allocator: ids, revision: .compressed(-1), manager: manager)
    #expect(inverse.first?.changes == nil)
    #expect(inverse.last?.changes == child)
}

@Test func sequenceInversionMatchesThousandTypeScriptFixtures() throws {
    let session = "00000001-0000-4000-8000-000000000000"
    let compressor = try IdCompressor(session)
    let revision = RevisionTag.compressed(try compressor.generateCompressedId())
    let codec = try SequenceFieldCodec(version: 3, revisionTagCodec: RevisionTagCodec(compressor))
    let url = try #require(Bundle.module.url(forResource: "sequence-invert", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    for fixture in fixtures {
        for entry in try fixture.asArray() {
            let input = try JSON.parse(entry.member("input").asString().description)
            let marks = try codec.decode(input, revision: revision, originatorId: session) { _ in ChangeAtomId(localId: 0) }
            for (index, rollback) in [false, true].enumerated() {
                let allocator = DefaultAtomIdAliasAllocator()
                try allocator.reserve(.root, maxLocalId: 63)
                let result = try invertSequence(marks, isRollback: rollback, allocator: allocator, revision: revision, manager: InvertManager())
                let encoded = try codec.encode(result, revision: revision) { _ in .object(JSObject<JSONValue>()) }
                #expect(try JSON.stringify(encoded) == entry.member("inverses").asArray()[index].asString().description)
            }
        }
    }
}
