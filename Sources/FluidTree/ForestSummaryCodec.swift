import FluidJS

/// Ports feature-libraries/forest-summary/codec.ts.
public struct ForestCodec {
    public let fieldBatchCodec: FieldBatchCodec
    public init(fieldBatchCodec: FieldBatchCodec) { self.fieldBatchCodec = fieldBatchCodec }
    public func encode(_ fields: [(JSString, BasicChunk)], version: Int, fieldVersion: FieldBatchFormatVersion, schema: TreeStoredSchema? = nil) throws -> JSONValue {
        try forestCheck(version == 1 || version == 2, "unsupported Forest version")
        return forestObject([("keys", .array(fields.map { .string($0.0) })), ("fields", try fieldBatchCodec.encode(fields.map(\.1), version: fieldVersion, schema: schema)), ("version", forestIndex(version))])
    }
    public func decode(_ value: JSONValue) throws -> [(JSString, BasicChunk)] {
        let version = try value.member("version").asInt()
        try forestCheck(version == 1 || version == 2, "unsupported Forest version")
        let keys = try value.member("keys").asArray().map { try $0.asString() }
        let chunks = try fieldBatchCodec.decode(value.member("fields"))
        try forestCheck(keys.count == chunks.count, "0x891 key/field count mismatch")
        var result: [(JSString, BasicChunk)] = []
        for (key, chunk) in zip(keys, chunks) {
            if let index = result.firstIndex(where: { $0.0 == key }) { result[index].1 = chunk }
            else { result.append((key, chunk)) }
        }
        return result
    }
}
