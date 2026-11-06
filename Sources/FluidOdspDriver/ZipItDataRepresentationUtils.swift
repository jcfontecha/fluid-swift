import FluidJS

// Ports odsp-driver/src/zipItDataRepresentationUtils.ts: the ZipIt typed tree that the compact
// snapshot is made of. See specs/odsp-driver/compact-snapshot.md for the byte grammar.

/// Control codes used by tree serialization / deserialization code. Same as on server.
public enum MarkerCodes: UInt8, Sendable {
    case boolTrue = 11
    case boolFalse = 12

    case stringEmpty = 13
    case string8Length = 14
    case string16Length = 15
    case string32Length = 16

    case constString8Id = 17
    case constString16Id = 18
    case constString32Id = 19
    case constStringDeclare = 20
    case constStringDeclareBig = 21

    case int0 = 1
    case uInt8 = 3
    case uInt16 = 5
    case uInt32 = 7
    case uInt64 = 9
    case int8 = 2
    case int16 = 4
    case int32 = 6
    case int64 = 8

    case binaryEmpty = 32
    case binarySingle8 = 33
    case binarySingle16 = 34
    case binarySingle32 = 35
    case binarySingle64 = 36
}

/// Control codes that mark the start of sections.
public enum MarkerCodesStart: UInt8, Sendable {
    case list = 49
    case set = 51
}

/// Control codes that mark the end of sections.
public enum MarkerCodesEnd: UInt8, Sendable {
    case list = 50
    case set = 52
}

public enum NodeCoreTypes: Sendable {
    case list
    case set

    var startCode: MarkerCodesStart {
        self == .set ? .set : .list
    }

    var endCode: MarkerCodesEnd {
        self == .set ? .set : .list
    }
}

/// Maps a marker code to the number of bytes that follow it (the width of a length, an ID or an
/// integer). Absent codes carry no width and are rejected by `getValueSafely`.
public let codeToBytesMap: [Int: Int] = [
    // Integer code to bytes
    1: 0,
    2: 1,
    3: 1,
    4: 2,
    5: 2,
    6: 4,
    7: 4,
    8: 8,
    9: 8,

    // String code to bytes
    13: 0,
    14: 1,
    15: 2,
    16: 4,

    17: 1,
    18: 2,
    19: 4,

    20: 1,
    21: 4,

    // Binary code to bytes
    32: 0,
    33: 1,
    34: 2,
    35: 4,
    36: 8,
]

/// `codeToBytesMap` as a flat table for the parse loop (-1 = no entry): the same data, indexed by
/// marker code instead of hashed once per element.
private let codeToBytesTable: [Int] = {
    var table = [Int](repeating: -1, count: 256)
    for (code, bytes) in codeToBytesMap {
        table[code] = bytes
    }
    return table
}()

public func getValueSafely(_ map: [Int: Int], _ key: Int) throws -> Int {
    guard let value = map[key] else {
        throw OdspSnapshotError.assertionFailed(code: 0x287)  // "key must exist in the map"
    }
    return value
}

@inline(__always)
func getBytesForCode(_ code: UInt8) throws -> Int {
    let bytes = codeToBytesTable[Int(code)]
    try fluidAssert(bytes >= 0, 0x287)  // "key must exist in the map"
    return bytes
}

/// A binary blob element: one of the leaf types of a tree.
///
/// Ports `BlobCore` with its two subclasses. `BlobDeepCopy` (the writer's owned bytes) and
/// `BlobShallowCopy` (a window onto the `ReadBuffer`) are both an `ArraySlice` here: copy-on-write
/// storage makes a parsed blob zero-copy, and it keeps the caller's buffer alive for as long as the
/// blob is used. `buffer` indices are those of the original storage, not rebased to zero.
public struct BlobCore: Sendable {
    public let buffer: ArraySlice<UInt8>

    /// `new BlobDeepCopy(data)`.
    public init(deepCopy data: ArraySlice<UInt8>) {
        self.buffer = data
    }

    /// `new BlobShallowCopy(data, start, end)`: `start`/`end` are offsets into `data`.
    public init(shallowCopy data: ArraySlice<UInt8>, start: Int, end: Int) {
        self.buffer = data[(data.startIndex + start)..<(data.startIndex + end)]
    }

