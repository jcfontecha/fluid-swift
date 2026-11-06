import Foundation
import Testing
import FluidJS
import FluidIdCompressor
@testable import FluidTree

@Test func sequenceCodecPreservesWireOrderingAndImplicitRevision() throws {
    let session = "00000001-0000-4000-8000-000000000000"
    let revisionCodec = RevisionTagCodec(try IdCompressor(session))
    for version in [2, 3] {
        let codec = try SequenceFieldCodec(version: version, revisionTagCodec: revisionCodec)
        let atom = ChangeAtomId(localId: 7, revision: .root)
        let marks = [SequenceMark(count: 2), SequenceMark(count: 1,
            effect: .moveOut(id: 3, revision: .root, finalEndpoint: atom, idOverride: atom), cellId: atom, changes: atom)]
        let encoded = try codec.encode(marks, revision: .root) { .number($0.localId) }
        #expect(JSON.stringify(encoded) == "[{\"count\":2},{\"count\":1,\"effect\":{\"moveOut\":{\"finalEndpoint\":7,\"idOverride\":7,\"id\":3}},\"cellId\":7,\"changes\":7}]")
        #expect(try codec.decode(encoded, revision: .root, originatorId: session) { ChangeAtomId(localId: try $0.asNumber(), revision: .root) } == marks)
    }
}

@Test func sequenceCodecRenameCompatibilityAndMalformedData() throws {
    let session = "00000001-0000-4000-8000-000000000000"
    let revisionCodec = RevisionTagCodec(try IdCompressor(session))
    let mark = SequenceMark(count: 1, effect: .rename(idOverride: ChangeAtomId(localId: 9, revision: .root)), cellId: ChangeAtomId(localId: 4, revision: .root))
    for version in [2, 3] {
        let codec = try SequenceFieldCodec(version: version, revisionTagCodec: revisionCodec)
        let encoded = try codec.encode([mark], revision: .root) { _ in .null }
        #expect(try codec.decode(encoded, revision: .root, originatorId: session) { _ in ChangeAtomId(localId: 0) } == [mark])
        #expect(throws: (any Error).self) {
            try codec.decode(try JSON.parse("[{\"count\":1,\"effect\":{\"insert\":{\"id\":0}}}]"), revision: nil, originatorId: session) { _ in ChangeAtomId(localId: 0) }
        }
    }
}

@Test func sequenceCodecsMatchThousandTypeScriptFixtures() throws {
    let session = "00000001-0000-4000-8000-000000000000"
    let compressor = try IdCompressor(session)
    let revision = RevisionTag.compressed(try compressor.generateCompressedId())
    let revisionCodec = RevisionTagCodec(compressor)
    let url = try #require(Bundle.module.url(forResource: "sequence-codecs", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    for fixture in fixtures {
        for entry in try fixture.asArray() {
            let codec = try SequenceFieldCodec(version: entry.member("version").asInt(), revisionTagCodec: revisionCodec)
            let wire = try entry.member("wire").asString()
            let marks = try codec.decode(JSON.parse(wire.description), revision: revision, originatorId: session) { ChangeAtomId(localId: try $0.asNumber()) }
            #expect(try JSON.stringify(codec.encode(marks, revision: revision) { .number($0.localId) }) == wire.description)
        }
    }
}
