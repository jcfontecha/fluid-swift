import FluidDriverDefinitions
import FluidJS
import FluidOdspDriver

// JSON wire forms of the H10 harness (harness/PROTOCOL.md, "H10"): hex for bytes, `{ok}` / `{err}`
// outcomes, and the canonical snapshot form the TS oracle emits.

private let hexDigits = Array("0123456789abcdef".utf8)

func toHex(_ bytes: some Sequence<UInt8>) -> JSString {
    var units = ContiguousArray<UInt16>()
    for byte in bytes {
        units.append(UInt16(hexDigits[Int(byte >> 4)]))
        units.append(UInt16(hexDigits[Int(byte & 0x0F)]))
    }
    return JSString(utf16: units)
}

func fromHex(_ text: JSString) throws -> [UInt8] {
    let units = text.utf16
    guard units.count % 2 == 0 else {
        throw JSONDecodingError("odd hex length")
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(units.count / 2)
    var index = 0
    while index < units.count {
        bytes.append(try nibble(units[index]) << 4 | nibble(units[index + 1]))
        index += 2
    }
    return bytes
}

private func nibble(_ unit: UInt16) throws -> UInt8 {
    switch unit {
    case 0x30...0x39:
        return UInt8(unit - 0x30)
    case 0x61...0x66:
        return UInt8(unit - 0x61 + 10)
    default:
        throw JSONDecodingError("invalid hex digit")
    }
}

func object(_ pairs: [(JSString, JSONValue)]) -> JSONValue {
    var result = JSObject<JSONValue>()
    for (key, value) in pairs {
        result[key] = value
    }
    return .object(result)
}

func ok(_ value: JSONValue) -> JSONValue {
    object([("ok", value)])
}

func err(_ error: OdspSnapshotError) -> JSONValue {
    object([("err", errorJSON(error))])
}

private func errorJSON(_ error: OdspSnapshotError) -> JSONValue {
    switch error {
    case .assertionFailed(let code):
        let hex = String(code, radix: 16)
        return object([
            ("kind", .string("assert")),
            ("code", .string(JSString("0x" + String(repeating: "0", count: max(0, 3 - hex.count)) + hex))),
        ])
    case .invalidCode(let code):
        return object([("kind", .string("invalidCode")), ("code", .number(Double(code)))])
    case .bufferParsing(let message, let nodeType, let expectedNodeType):
        return object([
            ("kind", .string("bufferParsing")),
            ("message", .string(JSString(message))),
            ("nodeType", .string(JSString(nodeType.rawValue))),
            ("expectedNodeType", .string(JSString(expectedNodeType.rawValue))),
        ])
    case .undefinedAccess:
        return object([("kind", .string("undefinedAccess"))])
    case .invalidJSON:
        return object([("kind", .string("invalidJSON"))])
    case .sequenceNumberOutOfRange:
        return object([("kind", .string("sequenceNumberOutOfRange"))])
    }
}

// MARK: - Snapshot spec (harness -> Swift)

func decodeTree(_ json: JSONValue) throws -> CompactSnapshotTree {
    let fields = try json.asObject()
    var tree = CompactSnapshotTree()
    tree.id = try fields["id"]?.asString()
    for (key, value) in try json.member("blobs").asObject().entries {
        tree.blobs[key] = try value.asString()
    }
    for (key, value) in try json.member("trees").asObject().entries {
        tree.trees[key] = try decodeTree(value)
    }
    if let flag = fields["unreferenced"] {
        guard case .bool(let value) = flag else {
            throw JSONDecodingError("expected boolean")
        }
        tree.unreferenced = value
    }
    tree.groupId = try fields["groupId"]?.asString()
    return tree
}

private func decodeBlob(_ json: JSONValue) throws -> CompactSnapshotBlobContent {
    switch try json.member("kind").asString().description {
    case "buffer":
        return .buffer(try fromHex(json.member("hex").asString())[...])
    case "iblob":
        let encoding = try json.asObject()["encoding"].map { try BlobEncoding(json: $0) }
        return .blob(contents: try json.member("contents").asString(), encoding: encoding)
    default:
        throw JSONDecodingError("unknown blob kind")
    }
}

func decodeSnapshot(_ json: JSONValue) throws -> CompactSnapshot {
    let fields = try json.asObject()
    var blobContents = JSMap<JSString, CompactSnapshotBlobContent>()
    for entry in try json.member("blobContents").asArray() {
        let pair = try entry.asArray()
        guard pair.count == 2 else {
            throw JSONDecodingError("expected [id, blob]")
        }
        blobContents.set(try pair[0].asString(), try decodeBlob(pair[1]))
    }
    return CompactSnapshot(
        snapshotTree: try decodeTree(json.member("snapshotTree")),
        blobContents: blobContents,
        ops: try json.member("ops").asArray(),
        sequenceNumber: try fields["sequenceNumber"]?.asInt(),
        latestSequenceNumber: try fields["latestSequenceNumber"]?.asInt())
}

// MARK: - Canonical parse result (Swift -> harness)

private func canonicalTree(_ tree: CompactSnapshotTree) -> JSONValue {
    var pairs: [(JSString, JSONValue)] = []
    if let id = tree.id {
        pairs.append(("id", .string(id)))
    }
    var blobs = JSObject<JSONValue>()
    for (key, value) in tree.blobs.entries {
        blobs[key] = .string(value)
    }
    pairs.append(("blobs", .object(blobs)))
    var trees = JSObject<JSONValue>()
    for (key, value) in tree.trees.entries {
        trees[key] = canonicalTree(value)
    }
    pairs.append(("trees", .object(trees)))
    if let unreferenced = tree.unreferenced {
        pairs.append(("unreferenced", .bool(unreferenced)))
    }
    if let groupId = tree.groupId {
        pairs.append(("groupId", .string(groupId)))
    }
    return object(pairs)
}

func canonicalParse(_ result: ISnapshotContentsWithProps) throws -> JSONValue {
    let snapshot = result.snapshot
    var blobContents: [JSONValue] = []
    for (id, content) in snapshot.blobContents.entries {
        guard case .buffer(let bytes) = content else {
            throw JSONDecodingError("the parser produced a non-buffer blob")
        }
        blobContents.append(.array([.string(id), .string(toHex(bytes))]))
    }
    var pairs: [(JSString, JSONValue)] = [
        ("snapshotTree", canonicalTree(snapshot.snapshotTree)),
        ("blobContents", .array(blobContents)),
        ("ops", .array(snapshot.ops)),
    ]
    if let sequenceNumber = snapshot.sequenceNumber {
        pairs.append(("sequenceNumber", .number(Double(sequenceNumber))))
    }
    if let latest = snapshot.latestSequenceNumber {
        pairs.append(("latestSequenceNumber", .number(Double(latest))))
    }
    pairs.append(("snapshotFormatV", .number(Double(snapshot.snapshotFormatV))))
    pairs.append((
        "telemetry",
        object([
            ("slowTreeStructureCount", .number(Double(result.telemetryProps.slowTreeStructureCount))),
            ("slowBlobStructureCount", .number(Double(result.telemetryProps.slowBlobStructureCount))),
            ("treeStructureCountWithGroupId", .number(Double(result.telemetryProps.treeStructureCountWithGroupId))),
        ])
    ))
    return object(pairs)
}

// MARK: - Raw ZipIt trees

func fillNode(_ target: NodeCore, _ elements: [JSONValue]) throws {
    for element in elements {
        switch try element.member("k").asString().description {
        case "node":
            let type: NodeCoreTypes = try element.member("t").asString() == "list" ? .list : .set
            try fillNode(target.addNode(type), element.member("c").asArray())
        case "num":
            let value = try element.member("v")
            if case .null = value {
                try target.addNumber(nil)
            } else {
                try target.addNumber(value.asNumber())
            }
        case "bool":
            guard case .bool(let flag) = try element.member("v") else {
                throw JSONDecodingError("expected boolean")
            }
            target.addBool(flag)
        case "str":
            let content = try element.member("v").asString()
            guard case .bool(let dictionary) = try element.member("d") else {
                throw JSONDecodingError("expected boolean")
            }
            if dictionary {
                target.addDictionaryString(content)
            } else {
                target.addString(content)
            }
        case "blob":
            target.addBlob(try fromHex(element.member("hex").asString()))
        default:
            throw JSONDecodingError("unknown element kind")
        }
    }
}

func dump(_ element: NodeTypes) -> JSONValue {
    switch element {
    case .node(let node):
        return object([
            ("k", .string("node")),
            ("t", .string(node.type == .set ? "set" : "list")),
            ("c", .array(node.children.map(dump))),
        ])
    case .blob(let blob):
        return object([("k", .string("blob")), ("hex", .string(toHex(blob.buffer)))])
    case .number(let number):
        return object([("k", .string("num")), ("v", .number(number))])
    case .bool(let flag):
        return object([("k", .string("bool")), ("v", .bool(flag))])
    case .string(let string):
        return object([("k", .string("str")), ("v", .string(string.content)), ("d", .bool(string.dictionary))])
    case .unknownType:
        return object([("k", .string("unknown"))])
    }
}