    /// `BlobShallowCopy.arrayBuffer`: an independent copy of exactly the blob's bytes.
    public var arrayBuffer: [UInt8] {
        Array(buffer)
    }

    /// `BlobShallowCopy.read(buffer, lengthLen)`.
    static func readShallowCopy(_ buffer: ReadBuffer, lengthLen: Int) throws -> BlobCore {
        let length = try buffer.read(lengthLen)
        let pos = buffer.pos
        try buffer.skip(length)
        return BlobCore(shallowCopy: buffer.buffer, start: pos, end: pos + Int(length))
    }
}

/// `IStringElement` / `IStringElementInternal`. A class because the TS object identity matters:
/// dictionary references share one element, and the content of parsed strings is filled in by the
/// batched decode at the end of `load`.
public final class StringElement {
    public internal(set) var content: JSString
    public let dictionary: Bool
    var startPos = 0
    var endPos = 0

    public init(content: JSString, dictionary: Bool) {
        self.content = content
        self.dictionary = dictionary
    }

    /// A string whose bytes are still in the input at `startPos..<endPos`.
    init(dictionary: Bool, startPos: Int, endPos: Int) {
        self.content = JSString(utf16: [])
        self.dictionary = dictionary
        self.startPos = startPos
        self.endPos = endPos
    }
}

/// Leaf and container types supported by a tree:
/// 1. Node (sub-tree) 2. binary blob 3. integer 4. boolean 5. string.
///
/// `unknownType` is the TS `"UnknownType"`: a JS value that is none of the above, which only
/// arises through a `__proto__` key (see `getNodeProps`).
public enum NodeTypes {
    case node(NodeCore)
    case blob(BlobCore)
    case number(Double)
    case bool(Bool)
    case string(StringElement)
    case unknownType

    /// `getNodeType`.
    var nodeType: NodeType {
        switch self {
        case .number:
            return .number
        case .blob:
            return .blobCore
        case .node:
            return .nodeCore
        case .bool:
            return .boolean
        case .string:
            return .string
        case .unknownType:
            return .unknownType
        }
    }
}

/// Pairs of consecutive children (key, value). Ports `iteratePairs`.
public struct NodePairs: Sequence, IteratorProtocol {
    private let children: [NodeTypes]
    private var index = 0

    init(_ children: [NodeTypes]) {
        self.children = children
    }

    public mutating func next() -> (NodeTypes, NodeTypes)? {
        guard index < children.count else {
            return nil
        }
        // `iteratePairs()` asserted an even length (0x22b "Should be a pair" cannot fire).
        let pair = (children[index], children[index + 1])
        index += 2
        return pair
    }
}

/// Node - node in the tree (non-leaf element of the tree).
public class NodeCore {
    /// The elements of this node in order (TS `nodes`).
    public internal(set) var children: [NodeTypes] = []
    public let type: NodeCoreTypes

    public init(_ type: NodeCoreTypes = .set) {
        self.type = type
    }

    public var nodes: [NodeTypes] {
        children
    }

    public var length: Int {
        children.count
    }

    public func iteratePairs() throws -> NodePairs {
        try fluidAssert(length % 2 == 0, 0x22c)  // "reading pairs"
        return NodePairs(children)
    }

    /// `children[index]`, which is `undefined` out of range.
    public func get(_ index: Int) -> NodeTypes? {
        index >= 0 && index < children.count ? children[index] : nil
    }

    public func getString(_ index: Int) throws -> JSString {
        try getStringInstance(get(index), "getString should return string")
    }

    public func getMaybeString(_ index: Int) throws -> JSString? {
        try getMaybeStringInstance(get(index))
    }

    public func getBlob(_ index: Int) throws -> BlobCore {
        try assertBlobCoreInstance(get(index), "getBlob should return a blob")
    }

    public func getNode(_ index: Int) throws -> NodeCore {
        try assertNodeCoreInstance(get(index), "getNode should return a node")
    }

    public func getNumber(_ index: Int) throws -> Double {
        try assertNumberInstance(get(index), "getNumber should return a number")
    }

    public func getBool(_ index: Int) throws -> Bool {
        try assertBoolInstance(get(index), "getBool should return a boolean")
    }

