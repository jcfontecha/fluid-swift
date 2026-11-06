import Foundation
import FluidIdCompressor
import Testing
import FluidJS
@testable import FluidTree

@Test func modularInverseAmendsDestinationProcessedBeforeSource() throws {
    let context = BTreeStorageContext()
    var change = ModularChangeset(context: context)
    let child = ChangeAtomId(localId: 50, revision: .root)
    let destination = SequenceFieldEditor().moveIn(0, count: 1, moveId: 0, attachCellId: ChangeAtomId(localId: 8, revision: .root), revision: .root)
    var source = SequenceFieldEditor().moveOut(0, count: 1, id: 0, revision: .root)
    source[0].changes = child
    change.fieldChanges["destination"] = FieldChange(fieldKind: .sequence, change: .sequence(destination))
    change.fieldChanges["source"] = FieldChange(fieldKind: .sequence, change: .sequence(source))
    change.nodeChanges.set(child, NodeChangeset(nodeExistsConstraint: .init(violated: false)))
    change.maxId = 63
    change.revisions = [RevisionInfo(revision: .root)]
    let inverse = try ModularChangeFamily(context: context).invert(TaggedChange(change: change, revision: .root), isRollback: false, revision: .compressed(-1))
    guard case .sequence(let marks) = inverse.fieldChanges["destination"]?.change else {
        Issue.record("missing destination")
        return
    }
    #expect(marks.first?.changes == child)
    #expect(inverse.nodeToParent.get(child) == FieldId(field: "destination"))
    #expect(inverse.nodeChanges.get(child)?.nodeExistsConstraintOnRevert?.violated == false)
}

@Test func modularRebaseFollowsMoveIntoPreviouslyUnchangedField() throws {
    let context = BTreeStorageContext()
    let editor = SequenceFieldEditor()
    var base = ModularChangeset(context: context)
    base.fieldChanges["a"] = FieldChange(fieldKind: .sequence, change: .sequence(editor.moveOut(0, count: 1, id: 0, revision: .root)))
    base.fieldChanges["b"] = FieldChange(fieldKind: .sequence, change: .sequence(editor.moveIn(0, count: 1, moveId: 0, attachCellId: ChangeAtomId(localId: 8, revision: .root), revision: .root)))
    base.maxId = 63
    base.revisions = [RevisionInfo(revision: .root)]
    try makeChangesetInversions(&base)
    var change = ModularChangeset(context: context)
    change.fieldChanges["a"] = FieldChange(fieldKind: .sequence, change: .sequence(editor.remove(0, count: 1, id: 0, revision: .compressed(-1))))
    change.maxId = 63
    change.revisions = [RevisionInfo(revision: .compressed(-1))]
    let family = ModularChangeFamily(context: context)
    let result = try family.rebase(TaggedChange(change: change, revision: .compressed(-1)), over: TaggedChange(change: base, revision: .root), metadata: RevisionMetadataSource([RevisionInfo(revision: .root), RevisionInfo(revision: .compressed(-1))]))
    #expect(result.fieldChanges["a"] == nil)
    guard case .sequence(let marks) = result.fieldChanges["b"]?.change else {
        Issue.record("remove did not follow moved node")
        return
    }
    #expect(marks == editor.remove(0, count: 1, id: 0, revision: .compressed(-1)))
}

