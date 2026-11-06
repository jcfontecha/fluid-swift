import Foundation
import Testing
import FluidJS
import FluidIdCompressor
@testable import FluidTree

@Test func optionalCodecDistinguishesClearFromSelf() throws {
    let session = "00000001-0000-4000-8000-000000000000"
    let codec = OptionalFieldCodec(RevisionTagCodec(try IdCompressor(session)))
    let id = ChangeAtomId(localId: 4, revision: .root)
    let clear = OptionalFieldEditor().clear(wasEmpty: false, detachId: id)
    let keep = OptionalChangeset(valueReplace: OptionalReplace(isEmpty: false, src: .active, dst: id))
    #expect(try JSON.stringify(codec.encode(clear, revision: .root) { _ in .null }) == "{\"r\":{\"e\":false,\"d\":4}}")
    #expect(try JSON.stringify(codec.encode(keep, revision: .root) { _ in .null }) == "{\"r\":{\"e\":false,\"d\":4,\"s\":null}}")
    #expect(try codec.decode(codec.encode(keep, revision: .root) { _ in .null }, revision: .root, originatorId: session) { _ in id } == keep)
}

@Test func optionalUndoAndRollbackAllocateDifferentDestinations() throws {
    let fill = ChangeAtomId(localId: 8, revision: .root)
    let detach = ChangeAtomId(localId: 9, revision: .root)
    let change = OptionalFieldEditor().set(wasEmpty: false, fill: fill, detach: detach)
    for rollback in [false, true] {
        let ids = DefaultAtomIdAliasAllocator()
        let inverse = try invertOptional(change, isRollback: rollback, allocator: ids, revision: .compressed(-1))
        #expect(inverse.valueReplace?.src == .detached(detach))
        #expect(inverse.valueReplace?.dst == (rollback ? fill : ChangeAtomId(localId: 0, revision: .compressed(-1))))
    }
}

@Test func registerMapGroupsByLocalIdThenRevisionAndClonesIndependently() {
    let map = RegisterMap<Int>()
    let first = RegisterId.detached(ChangeAtomId(localId: 1, revision: .root))
    let second = RegisterId.detached(ChangeAtomId(localId: 2, revision: .root))
    let third = RegisterId.detached(ChangeAtomId(localId: 1, revision: .compressed(-1)))
    map.set(first, 1)
    map.set(second, 2)
    map.set(third, 3)
    #expect(map.keys == [first, third, second])
    let clone = map.clone()
    clone.delete(first)
    #expect(map.get(first) == 1)
    #expect(clone.get(first) == nil)
}

@Test func optionalAlgebraMatchesThousandTypeScriptScenarios() throws {
    let session = "00000001-0000-4000-8000-000000000000"
    let compressor = try IdCompressor(session)
    let revision = RevisionTag.compressed(try compressor.generateCompressedId())
    let updatedRevision = RevisionTag.compressed(try compressor.generateCompressedId())
    let revisions = RevisionTagCodec(compressor)
    let atoms = ChangeAtomIdCodec(revisions)
    let codec = OptionalFieldCodec(revisions)
    let url = try #require(Bundle.module.url(forResource: "optional-fields", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    func decodeNode(_ value: JSONValue) throws -> ChangeAtomId {
        let field = try #require(value.member("fieldChanges").asArray().first)
        return try atoms.decode(field.member("change"), revision: revision, originatorId: session)
    }
    func encodeNode(_ id: ChangeAtomId) throws -> JSONValue {
        var field = JSObject<JSONValue>()
        field["fieldKey"] = .string("test")
        field["fieldKind"] = .string("test")
        field["change"] = try atoms.encode(id, revision: revision)
        var node = JSObject<JSONValue>()
        node["fieldChanges"] = .array([.object(field)])
        return .object(node)
    }
    for fixture in fixtures {
        for entry in try fixture.asArray() {
            func decode(_ name: JSString) throws -> OptionalChangeset {
                try codec.decode(JSON.parse(entry.member(name).asString().description), revision: revision, originatorId: session, decodeNode: decodeNode)
            }
            func wire(_ change: OptionalChangeset) throws -> String {
                try JSON.stringify(codec.encode(change, revision: revision, encodeNode: encodeNode))
            }
            let base = try decode("base")
            let change = try decode("change")
            #expect(try wire(change) == entry.member("change").asString().description)
            var states: [JSONValue] = []
            let rebased = try rebaseOptional(change, over: base) { change, over, state in
                states.append(.string(state == .attached ? "attached" : "detached"))
                return change ?? over
            }
            #expect(try JSONValue.array(states) == entry.member("states"))
            #expect(try wire(rebased) == entry.member("rebased").asString().description)
            let composed = try composeOptional(base, rebased) { first, second in try #require(second ?? first) }
            #expect(try wire(composed) == entry.member("composed").asString().description)
            let replacer = DefaultRevisionReplacer(updatedRevision: updatedRevision, obsoleteRevisions: [.root, revision])
            let replaced = try replaceOptionalRevisions(composed) { try replacer.getUpdatedAtomId($0) }
            #expect(try wire(replaced) == entry.member("replaced").asString().description)
            let pruned = pruneOptional(composed) { $0.localId.truncatingRemainder(dividingBy: 2) == 0 ? nil : $0 }
            #expect(try wire(pruned) == entry.member("pruned").asString().description)
            for (index, rollback) in [false, true].enumerated() {
                let ids = DefaultAtomIdAliasAllocator()
                _ = try ids.allocate(64)
                let inverse = try invertOptional(change, isRollback: rollback, allocator: ids, revision: revision)
                #expect(try wire(inverse) == entry.member("inverses").asArray()[index].asString().description)
            }
        }
    }
}
