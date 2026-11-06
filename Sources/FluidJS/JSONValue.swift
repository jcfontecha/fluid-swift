/// A JSON value with JavaScript semantics: numbers are `Double`, strings are UTF-16, objects keep
/// JS property order.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(JSString)
    case array([JSONValue])
    case object(JSObject<JSONValue>)
}

public struct JSONDecodingError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

extension JSONValue {
    @inlinable public func member(_ key: JSString) throws -> JSONValue {
        guard let value = try asObject()[key] else {
            throw JSONDecodingError("missing member \"\(key)\"")
        }
        return value
    }

    @inlinable public func asObject() throws -> JSObject<JSONValue> {
        guard case .object(let object) = self else { throw JSONDecodingError("expected object, got \(self)") }
        return object
    }

    @inlinable public func asArray() throws -> [JSONValue] {
        guard case .array(let array) = self else { throw JSONDecodingError("expected array, got \(self)") }
        return array
    }

    @inlinable public func asString() throws -> JSString {
        guard case .string(let string) = self else { throw JSONDecodingError("expected string, got \(self)") }
        return string
    }

    @inlinable public func asNumber() throws -> Double {
        guard case .number(let number) = self else { throw JSONDecodingError("expected number, got \(self)") }
        return number
    }

    /// A number that must be an exactly representable integer (sequence numbers, counts).
    @inlinable public func asInt() throws -> Int {
        let number = try asNumber()
        guard let int = Int(exactly: number) else { throw JSONDecodingError("expected integer, got \(number)") }
        return int
    }
}
