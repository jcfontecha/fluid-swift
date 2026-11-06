import Foundation
import Testing
import FluidJS
import FluidIdCompressor
@testable import FluidTree

@Test func modularChunkAdapterRoundtripsConcreteNativeChunks() throws {
    let compressor = try IdCompressor("00000001-0000-4000-8000-000000000000")
    let chunk = try BasicChunk(json: JSON.parse(#"[{"type":"N","value":42,"fields":[]}]"#))
    let context = ModularCodecContext(revision: .root, originatorId: compressor.localSessionId)
    let adapter = ModularForestCodec(idCompressor: compressor, minimumClientVersion: .v2_80)
    let codec = try ModularChangeCodec(version: 5, revisionTagCodec: RevisionTagCodec(compressor), chunks: adapter)
    var change = ModularChangeset()
    change.builds = newChangeAtomIdBTree(context: change.context)
    change.builds?.set(ChangeAtomId(localId: 0, revision: .root), chunk)
    change.revisions = [RevisionInfo(revision: .root)]
    change.maxId = 0
    let encoded = try codec.encode(change, context: context)
    #expect(try encoded.member("builds").member("trees").member("version") == .number(2))
    let decoded = try codec.decode(encoded, context: context)
    let recovered = try #require(decoded.builds?.get(ChangeAtomId(localId: 0, revision: .root)) as? BasicChunk)
    #expect(recovered.json == chunk.json)
    #expect(try JSON.stringify(codec.encode(decoded, context: context)) == JSON.stringify(encoded))
}

@Test func modularDetachedChunksMatchThousandTypeScriptSeedsAtWriterGates() throws {
    let url = try #require(Bundle.module.url(forResource: "modular-chunks", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    let gates: [FluidClientVersion] = [.v2_0, .v2_43, .v2_80, .v2_117]
    let session = "00000001-0000-4000-8000-000000000000"
    for fixture in fixtures {
        let compressor = try IdCompressor(session)
        _ = try compressor.generateCompressedId()
        _ = try compressor.generateCompressedId()
        let revisions = RevisionTagCodec(compressor)
        let revision = try revisions.decode(fixture.member("revision"), originatorId: session)
        var change = ModularChangeset()
        change.maxId = 50
        change.revisions = [RevisionInfo(revision: revision)]
        change.builds = newChangeAtomIdBTree(context: change.context)
        change.refreshers = newChangeAtomIdBTree(context: change.context)
        func add(_ entry: JSONValue, to tree: ChangeAtomIdBTree<any TreeChunk>?) throws {
            let tag = try revisions.decode(entry.member("revision"), originatorId: session)
            let id = ChangeAtomId(localId: try entry.member("localId").asNumber(), revision: tag)
            tree?.set(id, try BasicChunk(json: entry.member("nodes")))
        }
        for entry in try fixture.member("entries").asArray() { try add(entry, to: change.builds) }
        try add(fixture.member("refresher"), to: change.refreshers)
        let context = ModularCodecContext(revision: revision, originatorId: session, isSummary: try fixture.member("isSummary") == .bool(true))
        for (index, row) in try fixture.member("rows").asArray().enumerated() {
            let adapter = ModularForestCodec(idCompressor: compressor, minimumClientVersion: gates[index])
            let codec = try ModularChangeCodec(version: row.member("version").asInt(), revisionTagCodec: revisions, chunks: adapter)
            let encoded = try codec.encode(change, context: context)
            #expect(try JSON.stringify(encoded) == row.member("wire").asString().description)
            let decoded = try codec.decode(encoded, context: context)
            #expect(try JSON.stringify(codec.encode(decoded, context: context)) == row.member("wire").asString().description)
            for (id, original) in change.builds?.entries ?? [] {
                let before = try #require(original as? BasicChunk)
                let after = try #require(decoded.builds?.get(id) as? BasicChunk)
                #expect(after.json == before.json)
            }
        }
    }
}

@Test func nativeBuildRollbackDestroysAndCancelsChunkRanges() throws {
    let family = ModularChangeFamily()
    let builder = family.buildEditor { _ in }
    let chunk = try BasicChunk(json: JSON.parse(#"[{"type":"N","fields":[]},{"type":"N","fields":[]}]"#))
    #expect(!chunk.isShared())
    let firstId = try builder.generateId(2)
    let build = try builder.buildChanges([builder.buildTrees(firstId: firstId, content: chunk, revision: .root)])
    #expect(chunk.isShared())
    let rollback = try family.invert(TaggedChange(change: build, revision: .root), isRollback: true, revision: .compressed(-1))
    #expect(rollback.destroys?.get(ChangeAtomId(localId: 0, revision: .root)) == 2)
    let cancelled = try family.compose([TaggedChange(change: build, revision: .root), TaggedChange(change: rollback, revision: .compressed(-1), rollbackOf: .root)])
    #expect(cancelled.builds == nil)
    #expect(cancelled.destroys == nil)
    #expect(try family.intoDelta(cancelled).fields == nil)
}

@Test func modularChunkAdapterPropagatesSummaryAndOriginatorContexts() throws {
    let compressor = try IdCompressor("00000001-0000-4000-8000-000000000000")
    let stable = try compressor.decompress(compressor.generateCompressedId())
    let schema = try TreeStoredSchema(json: JSON.parse(#"{"nodes":{"O":{"object":{"id":{"kind":"Identifier","types":["S"]}}},"S":{"leaf":1}},"root":{"kind":"Value","types":["O"]}}"#))
    let chunk = try BasicChunk(json: JSON.parse("[{\"type\":\"O\",\"fields\":[[\"id\",[{\"type\":\"S\",\"value\":\"\(stable)\",\"fields\":[]}]]]}]"))
    let adapter = ModularForestCodec(idCompressor: compressor, minimumClientVersion: .v2_80, schema: schema)
    let codec = try ModularChangeCodec(version: 5, revisionTagCodec: RevisionTagCodec(compressor), chunks: adapter)
    var change = ModularChangeset()
    change.builds = newChangeAtomIdBTree(context: change.context)
    change.builds?.set(ChangeAtomId(localId: 0, revision: .root), chunk)
    change.revisions = [RevisionInfo(revision: .root)]
    change.maxId = 0
    for summary in [false, true] {
        let context = ModularCodecContext(revision: .root, originatorId: compressor.localSessionId, isSummary: summary)
        let encoded = try codec.encode(change, context: context)
        #expect(JSON.stringify(encoded).contains(stable) == summary)
        let decoded = try codec.decode(encoded, context: context)
        let recovered = try #require(decoded.builds?.get(ChangeAtomId(localId: 0, revision: .root)) as? BasicChunk)
        #expect(recovered.json == chunk.json)
    }
}
