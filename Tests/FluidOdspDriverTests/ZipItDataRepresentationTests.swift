import FluidJS
import Testing

@testable import FluidOdspDriver

// Ports src/test/zipItDataRepresentationTests.spec.ts, plus the byte grammar of
// specs/odsp-driver/compact-snapshot.md (unsigned markers, declarations that are not elements,
// invalid codes, unbalanced markers, embedded NUL strings).

func bytes(_ hex: String) -> [UInt8] {
    hex.split(separator: " ").map { UInt8($0, radix: 16)! }
}

private func compareNodes(_ node1: NodeTypes, _ node2: NodeTypes) {
    switch (node1, node2) {
    case (.node(let a), .node(let b)):
        #expect(a.length == b.length, "Node lengths are not same")
        if a.length == b.length {
            for index in 0..<a.length {
                compareNodes(a.children[index], b.children[index])
            }
        }
    case (.blob(let a), .blob(let b)):
        #expect(a.buffer.elementsEqual(b.buffer), "Blob contents not same")
    case (.number(let a), .number(let b)):
        #expect(a == b, "Number should be equal")
    case (.bool(let a), .bool(let b)):
        #expect(a == b, "Bool value should be equal")
    case (.string(let a), .string(let b)):
        #expect(a.content == b.content, "String contents not same")
    default:
        Issue.record("Node kinds differ: \(node1) vs \(node2)")
    }
}

private func createLongBuffer(_ length: Int) -> [UInt8] {
    (0..<length).map { UInt8(30 + ($0 % 10)) }
}

private func validate(_ builder: TreeBuilderSerializer, length: Int) throws {
    let buffer = try builder.serialize()
    #expect(buffer.count == length, "buffer size not equal")
    let builder2 = try TreeBuilder.load(ReadBuffer(buffer)).builder
    compareNodes(.node(builder), .node(builder2))
}

private func load(_ data: [UInt8]) throws -> TreeBuilder {
    try TreeBuilder.load(ReadBuffer(data)).builder
}

@Suite struct TreeRepresentationTests {
    @Test func empty() throws {
        try validate(TreeBuilderSerializer(), length: 0)
    }

    @Test func singleNode() throws {
        let builder = TreeBuilderSerializer()
        builder.addNode()
        try validate(builder, length: 2)
    }

    @Test func numberZero() throws {
        let builder = TreeBuilderSerializer()
        try builder.addNumber(0)
        try validate(builder, length: 1)
    }

    @Test func number() throws {
        let builder = TreeBuilderSerializer()
        try builder.addNumber(1)
        try validate(builder, length: 1 + 1)
    }

    @Test func bigNumber() throws {
        let builder = TreeBuilderSerializer()
        try builder.addNumber(65536 * 65536)
        // 1 for Marker Code and 8 for representation
        try validate(builder, length: 1 + 8)
    }

    @Test func boolean() throws {
        let builder = TreeBuilderSerializer()
        builder.addBool(true)
        try validate(builder, length: 1)
    }

    @Test func emptyString() throws {
        let builder = TreeBuilderSerializer()
        builder.addString("")
        // 1 for Marker Code is enough for empty string.
        try validate(builder, length: 1)
    }

    @Test func smallString() throws {
        let builder = TreeBuilderSerializer()
        builder.addString("first")
        try validate(builder, length: 2 + 5)
    }

    @Test func loadsFromArraySliceWithNonZeroStartIndex() throws {
        let builder = TreeBuilderSerializer()
        builder.addString("first")
        builder.addBlob(createLongBuffer(3))
        let serialized = try builder.serialize()
        var backing: [UInt8] = [0xAA]
        backing.append(contentsOf: serialized)
        backing.append(0xBB)
        let offsetBuffer = backing[1..<(serialized.count + 1)]
        #expect(offsetBuffer.startIndex == 1, "Test buffer should have a start offset")
        let builder2 = try TreeBuilder.load(ReadBuffer(offsetBuffer)).builder
        compareNodes(.node(builder), .node(builder2))
    }

