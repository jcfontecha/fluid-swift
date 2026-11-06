import Testing
import FluidJS
import FluidIdCompressor
@testable import FluidTree

@Test func atomEnumerationDoesNotChangeIdentity() {
    let editor = ChangeAtomId(localId: 3, revision: .root)
    let detach = ChangeAtomId(localId: 3, revision: .root, propertyOrder: .revisionFirst)
    #expect(editor == detach)
    #expect(Set([editor, detach]).count == 1)
    #expect(atomStructure(editor) != atomStructure(detach))
}

@Test func detachConversionReappendsRevisionAfterEndpoint() throws {
    // Regression from full farm seed 324, association of cross-field moves.
    let mark = SequenceMark(count: 1, effect: .moveOut(id: 1, revision: .root, finalEndpoint: ChangeAtomId(localId: 0, revision: .compressed(-1)), idOverride: nil), cellId: ChangeAtomId(localId: 8, revision: .root))
    let (_, detach) = try mark.attachAndDetach()
    #expect(detach.propertyOrder == [.type, .id, .finalEndpoint, .revision])
    #expect(try detach.withFinalEndpoint(nil).propertyOrder == [.type, .id, .revision])
    let remove = SequenceFieldEditor().remove(0, count: 1, id: 0, revision: .root)
    #expect(remove.first?.propertyOrder == [.type, .count, .id, .revision])
}

@Test func legacyAttachDetachDecodeUsesFreshNormalizedObjectOrder() throws {
    let session = "00000001-0000-4000-8000-000000000000"
    let codec = try SequenceFieldCodec(version: 2, revisionTagCodec: RevisionTagCodec(try IdCompressor(session)))
    let wire = try JSON.parse(#"[{"count":1,"effect":{"attachAndDetach":{"attach":{"insert":{"id":0}},"detach":{"remove":{"id":1}}}},"cellId":0}]"#)
    let marks = try codec.decode(wire, revision: .root, originatorId: session) { _ in ChangeAtomId(localId: 0) }
    #expect(marks.first?.propertyOrder == [.type, .id, .revision, .count, .cellId])
}

@Test func anonymousRollbackPreservesExplicitUndefinedRevisionMetadata() throws {
    let inverse = try ModularChangeFamily().invert(TaggedChange(change: ModularChangeset()), isRollback: true, revision: .root)
    #expect(inverse.revisions?.first?.includesRollbackOf == true)
    #expect(try JSON.stringify(modularStructure(inverse)).contains(#"["rollbackOf",["undefined"]]"#))
}

@Test func pruningPreservesInvertedNodePropertyOrder() throws {
    let context = BTreeStorageContext()
    var change = ModularChangeset(context: context)
    let child = ChangeAtomId(localId: 0, revision: .root)
    change.fieldChanges["a"] = FieldChange(fieldKind: .generic, change: .generic(newGenericChangeset([(0, child)], context: context)))
    let fields = FieldChangeMap()
    fields["child"] = FieldChange(fieldKind: .optional, change: .optional(OptionalFieldEditor().clear(wasEmpty: false, detachId: ChangeAtomId(localId: 8, revision: .root))))
    change.nodeChanges.set(child, NodeChangeset(fieldChanges: fields, nodeExistsConstraint: .init(violated: false)))
    change.maxId = 63
    change.revisions = [RevisionInfo(revision: .root)]
    try makeChangesetInversions(&change)
    let inverse = try ModularChangeFamily(context: context).invert(TaggedChange(change: change, revision: .root), isRollback: false, revision: .compressed(-1))
    #expect(inverse.nodeChanges.get(child)?.propertyOrder == [.nodeExistsConstraintOnRevert, .fieldChanges])
    let pruned = try pruneModularChangeset(inverse)
    #expect(pruned.nodeChanges.get(child)?.propertyOrder == [.nodeExistsConstraintOnRevert, .fieldChanges])
}
