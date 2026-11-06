import FluidJS
import FluidIdCompressor

/// Ports codec/chunkCodecUtilities.ts.
protocol ChunkDecoder {
    func decode(_ stream: inout StreamCursor, depth: Int) throws -> [JSONValue]
}
/// Ports codec/chunkDecoding.ts. Decoders borrow their batch context; recursive shapes cannot retain it.
final class NestedArrayDecoder: ChunkDecoder {
    unowned let context: DecoderContext
    let inner: JSONValue
    init(context: DecoderContext, inner: JSONValue) {
        self.context = context
        self.inner = inner
    }
    func decode(_ stream: inout StreamCursor, depth: Int) throws -> [JSONValue] {
        try forestCheck(context.shapes.indices.contains(try inner.asInt()), "nested shape index")
        let token = try stream.read()
        var result: [JSONValue] = []
        if case .number = token {
            let count = try token.asInt()
            try forestCheck(count >= 0, "nested count")
            var empty = StreamCursor(data: [])
            for _ in 0..<count { result += try context.decode(inner.asInt(), &empty, depth: depth + 1) }
        } else {
            var nested = StreamCursor(data: try token.asArray())
            while nested.offset < nested.data.count {
                let before = nested.offset
                result += try context.decode(inner.asInt(), &nested, depth: depth + 1)
                try forestCheck(nested.offset > before, "zero sized nested member")
            }
        }
        return result
    }
}
final class InlineArrayDecoder: ChunkDecoder {
    unowned let context: DecoderContext
    let inline: JSONValue
    init(context: DecoderContext, inline: JSONValue) {
        self.context = context
        self.inline = inline
    }
    func decode(_ stream: inout StreamCursor, depth: Int) throws -> [JSONValue] {
        try forestCheck(context.shapes.indices.contains(try inline.member("shape").asInt()), "inline shape index")
        let length = try inline.member("length").asInt()
        try forestCheck(length >= 0, "inline length")
        var result: [JSONValue] = []
        for _ in 0..<length { result += try context.decode(inline.member("shape").asInt(), &stream, depth: depth + 1) }
        return result
    }
}
final class IncrementalChunkDecoder: ChunkDecoder {
    unowned let context: DecoderContext
    init(context: DecoderContext) { self.context = context }
    func decode(_ stream: inout StreamCursor, depth: Int) throws -> [JSONValue] {
        let reference = try stream.read().asInt()
        let chunk: JSONValue
        if let cached = context.codec.incrementalChunks[reference] { chunk = cached }
        else if let decoder = context.codec.incrementalDecoder { chunk = try decoder.decodeIncrementalChunk(reference) }
        else { throw JSONDecodingError("0xc27 missing incremental chunk") }
        try forestCheck(FieldBatchFormatVersion(json: chunk.member("version")) != .v1, "0xc9f incremental version")
        return try context.codec.decode(chunk).flatMap { try $0.json.asArray() }
    }
}
final class NodeDecoder: ChunkDecoder {
    unowned let context: DecoderContext
    let node: JSObject<JSONValue>
    init(context: DecoderContext, node: JSObject<JSONValue>) {
        self.context = context
        self.node = node
    }
    func decode(_ stream: inout StreamCursor, depth: Int) throws -> [JSONValue] {
        let type = try context.identifier(node["type"] ?? stream.read())
        var value: JSONValue?
        if let valueShape = node["value"] {
            switch valueShape {
            case .bool(true): value = try stream.read()
            case .bool(false): break
            case .array(let constant):
                try forestCheck(constant.count == 1, "0x734 constant")
                value = constant[0]
            case .number(0):
                let token = try stream.read()
                if case .string = token { value = token }
                else {
                    guard let compressor = context.codec.idCompressor else { throw JSONDecodingError("identifier requires compressor") }
                    let id: Double
                    if let originator = context.codec.originatorSessionId {
                        id = try compressor.normalizeToSessionSpace(token.asNumber(), originSessionId: originator)
                    } else {
                        guard let finalized = try compressor.tryNormalizeToSessionSpaceWithoutSession(token.asNumber()) else { throw JSONDecodingError("0xd0a summary identifier must be finalized") }
                        id = finalized
                    }
                    value = .string(JSString(try compressor.decompress(id)))
                }
            default: throw JSONDecodingError("unsupported value shape")
            }
        } else {
            let present = try stream.read()
            guard case .bool(let present) = present else { throw JSONDecodingError("0x731 expected boolean") }
            if present { value = try stream.read() }
        }
        var fields: [(JSString, [JSONValue])] = []
        func add(_ key: JSString, _ nodes: [JSONValue]) {
            if !nodes.isEmpty {
                if let index = fields.firstIndex(where: { $0.0 == key }) { fields[index].1 = nodes }
                else { fields.append((key, nodes)) }
            }
        }
        for field in try node["fields"].map({ try $0.asArray() }) ?? [] {
            let pair = try field.asArray()
            try forestCheck(pair.count == 2, "field pair")
            add(try context.identifier(pair[0]), try context.decode(pair[1].asInt(), &stream, depth: depth + 1))
        }
        if let extra = node["extraFields"] {
            var nested = StreamCursor(data: try stream.read().asArray())
            while nested.offset < nested.data.count {
                let key = try context.identifier(nested.read())
                add(key, try context.decode(extra.asInt(), &nested, depth: depth + 1))
            }
        }
        var result: [(JSString, JSONValue)] = [("type", .string(type))]
        if let value { result.append(("value", value)) }
        result.append(("fields", .array(fields.map { .array([.string($0.0), .array($0.1)]) })))
        return [forestObject(result)]
    }
}
final class SpecializedNodeDecoder: ChunkDecoder {
    let inner: NodeDecoder
    init(context: DecoderContext, index: Int) throws {
        inner = NodeDecoder(context: context, node: try context.normalized(index))
    }
    func decode(_ stream: inout StreamCursor, depth: Int) throws -> [JSONValue] {
        try inner.decode(&stream, depth: depth)
    }
}