    @Test func blobsAreSlicesOfTheInputBuffer() throws {
        let builder = TreeBuilderSerializer()
        builder.addBlob(createLongBuffer(5))
        let serialized = try builder.serialize()
        var backing: [UInt8] = [0xAA, 0xAA]
        backing.append(contentsOf: serialized)
        let loaded = try TreeBuilder.load(ReadBuffer(backing[2...])).builder
        let blob = try loaded.getBlob(0)
        #expect(blob.buffer.startIndex == 4, "blob must reference the original storage, not a copy")
        #expect(Array(blob.buffer) == createLongBuffer(5))
        #expect(blob.arrayBuffer == createLongBuffer(5))
    }

    @Test func smallConstString() throws {
        let builder = TreeBuilderSerializer()
        builder.addDictionaryString("first")
        try validate(builder, length: 8 + 2)
    }

    @Test func emptyBuffer() throws {
        let builder = TreeBuilderSerializer()
        builder.addBlob(createLongBuffer(0))
        try validate(builder, length: 1)
    }

    @Test func singleLongBuffer255() throws {
        let builder = TreeBuilderSerializer()
        builder.addBlob(createLongBuffer(255))
        try validate(builder, length: 2 + 255)
    }

    @Test func singleLongBuffer256() throws {
        let builder = TreeBuilderSerializer()
        builder.addBlob(createLongBuffer(256))
        // 1 for Marker Code, 2 for representing length of buffer and 256 for data
        try validate(builder, length: 1 + 2 + 256)
    }

    @Test func singleLongBuffer257() throws {
        let builder = TreeBuilderSerializer()
        builder.addBlob(createLongBuffer(257))
        try validate(builder, length: 1 + 2 + 257)
    }

    @Test func singleLongBuffer() throws {
        let builder = TreeBuilderSerializer()
        builder.addBlob(createLongBuffer(65538))
        try validate(builder, length: 1 + 4 + 65538)
    }

    @Test func twoNode() throws {
        let builder = TreeBuilderSerializer()
        builder.addNode()
        builder.addNode()
        try validate(builder, length: 2 + 2)
    }

    @Test func twoBuffer() throws {
        let builder = TreeBuilderSerializer()
        builder.addString("first")
        builder.addString("Seventeen")
        try validate(builder, length: 2 + 5 + 2 + 9)
    }

    @Test func singleNodeAndBuffer() throws {
        let builder = TreeBuilderSerializer()
        builder.addNode().addString("first")
        try validate(builder, length: 2 + 2 + 5)
    }

    @Test func singleNodeAndConstString() throws {
        let builder = TreeBuilderSerializer()
        builder.addNode().addDictionaryString("first")
        try validate(builder, length: 2 + 8 + 2)
    }

    @Test func moreThanOneByteLengthString() throws {
        let builder = TreeBuilderSerializer()
        builder.addNode().addDictionaryString(JSString(String(repeating: "a", count: 257)))
        try validate(builder, length: 2 + 9 + 257 + 2)
    }

    @Test func complexTreeStructure() throws {
        let builder = TreeBuilderSerializer()
        builder.addString("first")
        let node = builder.addNode()
        node.addString("second")
        node.addString("third")
        let node2 = node.addNode()
        node2.addString("fourth")
        try validate(builder, length: 2 + 5 + 2 + 2 + 6 + 2 + 5 + 2 + 2 + 6)
    }
}

@Suite struct NodeTypeAssertionTests {
    private func parseError(_ message: String, _ nodeType: NodeType, _ expected: NodeType) -> OdspSnapshotError {
        .bufferParsing(
            message: "Buffer parsing exception: \(message)", nodeType: nodeType, expectedNodeType: expected)
    }

