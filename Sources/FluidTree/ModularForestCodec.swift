import FluidJS
import FluidIdCompressor

/// modularChangeCodecV1.ts's field-batch dependency, backed by the native
/// chunked-forest lane. Chunk grouping stays in ModularChangeCodec.
public struct ModularForestCodec: ModularChunkCodec {
    private let idCompressor: IdCompressor
    private let version: FieldBatchFormatVersion
    private let schema: TreeStoredSchema?
    private let codec = FieldBatchCodec()
    public init(idCompressor: IdCompressor, minimumClientVersion: FluidClientVersion = .v2_0, schema: TreeStoredSchema? = nil) {
        self.idCompressor = idCompressor
        version = minimumClientVersion >= FluidClientVersion(major: 2, minor: 73) ? .v2 : .v1
        self.schema = schema
    }
    public func encode(_ chunks: [any TreeChunk], context: ModularCodecContext) throws -> JSONValue {
        let batch = try chunks.map(materialize)
        let fields = FieldBatchEncodingContext(encodeType: .compressed, idCompressor: idCompressor, schema: schema, isSummary: context.isSummary)
        return try codec.encode(batch, context: fields, version: version)
    }
    public func decode(_ value: JSONValue, context: ModularCodecContext) throws -> [any TreeChunk] {
        let fields = context.isSummary
            ? FieldBatchDecodingContext.forSummary(idCompressor: idCompressor)
            : FieldBatchDecodingContext.forOp(idCompressor: idCompressor, originatorSessionId: context.originatorId)
        return try codec.decode(value, context: fields)
    }
    private func materialize(_ chunk: any TreeChunk) throws -> BasicChunk {
        if let basic = chunk as? BasicChunk { return basic }
        if let uniform = chunk as? UniformChunk { return try uniform.materialize() }
        if let sequence = chunk as? SequenceChunk {
            let nodes = try sequence.subChunks.flatMap { try materialize($0).json.asArray() }
            return try BasicChunk(json: .array(nodes))
        }
        throw JSONDecodingError("unsupported native chunk representation")
    }
}