    @discardableResult
    public func addNode(_ type: NodeCoreTypes = .set) -> NodeCore {
        let node = NodeCore(type)
        children.append(.node(node))
        return node
    }

    public func addBlob(_ blob: ArraySlice<UInt8>) {
        children.append(.blob(BlobCore(deepCopy: blob)))
    }

    public func addBlob(_ blob: [UInt8]) {
        addBlob(blob[...])
    }

    public func addDictionaryString(_ payload: JSString) {
        children.append(.string(StringElement(content: payload, dictionary: true)))
    }

    public func addString(_ payload: JSString) {
        children.append(.string(StringElement(content: payload, dictionary: false)))
    }

    /// `payload` is a JS `number | undefined`; only nonnegative integers are representable.
    public func addNumber(_ payload: Double?) throws {
        // `Number.isInteger(undefined)` is false.
        try fluidAssert(payload.map { $0.isFinite && $0.rounded(.towardZero) == $0 } ?? false, 0x231)  // "Number should be an integer"
        try fluidAssert(payload.map { $0 >= 0 } ?? false, 0x232)  // "Payload should not be negative"
        children.append(.number(payload ?? 0))
    }

    public func addBool(_ payload: Bool) {
        children.append(.bool(payload))
    }

    /// Reads the length-prefixed bytes of a string; the content is resolved later, in one pass.
    private static func readString(_ buffer: ReadBuffer, _ code: UInt8, dictionary: Bool) throws -> StringElement {
        let lengthLen = try getBytesForCode(code)
        let length = try buffer.read(lengthLen)
        let startPos = buffer.pos
        try buffer.skip(length)
        return StringElement(dictionary: dictionary, startPos: startPos, endPos: buffer.pos)
    }

    /// Load and parse the buffer into a tree.
    func load(_ buffer: ReadBuffer) throws -> TreeBuilderTelemetryProps {
        let (stringsToResolve, durationStructure) = try measure { try loadStructure(buffer) }
        let (_, durationStrings) = try measure { try loadStrings(buffer, stringsToResolve) }
        return TreeBuilderTelemetryProps(durationStructure: durationStructure, durationStrings: durationStrings)
    }

    /// First pass: builds the node structure and records every string's byte range.
    func loadStructure(_ buffer: ReadBuffer) throws -> [StringElement] {
        var stack: [NodeCore] = []
        var stringsToResolve: [StringElement] = []
        var dictionary: [UInt32: StringElement] = [:]
        // `nil` is a JS `undefined` destination, reached by an end marker with nothing to pop.
        var destination: NodeCore? = self

        while !buffer.eof {
            let code = try buffer.readByte()
            switch code {
            case MarkerCodesStart.list.rawValue, MarkerCodesStart.set.rawValue:
                let child = NodeCore(code == MarkerCodesStart.set.rawValue ? .set : .list)
                guard let parent = destination else {
                    throw OdspSnapshotError.undefinedAccess
                }
                parent.children.append(.node(child))
                stack.append(parent)
                destination = child
            case MarkerCodes.constStringDeclare.rawValue, MarkerCodes.constStringDeclareBig.rawValue:
                // A declaration defines a dictionary entry; it is not an element of any node.
                let stringId = try buffer.read(getBytesForCode(code))
                let constString = try NodeCore.readString(buffer, code, dictionary: true)
                stringsToResolve.append(constString)
                dictionary[UInt32(stringId)] = constString
            case MarkerCodes.constString8Id.rawValue, MarkerCodes.constString16Id.rawValue,
                MarkerCodes.constString32Id.rawValue:
                let stringId = try buffer.read(getBytesForCode(code))
                guard let content = dictionary[UInt32(stringId)] else {
                    throw OdspSnapshotError.assertionFailed(code: 0x3de)  // "const string not found"
                }
                guard let parent = destination else {
                    throw OdspSnapshotError.undefinedAccess
                }
                parent.children.append(.string(content))
            case MarkerCodes.stringEmpty.rawValue, MarkerCodes.string8Length.rawValue,
                MarkerCodes.string16Length.rawValue, MarkerCodes.string32Length.rawValue:
                let string = try NodeCore.readString(buffer, code, dictionary: false)
                stringsToResolve.append(string)
                guard let parent = destination else {
                    throw OdspSnapshotError.undefinedAccess
                }
                parent.children.append(.string(string))
            case MarkerCodes.binaryEmpty.rawValue, MarkerCodes.binarySingle8.rawValue,
                MarkerCodes.binarySingle16.rawValue, MarkerCodes.binarySingle32.rawValue,
                MarkerCodes.binarySingle64.rawValue:
                let blob = try BlobCore.readShallowCopy(buffer, lengthLen: getBytesForCode(code))
                guard let parent = destination else {
                    throw OdspSnapshotError.undefinedAccess
                }
                parent.children.append(.blob(blob))
            case MarkerCodes.int0.rawValue:
                guard let parent = destination else {
                    throw OdspSnapshotError.undefinedAccess
                }
                parent.children.append(.number(0))
            case MarkerCodes.uInt8.rawValue, MarkerCodes.uInt16.rawValue, MarkerCodes.uInt32.rawValue,
                MarkerCodes.uInt64.rawValue, MarkerCodes.int8.rawValue, MarkerCodes.int16.rawValue,
                MarkerCodes.int32.rawValue, MarkerCodes.int64.rawValue:
                // The "signed" markers decode exactly like the unsigned ones: 02 ff is 255.
                let value = try buffer.read(getBytesForCode(code))
                guard let parent = destination else {
                    throw OdspSnapshotError.undefinedAccess
                }
                parent.children.append(.number(value))
            case MarkerCodes.boolTrue.rawValue:
                guard let parent = destination else {
                    throw OdspSnapshotError.undefinedAccess
                }
                parent.children.append(.bool(true))
            case MarkerCodes.boolFalse.rawValue:
                guard let parent = destination else {
                    throw OdspSnapshotError.undefinedAccess
                }
                parent.children.append(.bool(false))
            case MarkerCodesEnd.list.rawValue, MarkerCodesEnd.set.rawValue:
                // Not checked: an end marker need not match its start marker, as in TS.
                destination = stack.popLast()
            default:
                throw OdspSnapshotError.invalidCode(Int(code))
            }
        }

        // This also ensures that the stack is empty.
        try fluidAssert(destination === self, 0x3e7)  // "Unpaired start/end list/set markers!"
        return stringsToResolve
    }

