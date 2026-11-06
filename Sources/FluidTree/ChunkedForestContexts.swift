import FluidJS
import FluidIdCompressor

/// Ports feature-libraries/treeCompressionUtils.ts.
public enum TreeCompressionStrategy: Int {
    case compressed = 0
    case uncompressed = 1
    case compressedIncremental = 2
}
/// Ports chunked-forest/codec/codecs.ts.
public struct FieldBatchEncodingContext {
    public let encodeType: TreeCompressionStrategy
    public let idCompressor: IdCompressor
    public let schema: TreeStoredSchema?
    public let incrementalEncoder: (any IncrementalEncoder)?
    public let isSummary: Bool
    public init(encodeType: TreeCompressionStrategy, idCompressor: IdCompressor, schema: TreeStoredSchema? = nil, incrementalEncoder: (any IncrementalEncoder)? = nil, isSummary: Bool) {
        self.encodeType = encodeType
        self.idCompressor = idCompressor
        self.schema = schema
        self.incrementalEncoder = incrementalEncoder
        self.isSummary = isSummary
    }
}
/// Ports chunked-forest/codec/codecs.ts. Originator-dependent ops and originatorless summaries remain distinct.
public final class FieldBatchDecodingContext {
    public let idCompressor: IdCompressor
    public let originatorSessionId: String?
    public let incrementalDecoder: (any IncrementalDecoder)?
    private init(idCompressor: IdCompressor, originatorSessionId: String?, incrementalDecoder: (any IncrementalDecoder)? = nil) {
        self.idCompressor = idCompressor
        self.originatorSessionId = originatorSessionId
        self.incrementalDecoder = incrementalDecoder
    }
    public static func forOp(idCompressor: IdCompressor, originatorSessionId: String) -> FieldBatchDecodingContext {
        FieldBatchDecodingContext(idCompressor: idCompressor, originatorSessionId: originatorSessionId)
    }
    public static func forSummary(idCompressor: IdCompressor, originatorSessionId: String? = nil) -> FieldBatchDecodingContext {
        FieldBatchDecodingContext(idCompressor: idCompressor, originatorSessionId: originatorSessionId)
    }
    public func withIncrementalDecoder(_ decoder: any IncrementalDecoder) throws -> FieldBatchDecodingContext {
        try forestCheck(originatorSessionId == nil, "0xd0c incremental decoder requires originatorless context")
        return FieldBatchDecodingContext(idCompressor: idCompressor, originatorSessionId: nil, incrementalDecoder: decoder)
    }
}

extension FieldBatchCodec {
    public func encode(_ batch: [BasicChunk], context: FieldBatchEncodingContext, version: FieldBatchFormatVersion) throws -> JSONValue {
        let codec = FieldBatchCodec(idCompressor: context.idCompressor)
        codec.isSummary = context.isSummary
        if context.encodeType == .compressedIncremental {
            try forestCheck(version != .v1, "0xca0 incremental encoding requires v2 or text")
            try forestCheck(context.isSummary || context.incrementalEncoder == nil, "0xd0d incremental encoding requires summary identifiers")
            codec.incrementalEncoder = context.incrementalEncoder
        }
        return try codec.encode(batch, version: version, schema: context.encodeType == .uncompressed ? nil : context.schema)
    }
    public func decode(_ encoded: JSONValue, context: FieldBatchDecodingContext) throws -> [BasicChunk] {
        let codec = FieldBatchCodec(idCompressor: context.idCompressor)
        codec.originatorSessionId = context.originatorSessionId
        codec.incrementalDecoder = context.incrementalDecoder
        return try codec.decode(encoded)
    }
}
