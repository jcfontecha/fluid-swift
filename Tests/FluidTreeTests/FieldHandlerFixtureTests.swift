import Foundation
import Testing
import FluidJS
import FluidIdCompressor
@testable import FluidTree

private struct HandlerFixtureCodec {
    let session = "00000001-0000-4000-8000-000000000000"
    let revision: RevisionTag
    let revisions: RevisionTagCodec
    let atoms: ChangeAtomIdCodec
    init() throws {
        let compressor = try IdCompressor(session)
        revision = .compressed(try compressor.generateCompressedId())
        revisions = RevisionTagCodec(compressor)
        atoms = ChangeAtomIdCodec(revisions)
    }
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
    func atom(_ value: JSONValue) throws -> ChangeAtomId {
        let object = try value.asObject()
        return ChangeAtomId(localId: try value.member("localId").asNumber(), revision: try object["revision"].map { try revisions.decode($0, originatorId: session) })
    }
    func root(_ value: JSONValue) throws -> DeltaDetachedNodeId {
        let object = try value.asObject()
        return DeltaDetachedNodeId(ChangeAtomId(localId: try value.member("minor").asNumber(), revision: try object["major"].map { try revisions.decode($0, originatorId: session) }))
    }
    func fields(_ value: JSONValue) throws -> DeltaFieldMap {
        var result = DeltaFieldMap()
        for entry in try value.asArray() {
            let pair = try entry.asArray()
            guard pair.count == 2 else { throw JSONDecodingError("expected field pair") }
            result[try pair[0].asString()] = try local(pair[1])
        }
        return result
    }
    func local(_ value: JSONValue) throws -> DeltaFieldChanges {
        DeltaFieldChanges(marks: try value.member("marks").asArray().map { value in
            let object = try value.asObject()
            return DeltaMark(count: try value.member("count").asInt(), fields: try object["fields"].map(fields), detach: try object["detach"].map(root), attach: try object["attach"].map(root))
        })
    }
    func delta(_ value: JSONValue) throws -> FieldChangeDelta {
        let object = try value.asObject()
        var result = FieldChangeDelta()
        result.local = try object["local"].map(local)
        result.global = try object["global"].map { value in
            try value.asArray().map { value in DeltaDetachedNodeChanges(id: try root(value.member("id")), fields: try fields(value.member("fields"))) }
        }
        result.rename = try object["rename"].map { value in
            try value.asArray().map { value in DeltaDetachedNodeRename(count: try value.member("count").asInt(), oldId: try root(value.member("oldId")), newId: try root(value.member("newId"))) }
        }
        return result
    }
    func nested(_ value: JSONValue) throws -> [ChildChangeInfo] {
        try value.asArray().map { value in
            let object = try value.asObject()
            return ChildChangeInfo(nodeId: try atom(value.member("nodeId")), inputRootId: try object["inputRootId"].map(atom), detachId: try object["detachId"].map(atom))
        }
    }
    func keys(_ value: JSONValue) throws -> [CrossFieldKeyRange] {
        try value.asArray().map { value in
            let key = try value.member("key")
            let id = try atom(key)
            let target = try key.member("target").asInt()
            guard target == 0 || target == 1 else { throw JSONDecodingError("invalid cross-field target") }
            return CrossFieldKeyRange(key: CrossFieldKey(target: target == 0 ? .source : .destination, revision: id.revision, localId: id.localId), count: try value.member("count").asInt())
        }
    }
}

@Test func fieldHandlersMatchThousandTypeScriptFixtures() throws {
    let context = try HandlerFixtureCodec()
    let seqCodec = try SequenceFieldCodec(version: 3, revisionTagCodec: context.revisions)
    let optCodec = OptionalFieldCodec(context.revisions)
    let seqHandler = SequenceFieldChangeHandler()
    let optHandler = OptionalChangeHandler()
    let url = try #require(Bundle.module.url(forResource: "field-handlers", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    func fromChild(_ id: ChangeAtomId) -> DeltaFieldMap {
        var fields = DeltaFieldMap()
        fields["child"] = DeltaFieldChanges(marks: [DeltaMark(count: 1, detach: DeltaDetachedNodeId(id))])
        return fields
    }
    for entry in fixtures {
        func json(_ key: JSString) throws -> JSONValue { try JSON.parse(entry.member(key).asString().description) }
        let sequence = try seqCodec.decode(json("sequence"), revision: context.revision, originatorId: context.session, decodeNode: context.decodeNode)
        let optional = try optCodec.decode(json("optional"), revision: context.revision, originatorId: context.session, decodeNode: context.decodeNode)
        #expect(try seqHandler.intoDelta(sequence, fromChild: fromChild) == context.delta(json("sequenceDelta")))
        #expect(try optHandler.intoDelta(optional, fromChild: fromChild) == context.delta(json("optionalDelta")))
        #expect(try seqHandler.relevantRemovedRoots(sequence) { [DeltaDetachedNodeId($0)] } == json("sequenceRoots").asArray().map(context.root))
        #expect(try optHandler.relevantRemovedRoots(optional) { [DeltaDetachedNodeId($0)] } == json("optionalRoots").asArray().map(context.root))
        #expect(try seqHandler.getNestedChanges(sequence) == context.nested(json("sequenceNested")))
        #expect(try optHandler.getNestedChanges(optional) == context.nested(json("optionalNested")))
        #expect(try seqHandler.getCrossFieldKeys(sequence) == context.keys(json("sequenceKeys")))
        let pruned = pruneSequence(sequence) { _ in nil }
        #expect(try JSON.stringify(seqCodec.encode(pruned, revision: context.revision, encodeNode: context.encodeNode)) == entry.member("sequencePruned").asString().description)
        let replacer = DefaultRevisionReplacer(updatedRevision: context.revision, obsoleteRevisions: [.root])
        let replaced = try replaceSequenceRevisions(sequence, replacer: replacer)
        #expect(try JSON.stringify(seqCodec.encode(replaced, revision: context.revision, encodeNode: context.encodeNode)) == entry.member("sequenceReplaced").asString().description)
        let preserve = try entry.member("preserveOtherEdits") == .bool(true)
        let action: EditFilterStatus
        switch try entry.member("filterAction").asInt() {
        case 0: action = .remove
        case 1: action = .preserve
        case 2: action = .preserveWithoutMove
        default: throw JSONDecodingError("invalid filter status")
        }
        let detach: FilterDetachFunc = { _, count, _, _ in .init(length: min(count, 1), value: .init(action: action, shouldRemoveChild: true)) }
        let attach: FilterAttachFunc = { _, count, _, _ in .init(length: min(count, 1), value: .init(action: action, nodeId: ChangeAtomId(localId: 50, revision: .root), newAttachId: ChangeAtomId(localId: 90, revision: .root))) }
        let filteredSeq = try filterSequence(sequence, preserveOtherEdits: preserve, filterDetach: detach, filterAttach: attach)
        let filteredOpt = try filterOptional(optional, preserveOtherEdits: preserve, filterDetach: detach, filterAttach: attach)
        #expect(try JSON.stringify(seqCodec.encode(filteredSeq, revision: context.revision, encodeNode: context.encodeNode)) == entry.member("sequenceFiltered").asString().description)
        #expect(try JSON.stringify(optCodec.encode(filteredOpt, revision: context.revision, encodeNode: context.encodeNode)) == entry.member("optionalFiltered").asString().description)
    }
}