    @Test func blobInstance() throws {
        let blob = NodeTypes.blob(BlobCore(shallowCopy: [], start: 0, end: 0))
        _ = try assertBlobCoreInstance(blob, "should be a blob")
        #expect(throws: parseError("should be a blob", .number, .blobCore)) {
            _ = try assertBlobCoreInstance(.number(5), "should be a blob")
        }
    }

    @Test func nodeInstance() throws {
        _ = try assertNodeCoreInstance(.node(NodeCore()), "should be a node")
        #expect(throws: parseError("should be a node", .blobCore, .nodeCore)) {
            _ = try assertNodeCoreInstance(.blob(BlobCore(shallowCopy: [], start: 0, end: 0)), "should be a node")
        }
    }

    @Test func numberInstance() throws {
        _ = try assertNumberInstance(.number(5), "should be a number")
        #expect(throws: parseError("should be a number", .blobCore, .number)) {
            _ = try assertNumberInstance(.blob(BlobCore(shallowCopy: [], start: 0, end: 0)), "should be a number")
        }
    }

    @Test func boolInstance() throws {
        _ = try assertBoolInstance(.bool(true), "should be a boolean")
        #expect(throws: parseError("should be a bool", .number, .boolean)) {
            _ = try assertBoolInstance(.number(0), "should be a bool")
        }
    }

    @Test func stringInstanceReportsBlobCoreAsExpectedType() throws {
        // TS passes "BlobCore" as the expected type of getStringInstance (a source quirk).
        #expect(throws: parseError("should be a string", .boolean, .blobCore)) {
            _ = try getStringInstance(.bool(true), "should be a string")
        }
        let element = NodeTypes.string(StringElement(content: "x", dictionary: false))
        #expect(try getStringInstance(element, "unused") == "x")
    }

    @Test func missingElementIsATypeError() {
        #expect(throws: OdspSnapshotError.undefinedAccess) {
            _ = try assertNumberInstance(nil, "x")
        }
        #expect(throws: OdspSnapshotError.undefinedAccess) {
            _ = try getStringInstance(nil, "x")
        }
        #expect(throws: OdspSnapshotError.undefinedAccess) {
            _ = try NodeCore().getMaybeString(0)
        }
    }

    @Test func typedGettersOnNodeCore() throws {
        let node = NodeCore()
        node.addString("s")
        try node.addNumber(7)
        node.addBool(false)
        node.addBlob([1, 2])
        node.addNode()
        #expect(try node.getString(0) == "s")
        #expect(try node.getMaybeString(1) == nil)
        #expect(try node.getNumber(1) == 7)
        #expect(try node.getBool(2) == false)
        #expect(try node.getBlob(3).buffer.elementsEqual([1, 2]))
        #expect(try node.getNode(4).length == 0)
        #expect(node.get(5) == nil)
    }
}

@Suite struct ReadBufferTests {
    @Test func readsLittleEndianUnsignedMagnitudes() throws {
        let buffer = ReadBuffer([0x01, 0x02, 0x03, 0x04, 0xFF, 0xFF])
        #expect(try buffer.read() == 1)
        #expect(try buffer.read(2) == 0x0302)
        #expect(try buffer.read(1) == 4)
        #expect(try buffer.read(2) == 65535)
        #expect(buffer.eof)
        #expect(buffer.pos == 6)
        #expect(buffer.length == 6)
    }

    @Test func readPastEndFails0x223() {
        let buffer = ReadBuffer([0x01])
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x223)) {
            _ = try buffer.read(2)
        }
    }

    @Test func skipPastEndFails0x3dc() {
        let buffer = ReadBuffer([0x01, 0x02])
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x3dc)) {
            try buffer.skip(3)
        }
    }

    @Test func resetRewinds() throws {
        let buffer = ReadBuffer([0x09])
        _ = try buffer.read()
        buffer.reset()
        #expect(buffer.pos == 0)
        #expect(!buffer.eof)
    }
}

