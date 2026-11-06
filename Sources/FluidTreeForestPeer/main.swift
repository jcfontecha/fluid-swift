import Foundation
import Darwin
import FluidJS
import FluidTree
import FluidIdCompressor

final class FixtureIncrementalEncoder: IncrementalEncoder {
    var chunks: [(Int, JSONValue)] = []
    var next = 0
    func shouldEncodeIncrementally(_ type: JSString, _ field: JSString?) -> Bool { field == "children" || field == "" }
    func encodeIncrementalField(_ content: BasicChunk, encode: (BasicChunk) throws -> JSONValue) throws -> [Int] {
        if content.topLevelLength == 0 { return [] }
        let reference = next
        next += 1
        let encoded = try encode(content)
        chunks.append((reference, encoded))
        return [reference]
    }
}

func run(_ scenario: JSONValue) throws -> [String] {
    let compressor = try IdCompressor("00000001-0000-4000-8000-000000000000")
    for _ in 0..<8 { _ = try compressor.generateCompressedId() }
    try compressor.finalizeCreationRange(compressor.takeNextCreationRange())
    let codec = FieldBatchCodec(idCompressor: compressor)
    let schema = try TreeStoredSchema(json: scenario.member("schema"))
    let fields = try scenario.member("fields").asArray().map { try BasicChunk(json: $0) }
    var rows: [String] = []
    for version: FieldBatchFormatVersion in [.v1, .v2, .vTextExperimental] {
        for compressed in [false, true] {
            let stored = compressed ? schema : nil
            let encoded = try codec.encode(fields, version: version, schema: stored)
            rows.append(JSON.stringify(encoded))
            do { rows.append(JSON.stringify(.array(try codec.decode(encoded).map(\.json)))) }
            catch let error as JSONDecodingError where error.description == "null stream token" { rows.append("decode-error:null-token") }
            for fv in [1, 2] {
                let forest = ForestCodec(fieldBatchCodec: codec)
                let pairs = fields.enumerated().map { (JSString("root\($0.offset)"), $0.element) }
                let summary = try forest.encode(pairs, version: fv, fieldVersion: version, schema: stored)
                rows.append(JSON.stringify(summary))

            }
        }
    }
    for version in [1, 2] { rows.append(JSON.stringify(try SchemaCodec().encode(schema, version: version))) }
    guard let numberType = schema.nodeSchema.first(where: { $0.0.description.hasPrefix("N") })?.0 else { throw JSONDecodingError("number type") }
    let seed = try scenario.member("seed").asInt()
    let uniformShape = try ChunkShape(treeShape: TreeShape(type: numberType, hasValue: true, fieldsArray: []), topLevelLength: 5)
    let uniform = try UniformChunk(shape: uniformShape, values: ContiguousArray((0..<5).map { .number(Double(seed + $0)) }))
    for version: FieldBatchFormatVersion in [.v1, .v2, .vTextExperimental] {
        let encoded = try codec.encode([uniform.materialize()], version: version, schema: schema)
        rows.append(JSON.stringify(encoded))
        rows.append(JSON.stringify(.array(try codec.decode(encoded).map(\.json))))
        if version != .v1 {
            let incremental = FixtureIncrementalEncoder()
            codec.incrementalEncoder = incremental
            let encoded = try codec.encode(fields, version: version, schema: schema)
            codec.incrementalEncoder = nil
            codec.incrementalChunks = Dictionary(uniqueKeysWithValues: incremental.chunks)
            rows.append(JSON.stringify(encoded))
            rows.append(JSON.stringify(.array(incremental.chunks.map { .array([.number(Double($0.0)), $0.1]) })))
            rows.append(JSON.stringify(.array(try codec.decode(encoded).map(\.json))))
        }
    }
    let unfinal = try IdCompressor("00000001-0000-4000-8000-000000000000")
    let stable = try unfinal.decompress(unfinal.generateCompressedId())
    let idSchema = try TreeStoredSchema(json: JSON.parse("{\"nodes\":{\"O\":{\"object\":{\"id\":{\"kind\":\"Identifier\",\"types\":[\"S\"]}}},\"S\":{\"leaf\":1}},\"root\":{\"kind\":\"Value\",\"types\":[\"O\"]}}"))
    let idTree = try BasicChunk(json: JSON.parse("[{\"type\":\"O\",\"fields\":[[\"id\",[{\"type\":\"S\",\"value\":\"\(stable)\",\"fields\":[]}]]]}]"))
    let idCodec = FieldBatchCodec(idCompressor: unfinal)
    idCodec.originatorSessionId = unfinal.localSessionId
    for version: FieldBatchFormatVersion in [.v1, .v2, .vTextExperimental] {
        for isSummary in [true, false] {
            idCodec.isSummary = isSummary
            let encoded = try idCodec.encode([idTree], version: version, schema: idSchema)
            rows.append(JSON.stringify(encoded))
            rows.append(JSON.stringify(.array(try idCodec.decode(encoded).map(\.json))))
        }
    }
    if let specialized = try scenario.asObject()["specialized"] {
        for batch in try specialized.asArray() { rows.append(JSON.stringify(.array(try codec.decode(batch).map(\.json)))) }
    }
    if let batches = try scenario.asObject()["decode"] {
        for job in try batches.asArray() {
            codec.originatorSessionId = try job.asObject()["originator"] == .bool(true) ? compressor.localSessionId : nil
            codec.incrementalChunks = [:]
            for pair in try job.member("chunks").asArray() {
                let entry = try pair.asArray()
                guard entry.count == 2 else { throw JSONDecodingError("chunk tuple") }
                codec.incrementalChunks[try entry[0].asInt()] = entry[1]
            }
            do { rows.append(JSON.stringify(.array(try codec.decode(job.member("encoded")).map(\.json)))) }
            catch let error as JSONDecodingError where error.description == "null stream token" { rows.append("decode-error:null-token") }
        }
    }
    if let forests = try scenario.asObject()["forestDecode"] {
        for text in try forests.asArray() {
            do {
                let forest = ForestCodec(fieldBatchCodec: codec)
                let fields = try forest.decode(JSON.parse(text.asString().description))
                rows.append(JSON.stringify(.array(fields.map { .array([.string($0.0), $0.1.json]) })))
            } catch let error as JSONDecodingError where error.description == "null stream token" { rows.append("decode-error:null-token") }
        }
    }
    if let schemas = try scenario.asObject()["schemaDecode"] {
        for (index, text) in try schemas.asArray().enumerated() {
            rows.append(JSON.stringify(try SchemaCodec().encode(SchemaCodec().decode(JSON.parse(text.asString().description)), version: index + 1)))
        }
    }
    return rows
}
setbuf(stdout, nil)
while let line = readLine() {
    do {
        let result = try run(JSON.parse(line))
        print(JSON.stringify(.array(result.map { .string(JSString($0)) })))
    } catch {
        FileHandle.standardError.write(Data("T2 error: \(error)\n".utf8))
        exit(1)
    }
}
