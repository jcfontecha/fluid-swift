import Testing
import FluidJS
@testable import FluidTree

@Suite struct ChunkedForestCodecTests {
    @Test func uncompressedGolden() throws {
        let chunk = try BasicChunk(json: JSON.parse("[{\"type\":\"N\",\"value\":42,\"fields\":[]}]"))
        let codec = FieldBatchCodec()
        let encoded = try codec.encode([chunk], version: .v1)
        #expect(JSON.stringify(encoded) == "{\"version\":1,\"identifiers\":[],\"shapes\":[{\"c\":{\"extraFields\":1}},{\"a\":0}],\"data\":[[1,[\"N\",true,42,[]]]]}")
        #expect(try codec.decode(encoded).map { $0.json } == [chunk.json])
    }
    @Test func rejectsTruncatedStream() throws {
        let bad = try JSON.parse("{\"version\":1,\"identifiers\":[],\"shapes\":[{\"c\":{}}],\"data\":[[0,\"N\"]]}")
        #expect(throws: (any Error).self) { try FieldBatchCodec().decode(bad) }
    }
    @Test func specializedCycle() throws {
        let bad = try JSON.parse("{\"version\":\"text\",\"identifiers\":[],\"shapes\":[{\"f\":{\"base\":0}}],\"data\":[[0]]}")
        #expect(throws: (any Error).self) { try FieldBatchCodec().decode(bad) }
    }
    @Test func schemaSorted() throws {
        let schema = try TreeStoredSchema(json: JSON.parse("{\"nodes\":{\"z\":{\"leaf\":1},\"a\":{\"leaf\":0}},\"root\":{\"kind\":\"Sequence\",\"types\":[\"z\",\"a\"]}}"))
        #expect(try JSON.stringify(SchemaCodec().encode(schema, version: 1)) == "{\"version\":1,\"nodes\":{\"a\":{\"leaf\":0},\"z\":{\"leaf\":1}},\"root\":{\"kind\":\"Sequence\",\"types\":[\"a\",\"z\"]}}")
    }
}

@Suite struct ChunkedForestShapeTests {
    @Test func specializedFieldsAndConstantValues() throws {
        let encoded = try JSON.parse("{\"version\":\"text\",\"identifiers\":[\"T\",\"x\"],\"shapes\":[{\"c\":{\"type\":0,\"value\":false,\"fields\":[[1,1]]}},{\"b\":{\"length\":0,\"shape\":1}},{\"f\":{\"base\":0,\"value\":[42],\"fields\":[[1,3]]}},{\"c\":{\"type\":\"N\",\"value\":[7]}}],\"data\":[[2]]}")
        let chunks = try FieldBatchCodec().decode(encoded)
        #expect(chunks.count == 1)
        #expect(JSON.stringify(chunks[0].json) == "[{\"type\":\"T\",\"value\":42,\"fields\":[[\"x\",[{\"type\":\"N\",\"value\":7,\"fields\":[]}]]]}]")
    }
    @Test func zeroTokenNestedRun() throws {
        let batch = try JSON.parse("{\"version\":2,\"identifiers\":[],\"shapes\":[{\"a\":1},{\"c\":{\"type\":\"N\",\"value\":[null]}}],\"data\":[[0,4]]}")
        let chunk = try FieldBatchCodec().decode(batch)[0]
        #expect(chunk.topLevelLength == 4)
        #expect(chunk.values.allSatisfy { $0 == .null })
    }
    @Test func forestLengthMismatch() throws {
        let forest = try JSON.parse("{\"version\":1,\"keys\":[\"a\"],\"fields\":{\"version\":1,\"identifiers\":[],\"shapes\":[],\"data\":[]}}")
        #expect(throws: (any Error).self) { try ForestCodec(fieldBatchCodec: FieldBatchCodec()).decode(forest) }
    }
    @Test func uniformColumns() throws {
        let shape = try ChunkShape(treeShape: TreeShape(type: "N", hasValue: true, fieldsArray: []), topLevelLength: 3)
        let uniform = try UniformChunk(shape: shape, values: [.number(1), .number(2), .number(3)])
        let materialized = try uniform.materialize()
        #expect(materialized.types == ["N", "N", "N"])
        #expect(materialized.values == [.number(1), .number(2), .number(3)])
        #expect(throws: (any Error).self) { try UniformChunk(shape: shape, values: []) }
    }
    @Test func rawNullMatchesOracleRejection() throws {
        let chunk = try BasicChunk(json: JSON.parse("[{\"type\":\"Z\",\"value\":null,\"fields\":[]}]"))
        let codec = FieldBatchCodec()
        #expect(throws: (any Error).self) { try codec.decode(codec.encode([chunk], version: .v1)) }
    }
}