@Suite struct MarkerGrammarTests {
    @Test func signedLookingMarkersDecodeUnsigned() throws {
        // 02 ff is 255, not -1; every Int marker equals its UInt twin.
        let tree = try load(
            bytes(
                "31 02 ff 03 ff 04 ff ff 05 ff ff 06 ff ff ff ff 07 ff ff ff ff 32"))
        let list = try tree.getNode(0)
        #expect(
            list.children.map { if case .number(let n) = $0 { n } else { -1 } }
                == [255, 255, 65535, 65535, 4294967295, 4294967295])
    }

    @Test func sixtyFourBitIntegersAccumulateAsDouble() throws {
        let tree = try load(bytes("31 08 ff ff ff ff ff ff ff ff 09 00 00 00 00 01 00 00 00 32"))
        let list = try tree.getNode(0)
        #expect(try list.getNumber(0) == 18446744073709551616.0)
        #expect(try list.getNumber(1) == 4294967296)
    }

    @Test func zeroTrueFalseAndEmptyValues() throws {
        let tree = try load(bytes("31 01 0b 0c 0d 20 32"))
        let list = try tree.getNode(0)
        #expect(try list.getNumber(0) == 0)
        #expect(try list.getBool(1) == true)
        #expect(try list.getBool(2) == false)
        #expect(try list.getString(3) == "")
        #expect(try list.getBlob(4).buffer.isEmpty)
    }

    @Test func spec_scalarContrastExample() throws {
        let tree = try load(bytes("31 0e 02 c3 a9 21 02 00 ff 05 00 01 0b 32"))
        let list = try tree.getNode(0)
        #expect(list.type == .list)
        #expect(list.length == 4)
        #expect(try list.getString(0) == "é")
        #expect(Array(try list.getBlob(1).buffer) == [0x00, 0xFF])
        #expect(try list.getNumber(2) == 256)
        #expect(try list.getBool(3) == true)
    }

    @Test func stringLengthWidthsAndDictionaryReferences() throws {
        let tree = try load(bytes("0f 01 00 61 10 01 00 00 00 62 14 07 01 63 11 07 12 07 00 13 07 00 00 00"))
        #expect(tree.length == 5)
        #expect(try tree.getString(0) == "a")
        #expect(try tree.getString(1) == "b")
        #expect(try tree.getString(2) == "c")
        #expect(try tree.getString(3) == "c")
        #expect(try tree.getString(4) == "c")
    }

    @Test func dictionaryDeclarationIsNotAnElement() throws {
        let tree = try load(bytes("14 01 01 78 11 01 11 01"))
        #expect(tree.length == 2)
        guard case .string(let first) = try #require(tree.get(0)), case .string(let second) = try #require(tree.get(1)) else {
            Issue.record("expected two string elements")
            return
        }
        #expect(first === second, "references share the declared string object")
        #expect(first.dictionary)
    }

    @Test func bigDictionaryDeclaration() throws {
        let tree = try load(bytes("15 00 01 00 00 01 00 00 00 78 12 00 01"))
        #expect(tree.length == 1)
        #expect(try tree.getString(0) == "x")
    }

    @Test func redeclaringAnIDReplacesLaterReferencesOnly() throws {
        let tree = try load(bytes("14 01 01 61 11 01 14 01 01 62 11 01"))
        #expect(tree.length == 2)
        #expect(try tree.getString(0) == "a")
        #expect(try tree.getString(1) == "b")
    }

    @Test func sixtyFourBitBlobLengthMarkerIsAccepted() throws {
        let tree = try load(bytes("24 02 00 00 00 00 00 00 00 aa bb"))
        #expect(Array(try tree.getBlob(0).buffer) == [0xAA, 0xBB])
    }

    @Test func everyCodeOutsideTheGrammarIsInvalid() {
        let valid: Set<Int> = Set(1...9).union(0x0B...0x15).union(0x20...0x24).union(0x31...0x34)
        for code in 0...255 where !valid.contains(code) {
            #expect(throws: OdspSnapshotError.invalidCode(code), "code \(code)") {
                _ = try load([UInt8(code)])
            }
        }
    }

    @Test func unbalancedMarkers() throws {
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x3e7)) { _ = try load(bytes("31")) }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x3e7)) { _ = try load(bytes("32")) }
        // Popping past the root leaves no destination: the next element is a TypeError in TS.
        #expect(throws: OdspSnapshotError.undefinedAccess) { _ = try load(bytes("32 01")) }
        #expect(throws: OdspSnapshotError.undefinedAccess) { _ = try load(bytes("32 31")) }
    }

    @Test func listAndSetEndMarkersAreNotMatched() throws {
        let tree = try load(bytes("31 34 33 32"))
        #expect(tree.length == 2)
        #expect(try tree.getNode(0).type == .list)
        #expect(try tree.getNode(1).type == .set)
    }

    @Test func missingDictionaryEntry() {
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x3de)) { _ = try load(bytes("11 01")) }
    }

    @Test func truncatedInput() {
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x223)) { _ = try load(bytes("0e")) }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x3dc)) { _ = try load(bytes("0e 05 61")) }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x3dc)) { _ = try load(bytes("21 03 01")) }
    }

    @Test func embeddedNulStringFailsLikeTheOracle() {
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x3ea)) { _ = try load(bytes("0e 03 61 00 62")) }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x3ea)) { _ = try load(bytes("14 01 01 00 11 01")) }
    }

    @Test func invalidUTF8IsReplacedPerMaximalSubpart() throws {
        let tree = try load(bytes("0e 07 e2 82 41 f0 9f 98 ff"))
        // e2 82 (truncated 3-byte) -> one U+FFFD; 'A'; f0 9f 98 (truncated 4-byte) -> one U+FFFD; ff -> U+FFFD
        #expect(try tree.getString(0).utf16 == [0xFFFD, 0x41, 0xFFFD, 0xFFFD])
    }

    @Test func astralCharactersBecomeSurrogatePairs() throws {
        let tree = try load(bytes("0e 04 f0 9f 98 80"))
        #expect(try tree.getString(0).utf16 == [0xD83D, 0xDE00])
    }

    @Test func structureErrorsWinOverStringErrors() {
        // The NUL string would fail 0x3ea, but the unbalanced start marker is detected first.
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x3e7)) {
            _ = try load(bytes("31 0e 01 00"))
        }
    }

    @Test func oddPairCountFails0x22c() throws {
        let node = NodeCore()
        node.addString("only")
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x22c)) {
            _ = try node.iteratePairs()
        }
    }

    @Test func nodePropsRequireStringKeys() throws {
        let node = NodeCore()
        try node.addNumber(1)
        try node.addNumber(2)
        #expect(
            throws: OdspSnapshotError.bufferParsing(
                message: "Buffer parsing exception: keynode should be a string", nodeType: .number,
                expectedNodeType: .blobCore)
        ) {
            _ = try getNodeProps(node)
        }
    }

    @Test func nodePropsLaterDuplicateWins() throws {
        let node = NodeCore()
        node.addString("k")
        try node.addNumber(1)
        node.addString("k")
        try node.addNumber(2)
        let props = try getNodeProps(node)
        guard case .number(let value) = try #require(props["k"]) else {
            Issue.record("expected number")
            return
        }
        #expect(value == 2)
    }
}

