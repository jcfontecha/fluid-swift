import FluidJS

/// Phase-0 submitted envelope. Received backing fields are retained and known edits replace
/// properties in place, preserving JS key order and unknown fields.
public struct UnsequencedMessage: Equatable, Sendable {
    public var clientId: JSString
    public var clientSequenceNumber: Int
    public var referenceSequenceNumber: Int
    public var contents: JSONValue

    public init(clientId: JSString, clientSequenceNumber: Int, referenceSequenceNumber: Int, contents: JSONValue) {
        self.clientId = clientId
        self.clientSequenceNumber = clientSequenceNumber
        self.referenceSequenceNumber = referenceSequenceNumber
        self.contents = contents
    }

    public init(json: JSONValue) throws {
        clientId = try json.member("clientId").asString()
        clientSequenceNumber = try decodeInt(json.member("clientSequenceNumber"))
        referenceSequenceNumber = try decodeInt(json.member("referenceSequenceNumber"))
        contents = try json.member("contents")
        received = json
    }
    private var received: JSONValue?

    public var json: JSONValue {
        var object = switch received { case .object(let value): value; default: JSObject<JSONValue>() }
        object["clientId"] = .string(clientId)
        object["clientSequenceNumber"] = .number(Double(clientSequenceNumber))
        object["referenceSequenceNumber"] = .number(Double(referenceSequenceNumber))
        object["contents"] = contents
        return .object(object)
    }
}
/// Phase-0 harness envelope (timestamp is not supplied by the mock sequencer).
/// Immutable fields and original backing JSON preserve received metadata and future fields.
/// Real service messages use ISequencedDocumentMessage.
public struct SequencedMessage: Equatable, Sendable {
    public let clientId: JSString
    public let clientSequenceNumber: Int
    public let referenceSequenceNumber: Int
    public let sequenceNumber: Int
    public let minimumSequenceNumber: Int
    public let type: JSString
    public let contents: JSONValue

    public let json: JSONValue

    public init(json: JSONValue) throws {
        self.json = json
        clientId = try json.member("clientId").asString()
        clientSequenceNumber = try json.member("clientSequenceNumber").asInt()
        referenceSequenceNumber = try json.member("referenceSequenceNumber").asInt()
        sequenceNumber = try json.member("sequenceNumber").asInt()
        minimumSequenceNumber = try json.member("minimumSequenceNumber").asInt()
        type = try json.member("type").asString()
        contents = try json.member("contents")
    }
}