import FluidIdCompressor

@Suite struct ChunkedForestIdentifierTests {
    @Test func unfinalizedIdentifiersRequireOriginatorInOps() throws {
        let compressor = try IdCompressor("00000001-0000-4000-8000-000000000000")
        let id = try compressor.generateCompressedId()
        let stable = try compressor.decompress(id)
        let repo = try TreeStoredSchema(json: JSON.parse("{\"nodes\":{\"O\":{\"object\":{\"id\":{\"kind\":\"Identifier\",\"types\":[\"S\"]}}},\"S\":{\"leaf\":1}},\"root\":{\"kind\":\"Value\",\"types\":[\"O\"]}}"))
        let chunk = try BasicChunk(json: JSON.parse("[{\"type\":\"O\",\"fields\":[[\"id\",[{\"type\":\"S\",\"value\":\"\(stable)\",\"fields\":[]}]]]}]"))
        let codec = FieldBatchCodec(idCompressor: compressor)
        for version: FieldBatchFormatVersion in [.v1, .v2, .vTextExperimental] {
            let summary = try codec.encode([chunk], version: version, schema: repo)
            #expect(JSON.stringify(summary).contains(stable))
            codec.isSummary = false
            let op = try codec.encode([chunk], version: version, schema: repo)
            #expect(!JSON.stringify(op).contains(stable))
            #expect(throws: (any Error).self) { try codec.decode(op) }
            codec.originatorSessionId = compressor.localSessionId
            #expect(try codec.decode(op).map(\.json) == [chunk.json])
            codec.originatorSessionId = nil
            codec.isSummary = true
        }
    }
}

@Suite struct ChunkedForestContextTests {
    @Test func explicitContextsDispatchReadVersionsAndRejectV1IncrementalWrites() throws {
        let compressor = try IdCompressor("00000001-0000-4000-8000-000000000000")
        let chunk = try BasicChunk(json: JSON.parse("[{\"type\":\"N\",\"value\":42,\"fields\":[]}]"))
        let context = FieldBatchEncodingContext(encodeType: .uncompressed, idCompressor: compressor, isSummary: true)
        let codec = FieldBatchCodec()
        for version: FieldBatchFormatVersion in [.v1, .v2, .vTextExperimental] {
            let encoded = try codec.encode([chunk], context: context, version: version)
            #expect(try codec.decode(encoded, context: .forSummary(idCompressor: compressor)).map(\.json) == [chunk.json])
        }
        let incremental = FieldBatchEncodingContext(encodeType: .compressedIncremental, idCompressor: compressor, isSummary: true)
        #expect(throws: (any Error).self) { try codec.encode([chunk], context: incremental, version: .v1) }
    }
}

@Suite struct ChunkedForestArrayValidationTests {
    @Test func emptyArraysStillValidateInnerShapeIndex() throws {
        for text in ["{\"version\":1,\"identifiers\":[],\"shapes\":[{\"a\":1}],\"data\":[[0,0]]}", "{\"version\":1,\"identifiers\":[],\"shapes\":[{\"b\":{\"length\":0,\"shape\":1}}],\"data\":[[0]]}"] {
            #expect(throws: (any Error).self) { try FieldBatchCodec().decode(JSON.parse(text)) }
        }
    }
}