    /// Second pass: decodes every string's UTF-8 bytes.
    ///
    /// TS decodes all strings with one call by joining them with NUL and splitting the result. A
    /// string that itself contains NUL breaks that split, and TS's "recovery" can only fail its
    /// assert (0x3ea), so that case is an error here too, never a silent success.
    func loadStrings(_ buffer: ReadBuffer, _ stringsToResolve: [StringElement]) throws {
        var containsNul = false
        let input = buffer.buffer
        for element in stringsToResolve {
            let bytes = input[(input.startIndex + element.startPos)..<(input.startIndex + element.endPos)]
            if bytes.contains(0) {
                containsNul = true
            }
            element.content = decodeUTF8(bytes)
        }
        try fluidAssert(!containsNul, 0x3ea)
    }
}

public struct TreeBuilderTelemetryProps: Sendable {
    /// Milliseconds spent building the node structure.
    public let durationStructure: Double
    /// Milliseconds spent decoding strings.
    public let durationStrings: Double
}

/// TreeBuilder - Root of the tree. Provides loading (and, as `TreeBuilderSerializer`, serialization).
public final class TreeBuilder: NodeCore {
    public static func load(
        _ buffer: ReadBuffer
    ) throws -> (builder: TreeBuilder, telemetryProps: TreeBuilderTelemetryProps) {
        let builder = TreeBuilder()
        let telemetryProps = try builder.load(buffer)
        try fluidAssert(buffer.eof, 0x233)  // "Unexpected data at the end of buffer"
        return (builder, telemetryProps)
    }
}

/// The properties of a node read as a JS `Record<string, NodeTypes>` (`getNodeProps`).
///
/// TS builds a plain object, so a key named `__proto__` is not stored: assigning an object to it
/// replaces the record's prototype, assigning a number or boolean does nothing. Later lookups of
/// an absent property then fall through to that prototype: a `NodeCore` supplies a `children`
/// array and a blob supplies a `data` array. Those are the only property names the snapshot
/// parser reads that any element prototype defines, so they are the only ones reproduced here.
public struct NodeProps {
    private var own: [JSString: NodeTypes] = [:]
    private var inheritedFrom: NodeTypes?

