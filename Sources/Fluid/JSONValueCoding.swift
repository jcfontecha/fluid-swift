internal import FluidJS

/// `Codable` straight to and from the port's `JSONValue`, with JS number semantics: every number
/// is a `Double`, so an integer must be exact in a `Double` and at most 2^53 in magnitude
/// (`Number.MAX_SAFE_INTEGER` + 1). Foundation's `JSONEncoder` is never involved (ARCHITECTURE.md
/// section 3). Object properties keep the order the value encodes them in.
enum JSONValueCoding {
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let node = EncodingNode()
        try value.encode(to: ValueEncoder(node: node, codingPath: []))
        return node.json
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try T(from: ValueDecoder(value: value, codingPath: []))
    }
}

/// 2^53: integers beyond it are not all representable as JS numbers.
private let maxSafeMagnitude: UInt64 = 1 << 53

private struct IndexKey: CodingKey {
    let intValue: Int?
    let stringValue: String

    init(_ index: Int) {
        intValue = index
        stringValue = String(index)
    }

    init?(stringValue: String) {
        return nil
    }

    init?(intValue: Int) {
        self.init(intValue)
    }
}

private struct SuperKey: CodingKey {
    let stringValue = "super"
    let intValue: Int? = nil

    init() {}

    init?(stringValue: String) {
        return nil
    }

    init?(intValue: Int) {
        return nil
    }
}

// MARK: - Encoding

/// One value under construction. Containers write into it by reference, so a nested container
/// keeps filling the same node after the call that made it returns.
private final class EncodingNode {
    enum Kind {
        case empty
        case value(JSONValue)
        case object
        case array
    }

    var kind = Kind.empty
    var properties: [(key: String, node: EncodingNode)] = []
    var elements: [EncodingNode] = []

    /// A value whose `encode(to:)` wrote nothing is `{}`, as with `JSONEncoder`.
    var json: JSONValue {
        switch kind {
        case .empty:
            return .object(JSObject())
        case .value(let value):
            return value
        case .object:
            var object = JSObject<JSONValue>()
            for (key, node) in properties {
                object[JSString(key)] = node.json
            }
            return .object(object)
        case .array:
            return .array(elements.map(\.json))
        }
    }

    func makeObject() {
        if case .object = kind {
            return
        }
        kind = .object
    }

    func makeArray() {
        if case .array = kind {
            return
        }
        kind = .array
    }

    func property(_ key: String) -> EncodingNode {
        let node = EncodingNode()
        properties.append((key, node))
        return node
    }

    func element() -> EncodingNode {
        let node = EncodingNode()
        elements.append(node)
        return node
    }
}

private struct ValueEncoder: Encoder {
    let node: EncodingNode
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        node.makeObject()
        return KeyedEncodingContainer(KeyedEncoder<Key>(node: node, codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        node.makeArray()
        return UnkeyedEncoder(node: node, codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleValueEncoder(node: node, codingPath: codingPath)
    }
}

private struct KeyedEncoder<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let node: EncodingNode
    let codingPath: [any CodingKey]

    mutating func encodeNil(forKey key: Key) throws {
        node.property(key.stringValue).kind = .value(.null)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try value.encode(to: ValueEncoder(node: node.property(key.stringValue), codingPath: codingPath + [key]))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        ValueEncoder(node: node.property(key.stringValue), codingPath: codingPath + [key]).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        ValueEncoder(node: node.property(key.stringValue), codingPath: codingPath + [key]).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        ValueEncoder(node: node.property(SuperKey().stringValue), codingPath: codingPath + [SuperKey()])
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        ValueEncoder(node: node.property(key.stringValue), codingPath: codingPath + [key])
    }
}

private struct UnkeyedEncoder: UnkeyedEncodingContainer {
    let node: EncodingNode
    let codingPath: [any CodingKey]
    var count: Int { node.elements.count }

    mutating func encodeNil() throws {
        node.element().kind = .value(.null)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let path = codingPath + [IndexKey(count)]
        try value.encode(to: ValueEncoder(node: node.element(), codingPath: path))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let path = codingPath + [IndexKey(count)]
        return ValueEncoder(node: node.element(), codingPath: path).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let path = codingPath + [IndexKey(count)]
        return ValueEncoder(node: node.element(), codingPath: path).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        let path = codingPath + [IndexKey(count)]
        return ValueEncoder(node: node.element(), codingPath: path)
    }
}

/// Primitives are encoded here; every other type encodes itself through `encode(to:)`.
private struct SingleValueEncoder: SingleValueEncodingContainer {
    let node: EncodingNode
    let codingPath: [any CodingKey]

    mutating func encodeNil() throws {
        node.kind = .value(.null)
    }

    mutating func encode(_ value: Bool) throws {
        node.kind = .value(.bool(value))
    }

    mutating func encode(_ value: String) throws {
        node.kind = .value(.string(JSString(value)))
    }

