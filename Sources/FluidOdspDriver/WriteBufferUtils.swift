import FluidJS

// Ports odsp-driver/src/WriteBufferUtils.ts: serialization of a ZipIt tree into bytes.

/// Buffer class, used to sequentially write data. Used by tree code to serialize a tree into its
/// binary representation. `done()` hands the bytes over exactly once.
public final class WriteBuffer {
    private var data: [UInt8]?

    public init() {
        var storage: [UInt8] = []
        storage.reserveCapacity(4096)
        self.data = storage
    }

    private func push(_ byte: UInt8) throws {
        try fluidAssert(data != nil, 0x225)  // "Data should be there"
        data?.append(byte)
    }

    /// Writes `code` as `lengthArg` little-endian bytes. TS computes the digits with `%` and
    /// `Math.floor`, so values above 2^53 are written with exactly the bits of their `number`.
    public func write(_ codeArg: Double, _ lengthArg: Int = 1) throws {
        var code = codeArg
        var length = lengthArg
        while length > 0 {
            try fluidAssert(code.isFinite, 0x226)
            try push(UInt8(truncatingIfNeeded: Int(code.truncatingRemainder(dividingBy: 256))))
            code = (code / 256).rounded(.down)
            length -= 1
        }
        try fluidAssert(code == 0, 0x226)  // "Should write complete data"
    }

    /// `write(byte)` for a marker code or raw byte.
    @inline(__always)
    func writeByte(_ byte: UInt8) throws {
        try push(byte)
    }

    /// Writes raw bytes, one TS `write(element)` each.
    func writeBytes(_ bytes: ArraySlice<UInt8>) throws {
        try fluidAssert(data != nil, 0x225)  // "Data should be there"
        data?.append(contentsOf: bytes)
    }

    public func done() throws -> [UInt8] {
        try fluidAssert(data != nil, 0x227)  // "Data should be there"
        let buffer = data ?? []
        data = nil
        return buffer
    }
}

// The maps below are the reverse mapping of the marker codes in zipItDataRepresentationUtils.

/// Number of bytes holding a string's length, to marker code.
private let utf8StringBytesToCodeMap: [Int: Int] = [
    0: 13,
    1: 14,
    2: 15,
    4: 16,
]

/// Number of bytes holding a binary blob's length, to marker code.
///
/// Source defect, kept: the 8-byte width maps to 16 (the 32-bit *string* marker), not 36. A blob of
/// 4 GiB or more is therefore not readable by the reader, which accepts 36.
private let binaryBytesToCodeMap: [Int: Int] = [
    0: 32,
    1: 33,
    2: 34,
    4: 35,
    8: 16,
]

/// Number of bytes holding a dictionary string's ID, to marker code.
private let constStringBytesToCodeMap: [Int: Int] = [
    1: 17,
    2: 18,
    4: 19,
]

/// Number of bytes holding an integer, to marker code.
private let integerBytesToCodeMap: [Int: Int] = [
    0: 1,
    1: 3,
    2: 5,
    4: 7,
    8: 9,
]

/// Calculates how many bytes are required to encode a nonnegative integer. This is always a power
/// of 2, so an integer that needs 6 bytes returns 8. 0 returns 0: it is just a marker code.
public func calcLength(_ numArg: Double) -> Int {
    if numArg == 0 {
        return 0
    }
    var num = numArg
    var lengthLen = 0
    while num > 0 {
        num = (num / 256).rounded(.down)
        lengthLen += 1
    }
    var res = 1
    while res < lengthLen {
        res *= 2
    }
    return res
}

