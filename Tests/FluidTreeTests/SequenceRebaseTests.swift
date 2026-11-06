import Foundation
import FluidIdCompressor
import Testing
import FluidJS
@testable import FluidTree

@Test func crossFieldRangesInvalidateEveryOverlappingDependent() throws {
    let table = CrossFieldTable<MoveEffect, Int>()
    let first = CrossFieldManagerI(table: table, field: 1, onMoveIn: { _ in }, moveKey: { _, _, _, _ in })
    let second = CrossFieldManagerI(table: table, field: 2, onMoveIn: { _ in }, moveKey: { _, _, _, _ in })
    _ = first.get(.destination, revision: .root, id: 0, count: 3, addDependency: true)
    _ = second.get(.destination, revision: .root, id: 3, count: 3, addDependency: true)
    try first.set(.destination, revision: .root, id: 2, count: 3, value: MoveEffect(endpoint: ChangeAtomId(localId: 8, revision: .root)), invalidateDependents: true)
    #expect(table.invalidatedFields == [1, 2])
    #expect(first.get(.destination, revision: .root, id: 0, count: 6, addDependency: false).length == 2)
    #expect(first.get(.destination, revision: .root, id: 2, count: 6, addDependency: false).length == 3)
}

@Test func queueSplitsAndOffsetsMoveEffects() throws {
    let table = CrossFieldTable<MoveEffect, Int>()
    let manager = CrossFieldManagerI(table: table, field: 0, onMoveIn: { _ in }, moveKey: { _, _, _, _ in })
    try setMoveEffect(manager, target: .source, revision: .root, id: 2, count: 2, effect: MoveEffect(endpoint: ChangeAtomId(localId: 20, revision: .root)))
    let queue = MarkQueue([SequenceMark(count: 5, effect: .moveOut(id: 0, revision: .root, finalEndpoint: nil, idOverride: nil))], manager: manager)
    #expect(try queue.dequeue().count == 2)
    #expect(try queue.dequeueUpTo(1).count == 1)
    let effect = try getMoveEffect(manager, target: .source, revision: .root, id: 3, count: 1)
    #expect(effect.value?.endpoint?.localId == 21)
    #expect(try queue.dequeue().count == 1)
    #expect(try queue.dequeue().count == 1)
    #expect(try queue.isEmpty())
}

@Test func rebaseInsertTieBreaksLeftAndFollowsRemoval() throws {
    let editor = SequenceFieldEditor()
    let newRevision = RevisionTag.compressed(-1)
    let older = editor.insert(0, count: 1, firstId: ChangeAtomId(localId: 0, revision: .root), revision: .root)
    let newer = editor.insert(0, count: 1, firstId: ChangeAtomId(localId: 0, revision: newRevision), revision: newRevision)
    let metadata = RevisionMetadataSource([RevisionInfo(revision: .root), RevisionInfo(revision: newRevision)])
    let manager = CrossFieldManagerI(table: CrossFieldTable<MoveEffect, Int>(), field: 0, onMoveIn: { _ in }, moveKey: { _, _, _, _ in })
    #expect(try rebaseSequence(newer, over: older, metadata: metadata, manager: manager) { change, _, _ in change } == newer)
    let remove = editor.remove(1, count: 2, id: 0, revision: .root)
    let child = ChangeAtomId(localId: 9, revision: newRevision)
    let change = [SequenceMark(count: 1), SequenceMark(count: 1, changes: child)]
    var states: [NodeAttachState] = []
    let result = try rebaseSequence(change, over: remove, metadata: metadata, manager: manager) { change, _, state in
        states.append(try #require(state))
        return change
    }
    #expect(states == [.detached])
    #expect(result.contains { $0.cellId == ChangeAtomId(localId: 0, revision: .root) && $0.changes == child })
}

@Test func sequenceRebaseMatchesThousandTypeScriptScenarios() throws {
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
            let change = try decode("change")
            let table = CrossFieldTable<MoveEffect, Int>()
            let manager = CrossFieldManagerI(table: table, field: 0, onMoveIn: { _ in }, moveKey: { _, _, _, _ in })
            var result = try rebaseSequence(change, over: base, metadata: metadata, manager: manager) { change, _, _ in change }
            #expect(try JSONValue.bool(!table.invalidatedFields.isEmpty) == entry.member("invalidated"))
            if !table.invalidatedFields.isEmpty {
                table.resetDependencies()
                result = try rebaseSequence(change, over: base, metadata: metadata, manager: manager) { change, _, _ in change }
            }
            #expect(try JSON.stringify(codec.encode(result, revision: revision) { _ in .object(JSObject<JSONValue>()) }) == entry.member("result").asString().description)
        }
    }
}
