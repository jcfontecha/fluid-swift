import FluidJS

/// Ports core/schema-stored/schema.ts.
public struct TreeFieldStoredSchema: Sendable {
    public let kind: JSString
    public let types: [JSString]
    public let persistedMetadata: JSONValue?
    public init(json: JSONValue) throws {
        kind = try json.member("kind").asString()
        var seen = Set<JSString>()
        types = try json.member("types").asArray().map { try $0.asString() }.filter { seen.insert($0).inserted }
        persistedMetadata = try json.asObject()["metadata"]
    }
    func encode(_ version: Int) -> JSONValue {
        var entries: [(JSString, JSONValue)] = [("kind", .string(kind)), ("types", .array(types.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.map(JSONValue.string)))]
        if version == 2, let metadata = persistedMetadata { entries.append(("metadata", metadata)) }
        return forestObject(entries)
    }
}
/// Ports core/schema-stored/schema.ts; concrete kinds retain their upstream names.
public enum TreeNodeStoredSchema: Sendable {
    case object(ObjectNodeStoredSchema)
    case map(MapNodeStoredSchema)
    case leaf(LeafNodeStoredSchema)
    var metadata: JSONValue? {
        switch self {
        case .object(let node): return node.persistedMetadata
        case .map(let node): return node.persistedMetadata
        case .leaf(let node): return node.persistedMetadata
        }
    }
    func encode(_ version: Int) -> JSONValue {
        let kind: JSONValue
        switch self {
        case .object(let node):
            kind = forestObject([("object", forestObject(node.objectNodeFields.sorted { $0.0.utf16.lexicographicallyPrecedes($1.0.utf16) }.map { ($0.0, $0.1.encode(version)) }))])
        case .map(let node): kind = forestObject([("map", node.mapFields.encode(version))])
        case .leaf(let node): kind = forestObject([("leaf", forestIndex(node.leafValue))])
        }
        if version == 1 { return kind }
        var entries: [(JSString, JSONValue)] = [("kind", kind)]
        if let metadata { entries.append(("metadata", metadata)) }
        return forestObject(entries)
    }
}
public struct ObjectNodeStoredSchema: Sendable {
    public let objectNodeFields: [(JSString, TreeFieldStoredSchema)]
    public let persistedMetadata: JSONValue?
}
public struct MapNodeStoredSchema: Sendable {
    public let mapFields: TreeFieldStoredSchema
    public let persistedMetadata: JSONValue?
}
public struct LeafNodeStoredSchema: Sendable {
    public let leafValue: Int
    public let persistedMetadata: JSONValue?
}
public struct TreeStoredSchema: Sendable {
    public let nodeSchema: [(JSString, TreeNodeStoredSchema)]
    public let rootFieldSchema: TreeFieldStoredSchema
    public init(json: JSONValue) throws {
        let object = try json.asObject()
        let version = try object["version"].map { try $0.asInt() } ?? 1
        try forestCheck(version == 1 || version == 2, "unsupported Schema version")
        rootFieldSchema = try TreeFieldStoredSchema(json: json.member("root"))
        nodeSchema = try json.member("nodes").asObject().entries.map { key, value in
            let wrapper = try value.asObject()
            let kind = try (version == 2 ? value.member("kind") : value).asObject()
            try forestCheck(kind.count == 1, "schema union")
            let metadata = version == 2 ? wrapper["metadata"] : nil
            let node: TreeNodeStoredSchema
            if let leaf = kind["leaf"] {
                let tag = try leaf.asInt()
                try forestCheck((0...4).contains(tag), "invalid leaf tag")
                node = .leaf(LeafNodeStoredSchema(leafValue: tag, persistedMetadata: metadata))
            } else if let map = kind["map"] {
                node = .map(MapNodeStoredSchema(mapFields: try TreeFieldStoredSchema(json: map), persistedMetadata: metadata))
            } else if let fields = kind["object"] {
                node = .object(ObjectNodeStoredSchema(objectNodeFields: try fields.asObject().entries.map { ($0.key, try TreeFieldStoredSchema(json: $0.value)) }, persistedMetadata: metadata))
            } else { throw JSONDecodingError("unknown stored schema kind") }
            return (key, node)
        }
    }
}
/// Ports feature-libraries/schema-index/codec.ts.
public struct SchemaCodec {
    public init() {}
    public func encode(_ schema: TreeStoredSchema, version: Int) throws -> JSONValue {
        try forestCheck(version == 1 || version == 2, "unsupported Schema version")
        return forestObject([("version", forestIndex(version)), ("nodes", forestObject(schema.nodeSchema.sorted { $0.0.utf16.lexicographicallyPrecedes($1.0.utf16) }.map { ($0.0, $0.1.encode(version)) })), ("root", schema.rootFieldSchema.encode(version))])
    }
    public func decode(_ value: JSONValue) throws -> TreeStoredSchema { try TreeStoredSchema(json: value) }
}
