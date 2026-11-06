import Foundation
import Testing
import FluidJS
import FluidIdCompressor
@testable import FluidTree

@Test func modularCodecReconstructsNestedNodeAndCrossFieldTables() throws {
    let session = "00000001-0000-4000-8000-000000000000"
    let revisions = RevisionTagCodec(try IdCompressor(session))
    let wire = #"{"maxId":64,"changes":[{"fieldKey":"a","fieldKind":"ModularEditBuilder.Generic","change":[[2,{"fieldChanges":[{"fieldKey":"children","fieldKind":"Sequence","change":[{"count":1,"effect":{"insert":{"id":0}},"cellId":0}]}]}]]}]}"#
    for version in [3, 4, 5] {
        let codec = try ModularChangeCodec(version: version, revisionTagCodec: revisions)
        let context = ModularCodecContext(revision: .root, originatorId: session)
        let decoded = try codec.decode(JSON.parse(wire), context: context)
        let node = ChangeAtomId(localId: 65, revision: .root)
        #expect(decoded.nodeChanges.has(node))
        #expect(decoded.nodeToParent.get(node) == FieldId(field: "a"))
        #expect(decoded.crossFieldKeys.getFirst(CrossFieldKey(target: .source, revision: .root, localId: 0), count: 1).value == FieldId(nodeId: node, field: "children"))
        #expect(try JSON.stringify(codec.encode(decoded, context: context)) == wire)
    }
}

@Test func modularCodecHonorsRevisionContextAndConstraintVersion() throws {
    let session = "00000001-0000-4000-8000-000000000000"
    let revisions = RevisionTagCodec(try IdCompressor(session))
    var change = ModularChangeset()
    change.revisions = [RevisionInfo(revision: .root, rollbackOf: .root)]
    change.noChangeConstraint = NoChangeConstraint(violated: true)
    let codec = try ModularChangeCodec(version: 5, revisionTagCodec: revisions)
    #expect(throws: (any Error).self) { try codec.encode(change, context: ModularCodecContext(revision: .root, originatorId: session)) }
    #expect(try JSON.stringify(codec.encode(change, context: ModularCodecContext(originatorId: session))) == #"{"revisions":[{"revision":"root","rollbackOf":"root"}],"changes":[],"noChangeConstraint":{"violated":true}}"#)
}

@Test func modularCodecsMatchThousandTypeScriptSeedsAtEveryWriterGate() throws {
    let url = try #require(Bundle.module.url(forResource: "modular-codecs", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    let session = "00000001-0000-4000-8000-000000000000"
    for fixture in fixtures {
        let compressor = try IdCompressor(session)
        for _ in 0..<(try fixture.member("revisionCount").asInt()) { _ = try compressor.generateCompressedId() }
        let revisions = RevisionTagCodec(compressor)
        let storage = BTreeStorageContext()
        let changes = try fixture.member("changes").asArray()
        #expect(changes.count == 8)
        for change in changes {
            let revision = try revisions.decode(change.member("revision"), originatorId: session)
            let context = ModularCodecContext(revision: revision, originatorId: session)
            let wires = try change.member("wires").asArray()
            #expect(wires.count == 4)
            for wire in wires {
                let codec = try ModularChangeCodec(version: wire.member("version").asInt(), revisionTagCodec: revisions, storageContext: storage)
                let bytes = try wire.member("bytes").asString().description
                let decoded = try codec.decode(JSON.parse(bytes), context: context)
                #expect(try JSON.stringify(codec.encode(decoded, context: context)) == bytes)
            }
            let algebraCodec = try ModularChangeCodec(version: 5, revisionTagCodec: revisions, storageContext: storage)
            let algebraContext = ModularCodecContext(originatorId: session)
            let bytes = try change.member("algebra").asString().description
            let decoded = try algebraCodec.decode(JSON.parse(bytes), context: algebraContext)
            #expect(try JSON.stringify(algebraCodec.encode(decoded, context: algebraContext)) == bytes)
        }
    }
}

@Test func modularCodecRejectsNonScalarMaximumId() throws {
    let session = "00000001-0000-4000-8000-000000000000"
    let codec = try ModularChangeCodec(version: 5, revisionTagCodec: RevisionTagCodec(try IdCompressor(session)))
    #expect(throws: (any Error).self) {
        try codec.decode(JSON.parse(#"{"maxId":[64,"root"],"changes":[]}"#), context: ModularCodecContext(originatorId: session))
    }
}
