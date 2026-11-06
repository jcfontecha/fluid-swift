import FluidJS

/// A message as submitted by a client, before the service sequences it.
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

    public var json: JSONValue {
        var object = JSObject<JSONValue>()
        object["clientId"] = .string(clientId)
        object["clientSequenceNumber"] = .number(Double(clientSequenceNumber))
        object["referenceSequenceNumber"] = .number(Double(referenceSequenceNumber))
        object["contents"] = contents
        return .object(object)
    }
}

/// `ISequencedDocumentMessage` (the fields used at channel level).
public struct SequencedMessage: Equatable, Sendable {
    public var clientId: JSString
    public var clientSequenceNumber: Int
    public var referenceSequenceNumber: Int
    public var sequenceNumber: Int
    public var minimumSequenceNumber: Int
    public var type: JSString
    public var contents: JSONValue

    public init(json: JSONValue) throws {
        clientId = try json.member("clientId").asString()
        clientSequenceNumber = try json.member("clientSequenceNumber").asInt()
        referenceSequenceNumber = try json.member("referenceSequenceNumber").asInt()
        sequenceNumber = try json.member("sequenceNumber").asInt()
        minimumSequenceNumber = try json.member("minimumSequenceNumber").asInt()
        type = try json.member("type").asString()
        contents = try json.member("contents")
    }
}

/// `MessageType` values from protocol-definitions.
public enum MessageType {
    public static let operation: JSString = "op"
}
