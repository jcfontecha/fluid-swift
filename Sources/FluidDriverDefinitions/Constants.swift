import FluidJS

public enum ConnectionMode: String, CaseIterable, Sendable, DriverJSONValue {
    case write = "write"
    case read = "read"
    public init(json: JSONValue) throws {
        guard let value = Self(rawValue: try json.asString().description) else { throw JSONDecodingError("unknown ConnectionMode") }
        self = value
    }
    public var json: JSONValue { .string(JSString(rawValue)) }
}

public enum MessageType: String, CaseIterable, Sendable, DriverJSONValue {
    case noOp = "noop"
    case clientJoin = "join"
    case clientLeave = "leave"
    case propose = "propose"
    case reject = "reject"
    case accept = "accept"
    case summarize = "summarize"
    case summaryAck = "summaryAck"
    case summaryNack = "summaryNack"
    case operationValue = "op"
    case noClient = "noClient"
    case roundTrip = "tripComplete"
    case control = "control"
    public static let operation: JSString = "op"
    public init(json: JSONValue) throws {
        guard let value = Self(rawValue: try json.asString().description) else { throw JSONDecodingError("unknown MessageType") }
        self = value
    }
    public var json: JSONValue { .string(JSString(rawValue)) }

}

public enum SignalType: String, CaseIterable, Sendable, DriverJSONValue {
    case clientJoin = "join"
    case clientLeave = "leave"
    public init(json: JSONValue) throws {
        guard let value = Self(rawValue: try json.asString().description) else { throw JSONDecodingError("unknown SignalType") }
        self = value
    }
    public var json: JSONValue { .string(JSString(rawValue)) }
}

public enum NackErrorType: String, CaseIterable, Sendable, DriverJSONValue {
    case throttlingError = "ThrottlingError"
    case invalidScopeError = "InvalidScopeError"
    case badRequestError = "BadRequestError"
    case limitExceededError = "LimitExceededError"
    public init(json: JSONValue) throws {
        guard let value = Self(rawValue: try json.asString().description) else { throw JSONDecodingError("unknown NackErrorType") }
        self = value
    }
    public var json: JSONValue { .string(JSString(rawValue)) }
}

public enum ScopeType: String, CaseIterable, Sendable, DriverJSONValue {
    case docRead = "doc:read"
    case docWrite = "doc:write"
    case summaryWrite = "summary:write"
    public init(json: JSONValue) throws {
        guard let value = Self(rawValue: try json.asString().description) else { throw JSONDecodingError("unknown ScopeType") }
        self = value
    }
    public var json: JSONValue { .string(JSString(rawValue)) }
}

public enum FileMode: String, CaseIterable, Sendable, DriverJSONValue {
    case file = "100644"
    case executable = "100755"
    case directory = "040000"
    case symlink = "120000"
    public init(json: JSONValue) throws {
        guard let value = Self(rawValue: try json.asString().description) else { throw JSONDecodingError("unknown FileMode") }
        self = value
    }
    public var json: JSONValue { .string(JSString(rawValue)) }
}

public enum TreeEntry: String, CaseIterable, Sendable, DriverJSONValue {
    case blob = "Blob"
    case tree = "Tree"
    case attachment = "Attachment"
    public init(json: JSONValue) throws {
        guard let value = Self(rawValue: try json.asString().description) else { throw JSONDecodingError("unknown TreeEntry") }
        self = value
    }
    public var json: JSONValue { .string(JSString(rawValue)) }
}

public enum BlobEncoding: String, CaseIterable, Sendable, DriverJSONValue {
    case utf8 = "utf-8"
    case base64 = "base64"
    public init(json: JSONValue) throws {
        guard let value = Self(rawValue: try json.asString().description) else { throw JSONDecodingError("unknown BlobEncoding") }
        self = value
    }
    public var json: JSONValue { .string(JSString(rawValue)) }
}

public enum FetchSource: String, CaseIterable, Sendable, DriverJSONValue {
    case `default` = "default"
    case noCache = "noCache"
    public init(json: JSONValue) throws {
        guard let value = Self(rawValue: try json.asString().description) else { throw JSONDecodingError("unknown FetchSource") }
        self = value
    }
    public var json: JSONValue { .string(JSString(rawValue)) }
}

public typealias IsoDate = JSString
public let fiveDaysMs = 432_000_000

extension JSString: DriverJSONValue {
    public init(json: JSONValue) throws { self = try json.asString() }
    public var json: JSONValue { .string(self) }
}

public enum LoaderCachingPolicy: Int, Sendable, DriverJSONValue {
    case noCaching = 0, prefetch = 1
    public init(json: JSONValue) throws {
        guard let value = Self(rawValue: try json.asInt()) else { throw JSONDecodingError("invalid caching policy") }
        self = value
    }
    public var json: JSONValue { .number(Double(rawValue)) }
}

/// TS literal type FiveDaysMs; unlike a general Int it only accepts the required GC limit.
public struct FiveDaysMs: DriverJSONValue {
    public init(json: JSONValue) throws { _ = try decodeLiteral(json, fiveDaysMs) }
    public var json: JSONValue { .number(Double(fiveDaysMs)) }
}