@Test func modularInvertAndRebaseMatchThousandTypeScriptSeeds() throws {
    let url = try #require(Bundle.module.url(forResource: "modular-family", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    let session = "00000001-0000-4000-8000-000000000000"
    for fixture in fixtures {
        let compressor = try IdCompressor(session)
        for _ in 0..<(try fixture.member("revisionCount").asInt()) { _ = try compressor.generateCompressedId() }
        let revisions = RevisionTagCodec(compressor)
        let storage = BTreeStorageContext()
        let codec = try ModularChangeCodec(version: 5, revisionTagCodec: revisions, storageContext: storage)
        let family = ModularChangeFamily(context: storage)
        let outputContext = ModularCodecContext(originatorId: session)
        func tag(_ value: JSONValue) throws -> RevisionTag { try revisions.decode(value, originatorId: session) }
        func decode(_ value: JSONValue, revision: RevisionTag) throws -> TaggedChange<ModularChangeset> {
            TaggedChange(change: try codec.decode(JSON.parse(value.asString().description), context: ModularCodecContext(revision: revision, originatorId: session)), revision: revision)
        }
        let inversions = try fixture.member("inversions").asArray()
        #expect(inversions.count == 8)
        for input in inversions {
            let revision = try tag(input.member("revision"))
            let change = try decode(input.member("wire"), revision: revision)
            for (index, expected) in try input.member("results").asArray().enumerated() {
                let result = try family.invert(change, isRollback: index == 1, revision: tag(expected.member("revision")))
                #expect(try JSON.stringify(codec.encode(result, context: outputContext)) == expected.member("wire").asString().description)
            }
        }
        let rebases = try fixture.member("rebases").asArray()
        #expect(rebases.count == 8)
        for input in rebases {
            let revision = try tag(input.member("revision"))
            let baseRevision = try tag(input.member("baseRevision"))
            let change = try decode(input.member("change"), revision: revision)
            let base = try decode(input.member("base"), revision: baseRevision)
            let metadata = RevisionMetadataSource([RevisionInfo(revision: baseRevision), RevisionInfo(revision: revision)])
            let result = try family.rebase(change, over: base, metadata: metadata)
            #expect(try JSON.stringify(codec.encode(result, context: outputContext)) == input.member("result").asString().description)
            let composed = try family.compose([base, TaggedChange(change: result, revision: revision)])
            #expect(try JSON.stringify(codec.encode(composed, context: outputContext)) == input.member("composed").asString().description)
        }
    }
}

@Test func modularComposeCarriesChildChangesBackThroughCrossFieldMove() throws {
    let context = BTreeStorageContext()
    let editor = SequenceFieldEditor()
    var move = ModularChangeset(context: context)
    move.fieldChanges["a"] = FieldChange(fieldKind: .sequence, change: .sequence(editor.moveOut(0, count: 1, id: 0, revision: .root)))
    move.fieldChanges["b"] = FieldChange(fieldKind: .sequence, change: .sequence(editor.moveIn(0, count: 1, moveId: 0, attachCellId: ChangeAtomId(localId: 8, revision: .root), revision: .root)))
    move.maxId = 63
    move.revisions = [RevisionInfo(revision: .root)]
    try makeChangesetInversions(&move)
    let child = ChangeAtomId(localId: 50, revision: .compressed(-1))
    var edit = ModularChangeset(context: context)
    edit.fieldChanges["b"] = FieldChange(fieldKind: .generic, change: .generic(newGenericChangeset([(0, child)], context: context)))
    edit.nodeChanges.set(child, NodeChangeset(nodeExistsConstraint: .init(violated: false)))
    edit.maxId = 63
    edit.revisions = [RevisionInfo(revision: .compressed(-1))]
    try makeChangesetInversions(&edit)
    let result = try ModularChangeFamily(context: context).compose([TaggedChange(change: move), TaggedChange(change: edit)])
    guard case .sequence(let source) = result.fieldChanges["a"]?.change else {
        Issue.record("missing source")
        return
    }
    #expect(source.first?.changes == child)
    #expect(result.nodeToParent.get(child) == FieldId(field: "a"))
}

@Test func modularDeltaAndRevisionReplacementTraverseNestedNodes() throws {
    let family = ModularChangeFamily()
    let builder = family.buildEditor { _ in }
    _ = try builder.generateId(64)
    let path = FieldUpPath(parent: UpPath(parentField: "a", parentIndex: 2), field: "children")
    let inserted = SequenceFieldEditor().insert(0, count: 1, firstId: ChangeAtomId(localId: 0, revision: .root), revision: .root)
    let change = try builder.buildChanges([.field(path: path, change: FieldChange(fieldKind: .sequence, change: .sequence(inserted)), revision: .root)])
    let delta = try family.intoDelta(change)
    #expect(delta.fields?["a"]?.marks.map(\.count) == [2, 1])
    #expect(delta.fields?["a"]?.marks.last?.fields?["children"]?.marks.first?.attach == DeltaDetachedNodeId(ChangeAtomId(localId: 0, revision: .root)))
    #expect(try family.relevantRemovedRoots(change) == [DeltaDetachedNodeId(ChangeAtomId(localId: 0, revision: .root))])
    let replacer = DefaultRevisionReplacer(updatedRevision: .compressed(-1), obsoleteRevisions: [.root])
    let replaced = try family.changeRevision(change, replacer: replacer)
    #expect(replaced.revisions == [RevisionInfo(revision: .compressed(-1))])
    #expect(replaced.nodeChanges.has(ChangeAtomId(localId: 64, revision: .compressed(-1))))
    #expect(replaced.nodeAliases.isEmpty)
}
