import FluidJS

func forestObject(_ entries: [(JSString, JSONValue)]) -> JSONValue {
    var object = JSObject<JSONValue>()
    for (key, value) in entries { object[key] = value }
    return .object(object)
}
func forestIndex(_ value: Int) -> JSONValue { .number(Double(value)) }
func forestCheck(_ condition: Bool, _ message: String) throws {
    guard condition else { throw JSONDecodingError(message) }
}

/// Ports feature-libraries/chunked-forest/basicChunk.ts with the columnar layout required by ARCHITECTURE section 5. Nodes, fields, and edges live in contiguous columns, not heap nodes.
public final class BasicChunk: TreeChunk {
    public var topLevelLength: Int { roots.count }
    private var references = 1
    public func isShared() -> Bool { references > 1 }
    public func referenceAdded() { references += 1 }
    public func referenceRemoved() { references -= 1 }
    public private(set) var types: ContiguousArray<JSString> = []
    public private(set) var values: ContiguousArray<JSONValue?> = []
    private var firstFields: ContiguousArray<Int> = []
    private var fieldCounts: ContiguousArray<Int> = []
    private var keys: ContiguousArray<JSString> = []
    private var firstEdges: ContiguousArray<Int> = []
    private var edgeCounts: ContiguousArray<Int> = []
    private var edges: ContiguousArray<Int> = []
    public private(set) var roots: ContiguousArray<Int> = []
    public init() {}
    public convenience init(json: JSONValue) throws {
        self.init()
        for node in try json.asArray() { roots.append(try append(node)) }
    }
    private func append(_ node: JSONValue) throws -> Int {
        let type = try node.member("type").asString()
        let object = try node.asObject()
        let fields = try node.member("fields").asArray()
        var decoded: [(JSString, [Int])] = []
        for field in fields {
            let pair = try field.asArray()
            try forestCheck(pair.count == 2, "field tuple")
            let key = try pair[0].asString()
            var children: [Int] = []
            for child in try pair[1].asArray() { children.append(try append(child)) }
            if !children.isEmpty { decoded.append((key, children)) }
        }
        let index = types.count
        types.append(type)
        values.append(object["value"])
        firstFields.append(keys.count)
        fieldCounts.append(decoded.count)
        for (key, children) in decoded {
            keys.append(key)
            firstEdges.append(edges.count)
            edgeCounts.append(children.count)
            edges.append(contentsOf: children)
        }
        return index
    }
    public func fields(_ node: Int) -> [(JSString, [Int])] {
        (firstFields[node]..<(firstFields[node] + fieldCounts[node])).map { field in
            (keys[field], Array(edges[firstEdges[field]..<(firstEdges[field] + edgeCounts[field])]))
        }
    }
    public func jsonNode(_ node: Int) -> JSONValue {
        var result: [(JSString, JSONValue)] = [("type", .string(types[node]))]
        if let value = values[node] { result.append(("value", value)) }
        result.append(("fields", .array(fields(node).map { key, children in
            .array([.string(key), .array(children.map(jsonNode))])
        })))
        return forestObject(result)
    }
    public var json: JSONValue { .array(roots.map(jsonNode)) }
}

public enum FieldBatchFormatVersion: Equatable, Sendable {
    case v1, v2, vTextExperimental
    var json: JSONValue {
        switch self {
        case .v1: return .number(1)
        case .v2: return .number(2)
        case .vTextExperimental: return .string("text")
        }
    }
    init(json: JSONValue) throws {
        switch json {
        case .number(1): self = .v1
        case .number(2): self = .v2
        case .string("text"): self = .vTextExperimental
        default: throw JSONDecodingError("unsupported FieldBatch version")
        }
    }
}

/// Ports id-compressor/utilities.ts isStableId, used by tree/util/compressedIds.ts.
func forestIsStableId(_ string: JSString) -> Bool {
    let units = string.utf16
    if units.count != 36 { return false }
    for (index, unit) in units.enumerated() {
        switch index {
        case 8, 13, 18, 23:
            if unit != 45 { return false }
        case 14:
            if unit != 52 { return false }
        case 19:
            if ![56, 57, 97, 98].contains(unit) { return false }
        default:
            if !(48...57).contains(unit) && !(65...70).contains(unit) && !(97...102).contains(unit) { return false }
        }
    }
    return true
}
