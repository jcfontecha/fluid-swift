import FluidJS

/// A validated received value. Every model retains its complete original JSON object, including
/// unknown fields, explicit nulls in opaque fields, and property order. Typed fields are read-only
/// so they cannot diverge from that backing store. Construct authored values through init(json:).
public protocol DriverJSONValue: Sendable {
    init(json: JSONValue) throws
    var json: JSONValue { get }
}

func decodeBool(_ value: JSONValue) throws -> Bool {
    guard case .bool(let result) = value else { throw JSONDecodingError("expected boolean") }
    return result
}
func decodeInt(_ value: JSONValue) throws -> Int {
    let result = try value.asInt()
    guard (-9_007_199_254_740_991...9_007_199_254_740_991).contains(result) else {
        throw JSONDecodingError("integer outside JS safe range")
    }
    return result
}
func decodeTrue(_ value: JSONValue) throws -> Bool {
    guard try decodeBool(value) else { throw JSONDecodingError("expected true") }
    return true
}
func decodeLiteral(_ value: JSONValue, _ expected: Int) throws -> Int {
    guard try value.asInt() == expected else { throw JSONDecodingError("incorrect discriminator") }
    return expected
}
func decodeNullableString(_ value: JSONValue) throws -> JSString? {
    if value == .null { return nil }
    return try value.asString()
}
func decodeMap<T>(_ value: JSONValue, _ decode: (JSONValue) throws -> T) throws -> JSObject<T> {
    var result = JSObject<T>()
    for (key, child) in try value.asObject().entries { result[key] = try decode(child) }
    return result
}