@Suite struct WriterEncodingTests {
    private func serialize(_ build: (TreeBuilderSerializer) throws -> Void) throws -> [UInt8] {
        let builder = TreeBuilderSerializer()
        try build(builder)
        return try builder.serialize()
    }

    @Test func integerWidthsRoundUpToPowersOfTwo() throws {
        #expect(try serialize { try $0.addNumber(0) } == bytes("01"))
        #expect(try serialize { try $0.addNumber(255) } == bytes("03 ff"))
        #expect(try serialize { try $0.addNumber(256) } == bytes("05 00 01"))
        #expect(try serialize { try $0.addNumber(65535) } == bytes("05 ff ff"))
        #expect(try serialize { try $0.addNumber(65536) } == bytes("07 00 00 01 00"))
        #expect(try serialize { try $0.addNumber(16_777_216) } == bytes("07 00 00 00 01"))
        #expect(try serialize { try $0.addNumber(4_294_967_296) } == bytes("09 00 00 00 00 01 00 00 00"))
    }

    @Test func largestRepresentableIntegerIsTwoToTheSixtyFourMinusOne() throws {
        #expect(try serialize { try $0.addNumber(9_223_372_036_854_775_808.0) } == bytes("09 00 00 00 00 00 00 00 80"))
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x287)) {
            _ = try serialize { try $0.addNumber(18_446_744_073_709_551_616.0) }
        }
    }

    @Test func addNumberRejectsNonNonnegativeIntegers() {
        let node = NodeCore()
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x232)) { try node.addNumber(-1) }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x231)) { try node.addNumber(1.5) }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x231)) { try node.addNumber(.nan) }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x231)) { try node.addNumber(.infinity) }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x231)) { try node.addNumber(nil) }
        #expect(node.length == 0)
    }

    @Test func blobAndStringLengthMarkers() throws {
        #expect(try serialize { $0.addBlob([]) } == bytes("20"))
        #expect(try serialize { $0.addBlob([0x7F]) } == bytes("21 01 7f"))
        #expect(try serialize { $0.addString("") } == bytes("0d"))
        #expect(try serialize { $0.addString("é") } == bytes("0e 02 c3 a9"))
        let long = try serialize { $0.addBlob(Array(repeating: 1, count: 256)) }
        #expect(Array(long.prefix(3)) == bytes("22 00 01"))
        let longString = try serialize { $0.addString(JSString(String(repeating: "a", count: 65536))) }
        #expect(Array(longString.prefix(5)) == bytes("10 00 00 01 00"))
    }

    @Test func loneSurrogatesEncodeAsReplacementCharacter() throws {
        let lone = JSString(utf16: [0x61, 0xD800, 0x62, 0xDC00, 0xD83D, 0xDE00])
        #expect(try serialize { $0.addString(lone) } == bytes("0e 0c 61 ef bf bd 62 ef bf bd f0 9f 98 80"))
    }

    @Test func dictionaryStringIsDeclaredOnceThenReferenced() throws {
        let data = try serialize {
            $0.addDictionaryString("mrv")
            $0.addDictionaryString("mrv")
            $0.addDictionaryString("x")
        }
        #expect(data == bytes("14 01 03 6d 72 76 11 01 11 01 14 02 01 78 11 02"))
    }

    @Test func dictionaryIDsAboveOneByteUseBigDeclarations() throws {
        let data = try serialize { builder in
            for index in 1...255 {
                builder.addDictionaryString(JSString("k\(index)"))
            }
            builder.addDictionaryString("x")
            builder.addDictionaryString("x")
        }
        #expect(Array(data.suffix(16)) == bytes("15 00 01 00 00 01 00 00 00 78 12 00 01 12 00 01"))
    }

    @Test func longDictionaryStringUsesBigDeclarationEvenWithSmallID() throws {
        let data = try serialize { $0.addDictionaryString(JSString(String(repeating: "a", count: 256))) }
        #expect(Array(data.prefix(9)) == bytes("15 01 00 00 00 00 01 00 00"))
        #expect(Array(data.suffix(2)) == bytes("11 01"))
    }

    @Test func nodesAreWrappedInStartAndEndMarkers() throws {
        let data = try serialize {
            $0.addNode(.list).addBool(true)
            $0.addNode(.set).addBool(false)
        }
        #expect(data == bytes("31 0b 32 33 0c 34"))
    }

    @Test func serializeConsumesTheBuffer() throws {
        let buffer = WriteBuffer()
        try buffer.write(1)
        #expect(try buffer.done() == [1])
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x227)) { _ = try buffer.done() }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x225)) { try buffer.write(1) }
    }

    @Test func writeRejectsValuesThatDoNotFit() {
        let buffer = WriteBuffer()
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x226)) { try buffer.write(256, 1) }
    }

    @Test func calcLengthMatchesTheSpecExamples() {
        #expect(calcLength(0) == 0)
        #expect(calcLength(255) == 1)
        #expect(calcLength(256) == 2)
        #expect(calcLength(65536) == 4)
        #expect(calcLength(16_777_215) == 4)
        #expect(calcLength(4_294_967_296) == 8)
    }
}
