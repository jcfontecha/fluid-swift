import FluidJS
import FluidIdCompressor

/// Ports codec/chunkEncodingGeneric.ts. Identity, not structural equality, deduplicates shapes.
struct ShapeReference {
    unowned let shape: Shape
}
class Shape {
    enum Kind {
        case any
        case empty
        case incremental
        case nested(ShapeReference)
        case node(JSString, JSONValue, [(JSString, ShapeReference)], ShapeReference?)
    }
    var kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}
/// Ports codec/nodeEncoder.ts.
final class NodeShapeBasedEncoder: Shape {
    fileprivate func encodeNode(_ chunk: BasicChunk, _ index: Int, context: EncoderContext) throws -> [BufferToken] {
        guard case .node(let type, let valueShape, let fields, let extra) = kind else { throw JSONDecodingError("node shape") }
        try forestCheck(type == chunk.types[index], "0x741 type mismatch")
        var output: [BufferToken] = []
        if valueShape == .bool(true) {
            guard let value = chunk.values[index] else { throw JSONDecodingError("0x78d required value") }
            output.append(.value(value))
        } else if valueShape == .bool(false) {
            try forestCheck(chunk.values[index] == nil, "0x73f expected no value")
        } else if valueShape == .number(0) {
            guard let value = chunk.values[index] else { throw JSONDecodingError("0x998 identifier") }
            let string = try value.asString()
            if forestIsStableId(string), let compressor = context.compressor, let id = try compressor.tryRecompress(string.description) {
                let op = try compressor.normalizeToOpSpace(id)
                output.append(.value(op >= 0 || !context.isSummary ? .number(op) : value))
            } else { output.append(.value(value)) }
        }
        let actual = chunk.fields(index)
        for (key, field) in fields {
            output += try context.encodeField(chunk, actual.first(where: { $0.0 == key })?.1 ?? [], field.shape)
        }
        var others: [BufferToken] = []
        for (key, children) in actual where !fields.contains(where: { $0.0 == key }) {
            guard let extra else { throw JSONDecodingError("0x742 extra field") }
            others.append(.identifier(IdentifierToken(identifier: key)))
            others += try context.encodeField(chunk, children, extra.shape)
        }
        if extra != nil { output.append(.array(others)) }
        return output
    }
}
/// Ports codec/compressedEncode.ts.
final class NestedArrayShape: Shape {}
final class InlineArrayEncoder: Shape {}
final class AnyShape: Shape {}
/// Ports codec/chunkEncodingGeneric.ts.
struct IdentifierToken { let identifier: JSString }
fileprivate indirect enum BufferToken {
    case value(JSONValue)
    case identifier(IdentifierToken)
    case shape(Shape)
    case array([BufferToken])
}
/// Ports codec/schemaBasedEncode.ts and codec/compressedEncode.ts EncoderContext.
final class EncoderContext {
    let schema: TreeStoredSchema
    let compressor: IdCompressor?
    let isSummary: Bool
    let incrementalEncoder: (any IncrementalEncoder)?
    var version: FieldBatchFormatVersion = .v1
    let incremental = Shape(.incremental)
    let any = AnyShape(.any)
    let empty = InlineArrayEncoder(.empty)
    var nodes: [JSString: Shape] = [:]
    var identifierNodes: [Shape] = []
    var nested: [ObjectIdentifier: Shape] = [:]
    init(schema: TreeStoredSchema, compressor: IdCompressor?, incrementalEncoder: (any IncrementalEncoder)? = nil, isSummary: Bool = true) {
        self.isSummary = isSummary
        self.incrementalEncoder = incrementalEncoder
        self.schema = schema
        self.compressor = compressor
    }
    func array(_ inner: Shape) -> Shape {
        let key = ObjectIdentifier(inner)
        if let shape = nested[key] { return shape }
        let shape = NestedArrayShape(.nested(ShapeReference(shape: inner)))
        nested[key] = shape
        return shape
    }
    func field(_ field: TreeFieldStoredSchema) throws -> Shape {
        try forestCheck(["Value", "Identifier", "Optional", "Sequence", "Forbidden"].contains(field.kind), "0xb52 missing FieldKind")
        let inner = try field.types.count == 1 ? node(field.types[0]) : any
        if field.kind == "Value" || field.kind == "Identifier" {
            if field.kind == "Identifier" {
                try forestCheck(field.types.count == 1, "0x999 identifier type")
                guard let type = field.types.first else { throw JSONDecodingError("0x999 identifier type") }
                guard let stored = schema.nodeSchema.first(where: { $0.0 == type })?.1 else { throw JSONDecodingError("0x99a missing identifier schema") }
                guard case .leaf(let leaf) = stored else { throw JSONDecodingError("0x99b identifier must be leaf") }
                try forestCheck(leaf.leafValue == 1, "0x99c identifier must be string")
                let shape = NodeShapeBasedEncoder(.node(type, .number(0), [], nil))
                identifierNodes.append(shape)
                return shape
            }
            return inner
        }
        return array(inner)
    }
    func node(_ type: JSString) throws -> Shape {
        if let shape = nodes[type] { return shape }
        guard let stored = schema.nodeSchema.first(where: { $0.0 == type })?.1 else { throw JSONDecodingError("0xb53 missing schema") }
        let shape = NodeShapeBasedEncoder(.any)
        nodes[type] = shape
        switch stored {
        case .leaf(let leaf): shape.kind = .node(type, leaf.leafValue == 4 ? .array([.null]) : .bool(true), [], nil)
        case .object(let object): shape.kind = .node(type, .bool(false), try object.objectNodeFields.map { ($0.0, ShapeReference(shape: incrementalEncoder?.shouldEncodeIncrementally(type, $0.0) == true ? array(incremental) : try field($0.1))) }, nil)
        case .map(let map): shape.kind = .node(type, .bool(false), [], ShapeReference(shape: incrementalEncoder?.shouldEncodeIncrementally(type, nil) == true ? array(incremental) : try field(map.mapFields)))
        }
        return shape
    }
    private func encodeNode(_ chunk: BasicChunk, _ index: Int, _ shape: Shape) throws -> [BufferToken] {
        if case .any = shape.kind {
            let specific = try node(chunk.types[index])
            return [.shape(specific)] + (try encodeNode(chunk, index, specific))
        }
        guard let encoder = shape as? NodeShapeBasedEncoder else { throw JSONDecodingError("node encoder required") }
        return try encoder.encodeNode(chunk, index, context: self)
    }
    fileprivate func encodeField(_ chunk: BasicChunk, _ indices: [Int], _ shape: Shape) throws -> [BufferToken] {
        switch shape.kind {
        case .nested(let inner):
            if case .incremental = inner.shape.kind {
                guard let incrementalEncoder else { throw JSONDecodingError("missing incremental encoder") }
                let content = try BasicChunk(json: .array(indices.map(chunk.jsonNode)))
                let refs = try incrementalEncoder.encodeIncrementalField(content) { try self.encode([$0], version: self.version) }
                return [.array(refs.map { .value(forestIndex($0)) })]
            }
            let buffer = try indices.flatMap { try encodeNode(chunk, $0, inner.shape) }
            return buffer.isEmpty ? [.value(forestIndex(indices.count))] : [.array(buffer)]
        case .empty: return []
        default: return try indices.flatMap { try encodeNode(chunk, $0, shape) }
        }
    }
    func encode(_ batch: [BasicChunk], version: FieldBatchFormatVersion) throws -> JSONValue {
        self.version = version
        var buffers: [[BufferToken]] = []
        for chunk in batch {
            let shape: Shape
            if chunk.roots.isEmpty { shape = empty }
            else if chunk.roots.count == 1 { shape = try node(chunk.types[chunk.roots[0]]) }
            else { shape = array(any) }
            buffers.append([.shape(shape)] + (try encodeField(chunk, Array(chunk.roots), shape)))
        }
        var shapeOrder: [Shape] = []
        var shapeCounts: [ObjectIdentifier: Int] = [:]
        var pending: [Shape] = []
        var identifierOrder: [JSString] = []
        var identifierCounts: [JSString: Int] = [:]
        func discover(_ shape: Shape) {
            let id = ObjectIdentifier(shape)
            if shapeCounts[id] == nil {
                shapeOrder.append(shape)
                pending.append(shape)
            }
            shapeCounts[id, default: 0] += 1
        }
        func identifier(_ key: JSString) {
            if identifierCounts[key] == nil { identifierOrder.append(key) }
            identifierCounts[key, default: 0] += 1
        }
        var arrays = buffers
        var cursor = 0
        while cursor < arrays.count {
            for token in arrays[cursor] {
                switch token {
                case .shape(let shape): discover(shape)
                case .identifier(let token): identifier(token.identifier)
                case .array(let buffer): arrays.append(buffer)
                case .value: break
                }
            }
            cursor += 1
        }
        while let shape = pending.popLast() {
            switch shape.kind {
            case .any, .incremental: break
            case .empty: discover(shape)
            case .nested(let inner): discover(inner.shape)
            case .node(let type, _, let fields, let extra):
                identifier(type)
                for (key, field) in fields {
                    identifier(key)
                    discover(field.shape)
                }
                if let extra { discover(extra.shape) }
            }
        }
        shapeOrder = shapeOrder.enumerated().sorted { lhs, rhs in
            let l = shapeCounts[ObjectIdentifier(lhs.element), default: 0]
            let r = shapeCounts[ObjectIdentifier(rhs.element), default: 0]
            return l == r ? lhs.offset < rhs.offset : l > r
        }.map(\.element)
        identifierOrder = identifierOrder.enumerated().sorted { lhs, rhs in
            let l = identifierCounts[lhs.element, default: 0]
            let r = identifierCounts[rhs.element, default: 0]
            return l == r ? lhs.offset < rhs.offset : l > r
        }.map(\.element)
        var identifiers: [JSString] = []
        for key in identifierOrder {
            let count = identifierCounts[key, default: 0]
            let length = JSON.stringify(.string(key)).utf16.count
            if String(identifiers.count).count * count + length + 1 < length * count { identifiers.append(key) }
        }
        let shapeIndices = Dictionary(uniqueKeysWithValues: shapeOrder.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
        let identifierIndices = Dictionary(uniqueKeysWithValues: identifiers.enumerated().map { ($0.element, $0.offset) })
        func shapeIndex(_ shape: Shape) throws -> JSONValue {
            guard let index = shapeIndices[ObjectIdentifier(shape)] else { throw JSONDecodingError("missing shape") }
            return forestIndex(index)
        }
        func encodedIdentifier(_ key: JSString) -> JSONValue { identifierIndices[key].map(forestIndex) ?? .string(key) }
        func resolve(_ buffer: [BufferToken]) throws -> JSONValue {
            .array(try buffer.map { token in
                switch token {
                case .value(let value): return value
                case .shape(let shape): return try shapeIndex(shape)
                case .identifier(let token): return encodedIdentifier(token.identifier)
                case .array(let nested): return try resolve(nested)
                }
            })
        }
        let shapes = try shapeOrder.map { shape -> JSONValue in
            switch shape.kind {
            case .incremental: return forestObject([("e", .number(0))])
            case .any: return forestObject([("d", .number(0))])
            case .empty: return forestObject([("b", forestObject([("length", .number(0)), ("shape", try shapeIndex(shape))]))])
            case .nested(let inner): return forestObject([("a", try shapeIndex(inner.shape))])
            case .node(let type, let value, let fields, let extra):
                var entries: [(JSString, JSONValue)] = [("type", encodedIdentifier(type)), ("value", value)]
                if !fields.isEmpty { entries.append(("fields", .array(try fields.map { .array([encodedIdentifier($0.0), try shapeIndex($0.1.shape)]) }))) }
                if let extra { entries.append(("extraFields", try shapeIndex(extra.shape))) }
                return forestObject([("c", forestObject(entries))])
            }
        }
        return forestObject([("version", version.json), ("identifiers", .array(identifiers.map(JSONValue.string))), ("shapes", .array(shapes)), ("data", .array(try buffers.map(resolve)))])
    }
}
