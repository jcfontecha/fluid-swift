import Foundation
import Testing
import FluidJS
@testable import FluidTree

private func readMark(_ value: JSONValue) throws -> SequenceMark {
    let count = try value.member("count").asInt()
    let object = try value.asObject()
    let type = object["type"]
    let cell = try object["cellId"].map { try readAtom($0) }
    let override = try object["idOverride"].map { try readAtom($0) }
    var effect = SequenceMarkEffect.noop
    if let type {
        let id = try value.member("id").asNumber()
        switch try type.asString() {
        case "Insert": effect = .insert(id: id, revision: .root)
        case "Remove": effect = .remove(id: id, revision: .root, idOverride: override)
        case "MoveIn": effect = .moveIn(id: id, revision: .root, finalEndpoint: nil)
        case "MoveOut": effect = .moveOut(id: id, revision: .root, finalEndpoint: nil, idOverride: override)
        default: throw JSONDecodingError("unsupported fixture mark")
        }
    }
    return SequenceMark(count: count, effect: effect, cellId: cell)
}
private func readAtom(_ value: JSONValue) throws -> ChangeAtomId {
    #expect(try value.member("revision").asString() == "root")
    return ChangeAtomId(localId: try value.member("localId").asNumber(), revision: .root)
}
@Test func sequenceEditorsMatchThousandTypeScriptScenarios() throws {
    let url = try #require(Bundle.module.url(forResource: "sequence-editors", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    let editor = SequenceFieldEditor()
    let atom = ChangeAtomId(localId: 8, revision: .root)
    for fixture in fixtures {
        let index = try fixture.member("index").asInt()
        let count = try fixture.member("count").asInt()
        let destination = try fixture.member("destination").asInt()
        let actual: [(JSString, [SequenceMark])] = [
            ("insert", editor.insert(index, count: count, firstId: atom, revision: .root)),
            ("remove", editor.remove(index, count: count, id: 0, revision: .root)),
            ("revive", try editor.revive(index, count: count, detachEvent: atom, revision: .root)),
            ("move", editor.move(index, count: count, destination: destination, detachCellId: 0, attachCellId: atom, revision: .root)),
            ("moveIn", editor.moveIn(destination, count: count, moveId: 0, attachCellId: atom, revision: .root)),
            ("moveOut", editor.moveOut(index, count: count, id: 0, revision: .root)),
            ("return", editor.returnNodes(index, count: count, destination: destination, detachCellId: ChangeAtomId(localId: 32, revision: .root), attachCellId: atom, revision: .root)),
        ]
        for (kind, marks) in actual {
            #expect(marks == (try fixture.member(kind).asArray().map(readMark)))
        }
    }
}

@Test func sequenceEditorRejectsMissingReviveRevisionAndUnorderedChildren() throws {
    let editor = SequenceFieldEditor()
    #expect(throws: (any Error).self) {
        try editor.revive(0, count: 0, detachEvent: ChangeAtomId(localId: 0), revision: .root)
    }
    let child = ChangeAtomId(localId: 4, revision: .root)
    #expect(try editor.buildChildChanges([(2, child), (4, child)]) == [
        SequenceMark(count: 2),
        SequenceMark(count: 1, changes: child),
        SequenceMark(count: 1),
        SequenceMark(count: 1, changes: child),
    ])
    #expect(throws: (any Error).self) {
        try editor.buildChildChanges([(2, child), (2, child)])
    }
}
