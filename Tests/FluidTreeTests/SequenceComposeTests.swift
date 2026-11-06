import Foundation
import FluidJS
import FluidIdCompressor
import Testing
@testable import FluidTree

@Test func composeInsertThenRemoveKeepsDetachedIdentity() throws {
    let editor = SequenceFieldEditor()
    let newer = RevisionTag.compressed(-1)
    let inserted = editor.insert(2, count: 3, firstId: ChangeAtomId(localId: 0, revision: .root), revision: .root)
    let removed = editor.remove(2, count: 3, id: 8, revision: newer)
    let manager = CrossFieldManagerI(table: CrossFieldTable<MoveEffect, Int>(), field: 0, onMoveIn: { _ in }, moveKey: { _, _, _, _ in })
    let result = try composeSequence(inserted, removed, metadata: RevisionMetadataSource([RevisionInfo(revision: .root), RevisionInfo(revision: newer)]), manager: manager) { first, second in
        try #require(second ?? first)
    }
    #expect(result == [SequenceMark(count: 2), SequenceMark(count: 3, effect: .remove(id: 8, revision: newer, idOverride: nil), cellId: ChangeAtomId(localId: 0, revision: .root))])
}

@Test func sequenceComposeMatchesThousandTypeScriptScenarios() throws {
    let session = "00000001-0000-4000-8000-000000000000"
    let compressor = try IdCompressor(session)
    let revision = RevisionTag.compressed(try compressor.generateCompressedId())
    let codec = try SequenceFieldCodec(version: 3, revisionTagCodec: RevisionTagCodec(compressor))
    let metadata = RevisionMetadataSource([RevisionInfo(revision: .root), RevisionInfo(revision: revision)])
    let url = try #require(Bundle.module.url(forResource: "sequence-rebase", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    for fixture in fixtures {
        for entry in try fixture.asArray() {
            func decode(_ name: JSString) throws -> [SequenceMark] {
                try codec.decode(JSON.parse(entry.member(name).asString().description), revision: revision, originatorId: session) { _ in ChangeAtomId(localId: 0) }
            }
            let base = try decode("base")
            let change = try decode("result")
            let table = CrossFieldTable<MoveEffect, Int>()
            let manager = CrossFieldManagerI(table: table, field: 0, onMoveIn: { _ in }, moveKey: { _, _, _, _ in })
            let composer: NodeChangeComposer = { first, second in try #require(second ?? first) }
            var result = try composeSequence(base, change, metadata: metadata, manager: manager, composeChild: composer)
            #expect(try JSONValue.bool(!table.invalidatedFields.isEmpty) == entry.member("composeInvalidated"))
            if !table.invalidatedFields.isEmpty {
                table.resetDependencies()
                result = try composeSequence(base, change, metadata: metadata, manager: manager, composeChild: composer)
            }
            #expect(try JSON.stringify(codec.encode(result, revision: revision) { _ in .object(JSObject<JSONValue>()) }) == entry.member("composed").asString().description)
        }
    }
}