    mutating func encode(_ value: Double) throws {
        guard value.isFinite else {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: codingPath, debugDescription: "A JSON number must be finite."))
        }
        node.kind = .value(.number(value))
    }

    mutating func encode(_ value: Float) throws {
        try encode(Double(value))
    }

    mutating func encode(_ value: Int) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int8) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int16) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int32) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int64) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt8) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt16) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt32) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt64) throws { try encodeInteger(value) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try value.encode(to: ValueEncoder(node: node, codingPath: codingPath))
    }

    private mutating func encodeInteger<T: BinaryInteger>(_ value: T) throws {
        guard value.magnitude <= maxSafeMagnitude else {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: codingPath, debugDescription: "\(value) is not exact as a JS number."))
        }
        node.kind = .value(.number(Double(value)))
    }
}

// MARK: - Decoding

private func typeMismatch(_ type: Any.Type, _ codingPath: [any CodingKey], _ value: JSONValue) -> DecodingError {
    DecodingError.typeMismatch(type, DecodingError.Context(
        codingPath: codingPath, debugDescription: "Expected \(type), found \(value)."))
}

private struct ValueDecoder: Decoder {
    let value: JSONValue
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let object) = value else {
            throw typeMismatch(JSObject<JSONValue>.self, codingPath, value)
        }
        return KeyedDecodingContainer(KeyedDecoder<Key>(object: object, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let elements) = value else {
            throw typeMismatch([JSONValue].self, codingPath, value)
        }
        return UnkeyedDecoder(elements: elements, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleValueDecoder(value: value, codingPath: codingPath)
    }
}

private struct KeyedDecoder<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let object: JSObject<JSONValue>
    let codingPath: [any CodingKey]

    var allKeys: [Key] {
        object.keys.compactMap { Key(stringValue: $0.description) }
    }

    func contains(_ key: Key) -> Bool {
        object[JSString(key.stringValue)] != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        try value(forKey: key) == .null
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try T(from: ValueDecoder(value: value(forKey: key), codingPath: codingPath + [key]))
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try ValueDecoder(value: value(forKey: key), codingPath: codingPath + [key]).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try ValueDecoder(value: value(forKey: key), codingPath: codingPath + [key]).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        ValueDecoder(value: object[JSString(SuperKey().stringValue)] ?? .null, codingPath: codingPath + [SuperKey()])
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        ValueDecoder(value: object[JSString(key.stringValue)] ?? .null, codingPath: codingPath + [key])
    }

    private func value(forKey key: Key) throws -> JSONValue {
        guard let value = object[JSString(key.stringValue)] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath, debugDescription: "No value for \"\(key.stringValue)\"."))
        }
        return value
    }
}

private struct UnkeyedDecoder: UnkeyedDecodingContainer {
    let elements: [JSONValue]
    let codingPath: [any CodingKey]
    private(set) var currentIndex = 0

    init(elements: [JSONValue], codingPath: [any CodingKey]) {
        self.elements = elements
        self.codingPath = codingPath
    }

    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }

    mutating func decodeNil() throws -> Bool {
        guard try peek() == .null else {
            return false
        }
        currentIndex += 1
        return true
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = try nextDecoder()
        return try T(from: decoder)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        try nextDecoder().container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        try nextDecoder().unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        try nextDecoder()
    }

    private func peek() throws -> JSONValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(JSONValue.self, DecodingError.Context(
                codingPath: codingPath + [IndexKey(currentIndex)], debugDescription: "The array has no more elements."))
        }
        return elements[currentIndex]
    }

    private mutating func nextDecoder() throws -> ValueDecoder {
        let decoder = ValueDecoder(value: try peek(), codingPath: codingPath + [IndexKey(currentIndex)])
        currentIndex += 1
        return decoder
    }
}

/// Primitives are decoded here; every other type decodes itself through `init(from:)`.
private struct SingleValueDecoder: SingleValueDecodingContainer {
    let value: JSONValue
    let codingPath: [any CodingKey]

    func decodeNil() -> Bool {
        value == .null
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .bool(let bool) = value else {
            throw typeMismatch(type, codingPath, value)
        }
        return bool
    }

    /// A lone surrogate decodes as U+FFFD.
    func decode(_ type: String.Type) throws -> String {
        guard case .string(let string) = value else {
            throw typeMismatch(type, codingPath, value)
        }
        return string.description
    }

    func decode(_ type: Double.Type) throws -> Double {
        guard case .number(let number) = value else {
            throw typeMismatch(type, codingPath, value)
        }
        return number
    }

    func decode(_ type: Float.Type) throws -> Float {
        Float(try decode(Double.self))
    }

    func decode(_ type: Int.Type) throws -> Int { try decodeInteger(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try decodeInteger(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try decodeInteger(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try decodeInteger(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try decodeInteger(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try decodeInteger(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try decodeInteger(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try decodeInteger(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try decodeInteger(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try decodeInteger(type) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: ValueDecoder(value: value, codingPath: codingPath))
    }

    private func decodeInteger<T: BinaryInteger>(_ type: T.Type) throws -> T {
        let number = try decode(Double.self)
        guard let integer = T(exactly: number) else {
            throw typeMismatch(type, codingPath, value)
        }
        return integer
    }
}
