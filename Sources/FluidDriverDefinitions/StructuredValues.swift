import FluidJS

/// Retains the entire received tuple, including unknown nested fields and property order.
public struct QuorumMember: DriverJSONValue {
    public let json: JSONValue
    public let clientId: JSString
    public let client: ISequencedClient
    public init(json: JSONValue) throws {
        let items = try json.asArray()
        guard items.count == 2 else { throw JSONDecodingError("invalid member tuple") }
        clientId = try items[0].asString()
        client = try ISequencedClient(json: items[1])
        self.json = json
    }
}
/// Retains the entire received tuple, including unknown nested fields and property order.
public struct QuorumProposal: DriverJSONValue {
    public let json: JSONValue
    public let sequenceNumber: Int
    public let proposal: ISequencedProposal
    public let rejections: [JSString]
    public init(json: JSONValue) throws {
        let items = try json.asArray()
        guard items.count == 3 else { throw JSONDecodingError("invalid proposal tuple") }
        sequenceNumber = try decodeInt(items[0])
        proposal = try ISequencedProposal(json: items[1])
        rejections = try items[2].asArray().map { try $0.asString() }
        self.json = json
    }
}
/// Retains the entire received tuple, including unknown nested fields and property order.
public struct QuorumValue: DriverJSONValue {
    public let json: JSONValue
    public let key: JSString
    public let proposal: ICommittedProposal
    public init(json: JSONValue) throws {
        let items = try json.asArray()
        guard items.count == 2 else { throw JSONDecodingError("invalid value tuple") }
        key = try items[0].asString()
        proposal = try ICommittedProposal(json: items[1])
        self.json = json
    }
}

public enum SummaryType: Int, CaseIterable, Sendable, DriverJSONValue {
    case tree = 1, blob = 2, handle = 3, attachment = 4
    public init(json: JSONValue) throws {
        guard let value = Self(rawValue: try json.asInt()) else { throw JSONDecodingError("invalid summary type") }
        self = value
    }
    public var json: JSONValue { .number(Double(rawValue)) }
}
public enum SummaryTypeNoHandle: Int, CaseIterable, Sendable, DriverJSONValue {
    case tree = 1, blob = 2, attachment = 4
    public init(json: JSONValue) throws {
        guard let value = Self(rawValue: try json.asInt()) else { throw JSONDecodingError("invalid handle type") }
        self = value
    }
    public var json: JSONValue { .number(Double(rawValue)) }
}

/// Uint8Array serializes as an object with numeric keys, not a JSON array or base64 string.
public enum SummaryBlobContent: Sendable, DriverJSONValue {
    case text(JSString)
    case binary([UInt8])
    public init(json: JSONValue) throws {
        if case .string(let text) = json { self = .text(text); return }
        let object = try json.asObject()
        var bytes: [UInt8] = []
        for (index, entry) in object.entries.enumerated() {
            guard entry.key == JSString(String(index)), let byte = UInt8(exactly: try entry.value.asNumber()) else {
                throw JSONDecodingError("invalid Uint8Array JSON")
            }
            bytes.append(byte)
        }
        self = .binary(bytes)
    }
    public var json: JSONValue {
        switch self {
        case .text(let text): return .string(text)
        case .binary(let bytes):
            var object = JSObject<JSONValue>()
            for (index, byte) in bytes.enumerated() { object[JSString(String(index))] = .number(Double(byte)) }
            return .object(object)
        }
    }
}

/// JSON.stringify(Map) is `{}`: JSON alone cannot recover its entries or ArrayBuffers.
/// Native consumers retain the buffers here; received JSON is preserved verbatim separately.
public struct SnapshotBlobContents: DriverJSONValue {
    public let json: JSONValue
    public let buffers: JSObject<[UInt8]>
    public init(json: JSONValue) throws {
        _ = try json.asObject()
        self.json = json
        buffers = JSObject()
    }
    public init(buffers: JSObject<[UInt8]>) {
        self.buffers = buffers
        json = .object(JSObject())
    }
}

/// Storage tree entry retains all received properties; the discriminator validates its value.
public struct ITreeEntry: DriverJSONValue {
    public indirect enum Value: Sendable {
        case blob(IBlob), tree(ITree), attachment(IAttachment)
    }
    public let json: JSONValue
    public let path: JSString
    public let mode: FileMode
    public let type: TreeEntry
    public let value: Value
    public init(json: JSONValue) throws {
        path = try json.member("path").asString()
        mode = try FileMode(json: json.member("mode"))
        type = try TreeEntry(json: json.member("type"))
        let child = try json.member("value")
        switch type {
        case .blob: value = .blob(try IBlob(json: child))
        case .tree: value = .tree(try ITree(json: child))
        case .attachment: value = .attachment(try IAttachment(json: child))
        }
        self.json = json
    }
}

/// Descriptive alias for callers distinguishing the tree/handle union from ISummaryTree.
public typealias SummaryTreeReference = SummaryTree