    init(_ node: NodeCore) throws {
        for (keyNode, valueNode) in try node.iteratePairs() {
            let id = try getStringInstance(keyNode, "keynode should be a string")
            try assign(id, valueNode)
        }
    }

    private mutating func assign(_ id: JSString, _ value: NodeTypes) throws {
        guard id == protoKey else {
            own[id] = value
            return
        }
        switch value {
        case .number, .bool:
            break
        case .node, .blob, .string, .unknownType:
            inheritedFrom = value
        }
    }

    public subscript(key: JSString) -> NodeTypes? {
        if let value = own[key] {
            return value
        }
        switch inheritedFrom {
        case .node where key == childrenKey, .blob where key == dataKey:
            return .unknownType
        default:
            return nil
        }
    }
}

private let protoKey: JSString = "__proto__"
private let childrenKey: JSString = "children"
private let dataKey: JSString = "data"

public func getNodeProps(_ node: NodeCore) throws -> NodeProps {
    try NodeProps(node)
}

public func addStringProperty(_ node: NodeCore, _ a: JSString, _ b: JSString) {
    node.addDictionaryString(a)
    node.addString(b)
}

public func addDictionaryStringProperty(_ node: NodeCore, _ a: JSString, _ b: JSString) {
    node.addDictionaryString(a)
    node.addString(b)
}

public func addNumberProperty(_ node: NodeCore, _ a: JSString, _ b: Double?) throws {
    node.addDictionaryString(a)
    try node.addNumber(b)
}

public func addBoolProperty(_ node: NodeCore, _ a: JSString, _ b: Bool) {
    node.addDictionaryString(a)
    node.addBool(b)
}

/// `getMaybeStringInstance`. A missing element is a `TypeError`, as reading `_stringElement` of
/// `undefined` is in TS.
public func getMaybeStringInstance(_ node: NodeTypes?) throws -> JSString? {
    guard let node else {
        throw OdspSnapshotError.undefinedAccess
    }
    if case .string(let element) = node {
        return element.content
    }
    return nil
}

public func getStringInstance(_ node: NodeTypes?, _ message: String) throws -> JSString {
    guard let node else {
        throw OdspSnapshotError.undefinedAccess
    }
    if case .string(let element) = node {
        return element.content
    }
    // The expected type TS reports here is "BlobCore" (a source quirk).
    throw bufferParseException(node, .blobCore, message)
}

public func assertBlobCoreInstance(_ node: NodeTypes?, _ message: String) throws -> BlobCore {
    guard let node else {
        throw OdspSnapshotError.undefinedAccess
    }
    if case .blob(let blob) = node {
        return blob
    }
    throw bufferParseException(node, .blobCore, message)
}

public func assertNodeCoreInstance(_ node: NodeTypes?, _ message: String) throws -> NodeCore {
    guard let node else {
        throw OdspSnapshotError.undefinedAccess
    }
    if case .node(let nodeCore) = node {
        return nodeCore
    }
    throw bufferParseException(node, .nodeCore, message)
}

public func assertNumberInstance(_ node: NodeTypes?, _ message: String) throws -> Double {
    guard let node else {
        throw OdspSnapshotError.undefinedAccess
    }
    if case .number(let number) = node {
        return number
    }
    throw bufferParseException(node, .number, message)
}

public func assertBoolInstance(_ node: NodeTypes?, _ message: String) throws -> Bool {
    guard let node else {
        throw OdspSnapshotError.undefinedAccess
    }
    if case .bool(let bool) = node {
        return bool
    }
    throw bufferParseException(node, .boolean, message)
}

/// `throwBufferParseException`: a non-retryable `incorrectServerResponse`.
func bufferParseException(_ node: NodeTypes, _ expectedNodeType: NodeType, _ message: String) -> OdspSnapshotError {
    .bufferParsing(
        message: "Buffer parsing exception: \(message)", nodeType: node.nodeType, expectedNodeType: expectedNodeType)
}

/// `measure` from odspUtils.ts: the result of `body` and how many milliseconds it took.
func measure<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let clock = ContinuousClock()
    let start = clock.now
    let result = try body()
    let elapsed = start.duration(to: clock.now)
    let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    return (result, milliseconds)
}
