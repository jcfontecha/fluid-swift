import Foundation
import Testing
import FluidJS
import FluidIdCompressor
import FluidTree

@Test func identitiesMatchThousandRealTypeScriptScenarios() throws {
    let url = try #require(Bundle.module.url(forResource: "identities", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    for fixture in fixtures {
        let compressor = try IdCompressor("00000001-0000-4000-8000-000000000000")
        let codec = RevisionTagCodec(compressor)
        let atomCodec = ChangeAtomIdCodec(codec)
        let count = try fixture.member("count").asInt()
        var revisions: [RevisionTag] = []
        for _ in 0..<count {
            revisions.append(.compressed(try compressor.generateCompressedId()))
        }
        let revision = try #require(revisions.last)
        let first = try #require(revisions.first)
        let localId = try fixture.member("localId").asNumber()
        let atoms = [
            ChangeAtomId(localId: localId),
            ChangeAtomId(localId: localId, revision: revision),
            ChangeAtomId(localId: localId, revision: first),
            ChangeAtomId(localId: localId, revision: .root),
        ]
        for phase: JSString in ["before", "after"] {
            if phase == "after" {
                try compressor.finalizeCreationRange(compressor.takeNextCreationRange())
            }
            let encoded = try atoms.map { try atomCodec.encode($0, revision: revision) }
            #expect(JSON.stringify(.array(encoded)) == JSON.stringify(try fixture.member(phase)))
            for (atom, value) in zip(atoms, encoded) {
                let expected = ChangeAtomId(localId: atom.localId, revision: atom.revision ?? revision)
                #expect(try atomCodec.decode(value, revision: revision, originatorId: compressor.localSessionId) == expected)
            }
        }
        #expect(JSON.stringify(.array(try revisions.map { try codec.encode($0) })) == JSON.stringify(try fixture.member("revisions")))
    }
}