/// Serializes a dictionary ("const") string: declared on first use, referenced afterwards. IDs
/// start at 1 and are shared by every node of the tree.
private func serializeDictionaryString(
    _ buffer: WriteBuffer,
    _ content: JSString,
    _ dictionary: inout [JSString: Int]
) throws {
    let idLength: Int
    let id: Int
    if let existing = dictionary[content] {
        id = existing
        idLength = calcLength(Double(id))
    } else {
        let data = encodeUTF8(content)
        let lengthOfDataLen = calcLength(Double(data.count))

        id = dictionary.count + 1
        idLength = calcLength(Double(id))
        dictionary[content] = id
        let code: MarkerCodes =
            lengthOfDataLen > 1 || idLength > 1 ? .constStringDeclareBig : .constStringDeclare
        // Write marker code for const string.
        try buffer.writeByte(code.rawValue)
        let bytes = try getValueSafely(codeToBytesMap, Int(code.rawValue))
        try fluidAssert(bytes >= lengthOfDataLen, 0x283)  // "Length of data len should fit in the bytes from the map"
        try fluidAssert(bytes >= idLength, 0x284)  // "Length of id should fit in the bytes from the map"
        // Assign and write id for const string.
        try buffer.write(Double(id), bytes)
        // Write length of const string.
        try buffer.write(Double(data.count), bytes)
        // Write const string data.
        try buffer.writeBytes(data[...])
    }
    // Write marker code, then the id of the const string.
    try buffer.write(Double(getValueSafely(constStringBytesToCodeMap, idLength)))
    try buffer.write(Double(id), idLength)
}

private func serializeString(_ buffer: WriteBuffer, _ content: JSString) throws {
    try serializeBlob(buffer, encodeUTF8(content)[...], utf8StringBytesToCodeMap)
}

/// Serializes bytes with a marker for the width of their length. (The TS comment calls the data a
/// base64 string; the bytes are written raw.)
private func serializeBlob(
    _ buffer: WriteBuffer,
    _ data: ArraySlice<UInt8>,
    _ codeMap: [Int: Int] = binaryBytesToCodeMap
) throws {
    let lengthOfDataLen = calcLength(Double(data.count))
    // Write marker code.
    try buffer.write(Double(getValueSafely(codeMap, lengthOfDataLen)))
    // Write actual data if length greater than 0, otherwise the marker code is enough.
    if lengthOfDataLen > 0 {
        try buffer.write(Double(data.count), lengthOfDataLen)
        try buffer.writeBytes(data)
    }
}

private func serializeNodeCore(
    _ buffer: WriteBuffer,
    _ nodeCore: NodeCore,
    _ dictionary: inout [JSString: Int]
) throws {
    for child in nodeCore.nodes {
        switch child {
        case .node(let node):
            // A tree node starts and ends with set/list start and end marker codes.
            try buffer.writeByte(node.type.startCode.rawValue)
            try serializeNodeCore(buffer, node, &dictionary)
            try buffer.writeByte(node.type.endCode.rawValue)
        case .blob(let blob):
            try serializeBlob(buffer, blob.buffer)
        case .number(let number):
            // Calculate the length in which the integer will be stored.
            let len = calcLength(number)
            // Write the marker code for that length, then the number itself unless it is 0.
            try buffer.write(Double(getValueSafely(integerBytesToCodeMap, len)))
            if len > 0 {
                try buffer.write(number, len)
            }
        case .bool(let bool):
            try buffer.writeByte(bool ? MarkerCodes.boolTrue.rawValue : MarkerCodes.boolFalse.rawValue)
        case .string(let element):
            if element.dictionary {
                try serializeDictionaryString(buffer, element.content, &dictionary)
            } else {
                try serializeString(buffer, element.content)
            }
        case .unknownType:
            throw OdspSnapshotError.assertionFailed(code: 0x3dd)  // "Unsupported node type"
        }
    }
}

public class NodeCoreSerializer: NodeCore {
    public init() {
        super.init(.set)
    }

    public func serialize(_ buffer: WriteBuffer) throws {
        var dictionary: [JSString: Int] = [:]
        try serializeNodeCore(buffer, self, &dictionary)
    }
}

public final class TreeBuilderSerializer: NodeCoreSerializer {
    public func serialize() throws -> [UInt8] {
        let buffer = WriteBuffer()
        try super.serialize(buffer)
        return try buffer.done()
    }
}
