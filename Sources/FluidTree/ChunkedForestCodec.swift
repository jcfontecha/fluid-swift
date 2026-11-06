import FluidJS
import FluidIdCompressor

/// Ports codec/chunkCodecUtilities.ts.
struct StreamCursor {
    let data: [JSONValue]
    var offset = 0
    mutating func read() throws -> JSONValue {
        try forestCheck(offset < data.count, "0x730 truncated stream")
        defer { offset += 1 }
        try forestCheck(data[offset] != .null, "null stream token")
        return data[offset]
    }
}
/// Ports codec/codecs.ts. Dispatches read versions independently of the write version.
public final class FieldBatchCodec {
    public let idCompressor: IdCompressor?
    public var isSummary = true
    public var originatorSessionId: String?
    public var incrementalDecoder: (any IncrementalDecoder)?
    public var incrementalEncoder: (any IncrementalEncoder)?
    public var incrementalChunks: [Int: JSONValue] = [:]
    public init(idCompressor: IdCompressor? = nil) { self.idCompressor = idCompressor }
    public func encode(_ batch: [BasicChunk], version: FieldBatchFormatVersion, schema: TreeStoredSchema? = nil) throws -> JSONValue {
        if let schema { return try EncoderContext(schema: schema, compressor: idCompressor, incrementalEncoder: version == .v1 ? nil : incrementalEncoder, isSummary: isSummary).encode(batch, version: version) }
        func sequence(_ chunk: BasicChunk, _ nodes: [Int]) -> JSONValue {
            var data: [JSONValue] = []
            for node in nodes {
                data.append(.string(chunk.types[node]))
                data.append(.bool(chunk.values[node] != nil))
                if let value = chunk.values[node] { data.append(value) }
                var fields: [JSONValue] = []
                for (key, children) in chunk.fields(node) {
                    fields.append(.string(key))
                    fields.append(sequence(chunk, children))
                }
                data.append(.array(fields))
            }
            return .array(data)
        }
        return forestObject([("version", version.json), ("identifiers", .array([])), ("shapes", .array([forestObject([("c", forestObject([("extraFields", .number(1))]))]), forestObject([("a", .number(0))])])), ("data", .array(batch.map { .array([.number(1), sequence($0, Array($0.roots))]) }))])
    }
    public func decode(_ encoded: JSONValue) throws -> [BasicChunk] {
        let context = try DecoderContext(encoded: encoded, codec: self)
        return try encoded.member("data").asArray().map { field in
            var stream = StreamCursor(data: try field.asArray())
            let nodes = try context.decodeAny(&stream, depth: 0)
            try forestCheck(stream.offset == stream.data.count, "0x73a trailing stream")
            return try BasicChunk(json: .array(nodes))
        }
    }
}
/// Ports codec/chunkDecodingGeneric.ts.
final class DecoderContext {
    let identifiers: [JSString]
    let shapes: [JSONValue]
    let version: FieldBatchFormatVersion
    let codec: FieldBatchCodec
    init(encoded: JSONValue, codec: FieldBatchCodec) throws {
        version = try FieldBatchFormatVersion(json: encoded.member("version"))
        identifiers = try encoded.member("identifiers").asArray().map { try $0.asString() }
        shapes = try encoded.member("shapes").asArray()
        self.codec = codec
        for shape in shapes {
            let union = try shape.asObject()
            try forestCheck(union.count == 1, "shape union")
            guard let key = union.keys.first else { throw JSONDecodingError("empty shape") }
            try forestCheck(["a", "b", "c", "d", "e", "f"].contains(key), "unknown shape")
            try forestCheck(key != "e" || version != .v1, "incremental shape in v1")
            try forestCheck(key != "f" || version == .vTextExperimental, "specialized shape before text")
        }
    }
    func identifier(_ value: JSONValue) throws -> JSString {
        if case .string(let string) = value { return string }
        let index = try value.asInt()
        try forestCheck(identifiers.indices.contains(index), "identifier index")
        return identifiers[index]
    }
    func normalized(_ index: Int, pending: Set<Int> = []) throws -> JSObject<JSONValue> {
        try forestCheck(shapes.indices.contains(index), "shape index")
        try forestCheck(!pending.contains(index), "0xcfb cyclic specialization")
        let shape = try shapes[index].asObject()
        if let node = shape["c"] { return try node.asObject() }
        guard let override = shape["f"] else { throw JSONDecodingError("0xcfd base is not node") }
        let overlay = try override.asObject()
        var base = try normalized(override.member("base").asInt(), pending: pending.union([index]))
        var fields = try base["fields"].map { try $0.asArray() } ?? []
        var positions: [JSString: Int] = [:]
        for (i, field) in fields.enumerated() {
            let pair = try field.asArray()
            try forestCheck(pair.count == 2, "field pair")
            let key = try identifier(pair[0])
            try forestCheck(positions[key] == nil, "0xcfe duplicate base key")
            positions[key] = i
        }
        var seen = Set<JSString>()
        for field in try overlay["fields"].map({ try $0.asArray() }) ?? [] {
            let pair = try field.asArray()
            try forestCheck(pair.count == 2, "field pair")
            let key = try identifier(pair[0])
            try forestCheck(seen.insert(key).inserted, "0xcff duplicate override key")
            if let i = positions[key] {
                fields[i] = .array([try fields[i].asArray()[0], pair[1]])
            } else { fields.append(field) }
        }
        base["fields"] = fields.isEmpty ? nil : .array(fields)
        for key: JSString in ["value", "extraFields"] {
            if let value = overlay[key] { base[key] = value == .null ? nil : value }
        }
        return base
    }
    func decodeAny(_ stream: inout StreamCursor, depth: Int) throws -> [JSONValue] {
        let index = try stream.read().asInt()
        return try decode(index, &stream, depth: depth + 1)
    }
    private var decoders: [Int: any ChunkDecoder] = [:]
    func decode(_ index: Int, _ stream: inout StreamCursor, depth: Int) throws -> [JSONValue] {
        try forestCheck(shapes.indices.contains(index), "shape index")
        let shape = try shapes[index].asObject()
        if shape["d"] != nil { return try decodeAny(&stream, depth: depth) }
        let decoder: any ChunkDecoder
        if let cached = decoders[index] { decoder = cached }
        else {
            if let inner = shape["a"] { decoder = NestedArrayDecoder(context: self, inner: inner) }
            else if let inline = shape["b"] { decoder = InlineArrayDecoder(context: self, inline: inline) }
            else if shape["e"] != nil { decoder = IncrementalChunkDecoder(context: self) }
            else if shape["f"] != nil { decoder = try SpecializedNodeDecoder(context: self, index: index) }
            else { decoder = NodeDecoder(context: self, node: try normalized(index)) }
            decoders[index] = decoder
        }
        return try decoder.decode(&stream, depth: depth)
    }
}
