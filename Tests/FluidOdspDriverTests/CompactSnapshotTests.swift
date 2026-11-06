import FluidDriverDefinitions
import FluidJS
import Testing

@testable import FluidOdspDriver

// Ports src/test/snapshotFormatTests.spec.ts and exercises the hazards listed in
// specs/odsp-driver/compact-snapshot.md: parent-local `unreferenced`, `groupId` dropped on empty
// children, `cv === "1.0"`, reordered pairs, service-style entries, empty deltas.

private func object<Value>(_ pairs: [(JSString, Value)]) -> JSObject<Value> {
    var result = JSObject<Value>()
    for (key, value) in pairs {
        result[key] = value
    }
    return result
}

private func buffer(_ text: String) -> CompactSnapshotBlobContent {
    .buffer(ArraySlice(text.utf8))
}

private func map(_ pairs: [(JSString, CompactSnapshotBlobContent)]) -> JSMap<JSString, CompactSnapshotBlobContent> {
    var result = JSMap<JSString, CompactSnapshotBlobContent>()
    for (key, value) in pairs {
        result.set(key, value)
    }
    return result
}

private func entries(_ map: JSMap<JSString, CompactSnapshotBlobContent>) -> [String] {
    map.entries.map { key, value in
        guard case .buffer(let bytes) = value else {
            return "\(key)=<blob>"
        }
        return "\(key)=\(Array(bytes))"
    }
}

private func op(_ json: String) throws -> JSONValue {
    try JSON.parse(json)
}

private let goldenHex = """
    33
    14 01 03 6d 72 76 11 01 0e 03 31 2e 30
    14 02 02 63 76 11 02 0e 03 31 2e 30
    14 03 03 6c 73 6e 11 03 01
    14 04 08 73 6e 61 70 73 68 6f 74 11 04 33
    14 05 02 69 64 11 05 0e 01 73
    14 06 07 6d 65 73 73 61 67 65 11 06
    0e 0a 53 6e 61 70 73 68 6f 74 40 30
    14 07 0e 73 65 71 75 65 6e 63 65 4e 75 6d 62 65 72 11 07 01
    14 08 09 74 72 65 65 4e 6f 64 65 73 11 08 31 32
    34
    14 09 05 62 6c 6f 62 73 11 09 31 32
    34
    """.split(whereSeparator: \.isNewline).joined(separator: " ")

private let snapshotTree = CompactSnapshotTree(
    id: "SnapshotId",
    trees: object([
        (
            ".protocol",
            CompactSnapshotTree(
                blobs: object([
                    ("attributes", "bARADgIe4qmDjJl2l2zz12IM3"),
                    ("quorumMembers", "bARBkx1nses1pHL1vKnmFUfIC"),
                    ("quorumProposals", "bARBkx1nses1pHL1vKnmFUfIC"),
                ]))
        ),
        (
            ".app",
            CompactSnapshotTree(
                blobs: object([(".metadata", "bARD4RKvW4LL1KmaUKp6hUMSp")]),
                trees: object([
                    (
                        ".channels",
                        CompactSnapshotTree(
                            trees: object([
                                (
                                    "default",
                                    CompactSnapshotTree(
                                        blobs: object([
                                            (".component", "bARC6dCXlcrPxQHw3PeROtmKc"),
                                            ("gc", "bARDNMoBed+nKrsf04id52iUA"),
                                        ]),
                                        trees: object([
                                            (".channels", CompactSnapshotTree(trees: object([("root", CompactSnapshotTree())])))
                                        ]))
                                )
                            ]),
                            unreferenced: true)
                    ),
                    (".blobs", CompactSnapshotTree()),
                ]),
                unreferenced: true)
        ),
    ]))

nonisolated(unsafe) private let blobContents = map([
    ("bARADgIe4qmDjJl2l2zz12IM3", buffer(#"{"branch":"","minimumSequenceNumber":0,"sequenceNumber":0,"term":1}"#)),
    ("bARBkx1nses1pHL1vKnmFUfIC", buffer("[]")),
    ("bARD4RKvW4LL1KmaUKp6hUMSp", buffer(#"{"summaryFormatVersion":1,"gcFeature":0}"#)),
    ("bARC6dCXlcrPxQHw3PeROtmKc", buffer(#"{"pkg":"[\"@fluid-example/smde\"]","summaryFormatVersion":2,"isRootDataStore":true}"#)),
    (
        "bARDNMoBed+nKrsf04id52iUA",
        buffer(
            #"{"usedRoutes":[""],"gcData":{"gcNodes":{"/root":["/default/01b197a2-0432-413b-b2c9-83a992b804c4","/default"],"/01b197a2-0432-413b-b2c9-83a992b804c4":["/default"],"/":["/default/root","/default/01b197a2-0432-413b-b2c9-83a992b804c4"]}}}"#
        )
    ),
])

private func twoJoinOps() throws -> [JSONValue] {
    [
        try op(
            #"{"clientId":"X","clientSequenceNumber":-1,"contents":null,"minimumSequenceNumber":0,"referenceSequenceNumber":-1,"sequenceNumber":1,"timestamp":1623883807452,"type":"join"}"#
        ),
        try op(
            #"{"clientId":"Y","clientSequenceNumber":-1,"contents":null,"minimumSequenceNumber":0,"referenceSequenceNumber":-1,"sequenceNumber":2,"timestamp":1623883811928,"type":"join"}"#
        ),
    ]
}

private let snapshotTreeWithGroupId = CompactSnapshotTree(
    id: "SnapshotId",
    trees: object([
        (".protocol", CompactSnapshotTree()),
        (
            ".app",
            CompactSnapshotTree(
                blobs: object([(".metadata", "bARD4RKvW4LL1KmaUKp6hUMSp")]),
                trees: object([
                    (
                        ".channels",
                        CompactSnapshotTree(
                            trees: object([
                                (
                                    "default",
                                    CompactSnapshotTree(
                                        trees: object([("dds", CompactSnapshotTree())]),
                                        groupId: "G3")
                                )
                            ]),
                            unreferenced: true,
                            groupId: "G2")
                    ),
                    (".blobs", CompactSnapshotTree()),
                ]),
                unreferenced: true,
                groupId: "G4")
        ),
    ]))

nonisolated(unsafe) private let blobContents2 = map([
    ("bARD4RKvW4LL1KmaUKp6hUMSp", buffer(#"{"summaryFormatVersion":1,"gcFeature":0}"#))
])

@Suite struct CompactSnapshotWriterTests {
    @Test func specWorkedHexExample() throws {
        let snapshot = CompactSnapshot(
            snapshotTree: CompactSnapshotTree(id: "s"), blobContents: JSMap(), ops: [], sequenceNumber: 0)
        let written = try convertToCompactSnapshot(snapshot)
        #expect(written == bytes(goldenHex))
        #expect(written.count == 133)
    }

    @Test func specWorkedHexExampleParses() throws {
        let result = try parseCompactSnapshotResponse(bytes(goldenHex))
        #expect(result.snapshot.snapshotTree == CompactSnapshotTree(id: "s"))
        #expect(result.snapshot.blobContents.size == 0)
        #expect(result.snapshot.ops.isEmpty)
        #expect(result.snapshot.sequenceNumber == 0)
        #expect(result.snapshot.latestSequenceNumber == 0)
        #expect(result.snapshot.snapshotFormatV == 1)
    }

    @Test func missingSnapshotIDFails0x21b() {
        let snapshot = CompactSnapshot(
            snapshotTree: CompactSnapshotTree(), blobContents: JSMap(), ops: [], sequenceNumber: 0)
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x21b)) { _ = try convertToCompactSnapshot(snapshot) }
    }

    @Test func missingSequenceNumberFails0x21c() {
        let snapshot = CompactSnapshot(
            snapshotTree: CompactSnapshotTree(id: "s"), blobContents: JSMap(), ops: [], sequenceNumber: nil)
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x21c)) { _ = try convertToCompactSnapshot(snapshot) }
    }

    @Test func latestSequenceNumberDefaultsToLastOpThenSnapshotSequence() throws {
        let tree = CompactSnapshotTree(id: "s")
        let ops = try twoJoinOps()
        let fromOps = try parseCompactSnapshotResponse(
            convertToCompactSnapshot(
                CompactSnapshot(snapshotTree: tree, blobContents: JSMap(), ops: ops, sequenceNumber: 0)))
        #expect(fromOps.snapshot.latestSequenceNumber == 2)
        let fromSnapshot = try parseCompactSnapshotResponse(
            convertToCompactSnapshot(
                CompactSnapshot(snapshotTree: tree, blobContents: JSMap(), ops: [], sequenceNumber: 7)))
        #expect(fromSnapshot.snapshot.latestSequenceNumber == 7)
        let explicitZero = try parseCompactSnapshotResponse(
            convertToCompactSnapshot(
                CompactSnapshot(
                    snapshotTree: tree, blobContents: JSMap(), ops: ops, sequenceNumber: 7, latestSequenceNumber: 0)))
        #expect(explicitZero.snapshot.latestSequenceNumber == 0, "zero is not replaced")
    }

    @Test func opWithoutSequenceNumberOmitsDeltas() throws {
        let snapshot = CompactSnapshot(
            snapshotTree: CompactSnapshotTree(id: "s"), blobContents: JSMap(), ops: [try op(#"{"type":"noop"}"#)],
            sequenceNumber: 3, latestSequenceNumber: 3)
        let parsed = try parseCompactSnapshotResponse(convertToCompactSnapshot(snapshot))
        #expect(parsed.snapshot.ops.isEmpty)
    }

    @Test func opSequenceNumberThatIsNotAnIntegerFails0x231() throws {
        let snapshot = CompactSnapshot(
            snapshotTree: CompactSnapshotTree(id: "s"), blobContents: JSMap(),
            ops: [try op(#"{"sequenceNumber":"5"}"#)], sequenceNumber: 3, latestSequenceNumber: 3)
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x231)) { _ = try convertToCompactSnapshot(snapshot) }
    }

    @Test func nullOpIsATypeError() throws {
        let snapshot = CompactSnapshot(
            snapshotTree: CompactSnapshotTree(id: "s"), blobContents: JSMap(), ops: [.null], sequenceNumber: 3,
            latestSequenceNumber: 3)
        #expect(throws: OdspSnapshotError.undefinedAccess) { _ = try convertToCompactSnapshot(snapshot) }
    }

    @Test func treeEntriesFollowObjectEntriesOrderThenBlobs() throws {
        let tree = CompactSnapshotTree(
            id: "s",
            blobs: object([("b2", "id2"), ("10", "id10"), ("1", "id1")]),
            trees: object([("z", CompactSnapshotTree()), ("2", CompactSnapshotTree()), ("a", CompactSnapshotTree())]))
        let bytes = try convertToCompactSnapshot(
            CompactSnapshot(snapshotTree: tree, blobContents: JSMap(), ops: [], sequenceNumber: 0))
        let parsed = try TreeBuilder.load(ReadBuffer(bytes)).builder
        let snapshot = try parsed.getNode(0).getNode(7).getNode(7)
        let names = try (0..<snapshot.length).map { try snapshot.getNode($0).getString(1).description }
        // Object.entries: integer-like keys ascending first, then insertion order; trees before blobs.
        #expect(names == ["2", "z", "a", "1", "10", "b2"])
    }

    @Test func unreferencedAndGroupIdAreWrittenPerTS() throws {
        let tree = CompactSnapshotTree(
            id: "s",
            trees: object([
                ("full", CompactSnapshotTree(blobs: object([("b", "i")]), groupId: "")),
                ("empty", CompactSnapshotTree(groupId: "G")),
            ]),
            unreferenced: true)
        let bytes = try convertToCompactSnapshot(
            CompactSnapshot(snapshotTree: tree, blobContents: JSMap(), ops: [], sequenceNumber: 0))
        let root = try TreeBuilder.load(ReadBuffer(bytes)).builder.getNode(0)
        let snapshot = try root.getNode(7)
        let entries = try snapshot.getNode(7)
        let full = try entries.getNode(0)
        // name, "full", unreferenced, true (parent flag), children, list, groupId, ""
        #expect(full.length == 8)
        #expect(try full.getMaybeString(2) == "unreferenced")
        #expect(try full.getBool(3) == true)
        #expect(try full.getMaybeString(4) == "children")
        #expect(try full.getMaybeString(6) == "groupId")
        #expect(try full.getString(7) == "")
        let empty = try entries.getNode(1)
        // empty child: no children property, but groupId still written
        #expect(empty.length == 6)
        #expect(try empty.getMaybeString(4) == "groupId")
    }

    @Test func blobContentsInAllWriterVariants() throws {
        let contents = map([
            ("raw", .buffer([0x00, 0xFF])),
            ("utf8", .blob(contents: "héllo😀", encoding: nil)),
            ("utf8Explicit", .blob(contents: "é", encoding: .utf8)),
            ("b64", .blob(contents: "AP8=", encoding: .base64)),
        ])
        let written = try convertToCompactSnapshot(
            CompactSnapshot(
                snapshotTree: CompactSnapshotTree(id: "s"), blobContents: contents, ops: [], sequenceNumber: 0))
        let parsed = try parseCompactSnapshotResponse(written)
        #expect(
            entries(parsed.snapshot.blobContents) == [
                "raw=[0, 255]",
                "utf8=[104, 195, 169, 108, 108, 111, 240, 159, 152, 128]",
                "utf8Explicit=[195, 169]",
                "b64=[0, 255]",
            ])
    }
}

@Suite struct CompactSnapshotRoundTripTests {
    private func roundTrip(
        _ tree: CompactSnapshotTree, _ contents: JSMap<JSString, CompactSnapshotBlobContent>, ops: [JSONValue]
    ) throws -> (bytes: [UInt8], result: ISnapshotContentsWithProps) {
        let snapshot = CompactSnapshot(
            snapshotTree: tree, blobContents: contents, ops: ops, sequenceNumber: 0, latestSequenceNumber: 2)
        let bytes = try convertToCompactSnapshot(snapshot)
        return (bytes, try parseCompactSnapshotResponse(bytes))
    }

    @Test func conversion() throws {
        let ops = try twoJoinOps()
        let (compact, result) = try roundTrip(snapshotTree, blobContents, ops: ops)
        #expect(result.snapshot.snapshotTree == snapshotTree, "Tree structure should match")
        #expect(entries(result.snapshot.blobContents) == entries(blobContents), "Blobs content should match")
        #expect(result.snapshot.ops == ops, "Ops should match")
        #expect(result.snapshot.sequenceNumber == 0)
        #expect(result.snapshot.latestSequenceNumber == 2)
        #expect(result.snapshot.snapshotTree.id == "SnapshotId")
        #expect(result.telemetryProps.slowBlobStructureCount == 0)
        // there is { name, unreferenced } structure (i.e. empty unreferenced tree) that we do not optimize
        #expect(result.telemetryProps.slowTreeStructureCount == 1)
        #expect(try convertToCompactSnapshot(result.snapshot) == compact, "Compact representation should remain same")
    }

    @Test func conversionWithEmptyOps() throws {
        let (compact, result) = try roundTrip(snapshotTree, blobContents, ops: [])
        #expect(result.snapshot.snapshotTree == snapshotTree)
        #expect(entries(result.snapshot.blobContents) == entries(blobContents))
        #expect(result.snapshot.ops.isEmpty)
        #expect(result.snapshot.latestSequenceNumber == 2)
        #expect(result.telemetryProps.slowBlobStructureCount == 0)
        #expect(result.telemetryProps.slowTreeStructureCount == 1)
        #expect(try convertToCompactSnapshot(result.snapshot) == compact)
    }

    @Test func conversionForSnapshotWithGroupId() throws {
        let ops = try twoJoinOps()
        let (compact, result) = try roundTrip(snapshotTreeWithGroupId, blobContents2, ops: ops)
        #expect(result.snapshot.snapshotTree == snapshotTreeWithGroupId)
        #expect(entries(result.snapshot.blobContents) == entries(blobContents2))
        #expect(result.snapshot.ops == ops)
        #expect(result.telemetryProps.slowBlobStructureCount == 0)
        #expect(result.telemetryProps.slowTreeStructureCount == 4)
        #expect(result.telemetryProps.treeStructureCountWithGroupId == 3)
        #expect(try convertToCompactSnapshot(result.snapshot) == compact)
    }

    @Test func integerLikeNamesKeepJSOrderThroughTheRoundTrip() throws {
        let tree = CompactSnapshotTree(
            id: "s",
            blobs: object([("b", "1"), ("1", "2")]),
            trees: object([("x", CompactSnapshotTree()), ("0", CompactSnapshotTree())]))
        let (_, result) = try roundTrip(tree, JSMap(), ops: [])
        #expect(result.snapshot.snapshotTree.trees.keys == ["0", "x"])
        #expect(result.snapshot.snapshotTree.blobs.keys == ["1", "b"])
    }

    @Test func largeBlobsKeepTheirBytes() throws {
        let payload = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let contents = map([("big", .buffer(ArraySlice(payload))), ("empty", .buffer([]))])
        let (_, result) = try roundTrip(CompactSnapshotTree(id: "s"), contents, ops: [])
        #expect(result.snapshot.blobContents.get("big") == .buffer(ArraySlice(payload)))
        #expect(result.snapshot.blobContents.get("empty") == .buffer([]))
    }

    @Test func parsedBlobsAreSlicesOfTheInput() throws {
        let contents = map([("a", .buffer([1, 2, 3]))])
        let snapshot = CompactSnapshot(
            snapshotTree: CompactSnapshotTree(id: "s"), blobContents: contents, ops: [], sequenceNumber: 0)
        var storage: [UInt8] = [0xEE, 0xEE, 0xEE]
        storage.append(contentsOf: try convertToCompactSnapshot(snapshot))
        let result = try parseCompactSnapshotResponse(storage[3...])
        guard case .buffer(let blob) = try #require(result.snapshot.blobContents.get("a")) else {
            Issue.record("expected a buffer")
            return
        }
        #expect(Array(blob) == [1, 2, 3])
        #expect(blob.startIndex > 3, "the blob must be a window onto the caller's storage")
    }

    @Test func loneSurrogateNamesBecomeReplacementCharactersOnTheWire() throws {
        let name = JSString(utf16: [0x61, 0xD800])
        let tree = CompactSnapshotTree(id: "s", trees: object([(name, CompactSnapshotTree())]))
        let (_, result) = try roundTrip(tree, JSMap(), ops: [])
        #expect(result.snapshot.snapshotTree.trees.keys == [JSString(utf16: [0x61, 0xFFFD])])
    }
}

/// Builds `application/ms-fluid` bytes by hand, so each test controls exactly which pairs exist.
private struct RawSnapshot {
    var mrv: JSString? = "1.0"
    var cv: JSString? = "1.0"
    var lsn: Double? = 0
    var id: JSString? = "s"
    var sequenceNumber: Double? = 0
    /// Builds the content of `treeNodes`.
    var treeNodes: (NodeCore) throws -> Void = { _ in }
    var blobs: ((NodeCore) throws -> Void)? = { _ in }
    var deltas: ((NodeCore) throws -> Void)?

    func bytes() throws -> [UInt8] {
        let builder = TreeBuilderSerializer()
        let root = builder.addNode()
        if let mrv {
            addStringProperty(root, "mrv", mrv)
        }
        if let cv {
            addStringProperty(root, "cv", cv)
        }
        if let lsn {
            try addNumberProperty(root, "lsn", lsn)
        }
        root.addDictionaryString("snapshot")
        let snapshot = root.addNode()
        if let id {
            addStringProperty(snapshot, "id", id)
        }
        if let sequenceNumber {
            try addNumberProperty(snapshot, "sequenceNumber", sequenceNumber)
        }
        snapshot.addDictionaryString("treeNodes")
        try treeNodes(snapshot.addNode(.list))
        if let blobs {
            root.addDictionaryString("blobs")
            try blobs(root.addNode(.list))
        }
        if let deltas {
            root.addDictionaryString("deltas")
            try deltas(root.addNode())
        }
        return try builder.serialize()
    }
}

private func entry(_ list: NodeCore, _ build: (NodeCore) throws -> Void) rethrows {
    try build(list.addNode())
}

@Suite struct CompactSnapshotParserTests {
    private func parse(_ raw: RawSnapshot) throws -> ISnapshotContentsWithProps {
        try parseCompactSnapshotResponse(raw.bytes())
    }

    @Test func versionGatesAreLiteral() throws {
        var raw = RawSnapshot()
        raw.mrv = "2.0"
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x20f)) { _ = try parse(raw) }
        raw.mrv = "0.5"
        _ = try parse(raw)
        raw.mrv = "1.0"
        raw.cv = "0.5"
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x210)) { _ = try parse(raw) }
        raw.cv = "1.00"
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x2c2)) { _ = try parse(raw) }
        raw.cv = "1.5"
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x2c2)) { _ = try parse(raw) }
        raw.cv = "1.0abc"
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x2c2)) { _ = try parse(raw) }
        raw.cv = "abc"
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x210)) { _ = try parse(raw) }
        raw.cv = "1.0"
        raw.mrv = " +1e0xyz"
        _ = try parse(raw)
        raw.mrv = "NaN"
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x20f)) { _ = try parse(raw) }
    }

    @Test func versionStringsMustBeStrings() {
        var raw = RawSnapshot()
        raw.mrv = nil
        #expect(throws: OdspSnapshotError.undefinedAccess) { _ = try parse(raw) }
    }

    @Test func lsnIsOptionalButMustBeANumber() throws {
        var raw = RawSnapshot()
        raw.lsn = nil
        #expect(try parse(raw).snapshot.latestSequenceNumber == nil)
        raw.lsn = 9
        #expect(try parse(raw).snapshot.latestSequenceNumber == 9)
    }

    @Test func rootMustBeASingleNode() throws {
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x219)) {
            _ = try parseCompactSnapshotResponse([])
        }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x219)) {
            _ = try parseCompactSnapshotResponse(bytes("33 34 33 34"))
        }
        #expect(
            throws: OdspSnapshotError.bufferParsing(
                message: "Buffer parsing exception: getNode should return a node", nodeType: .number,
                expectedNodeType: .nodeCore)
        ) {
            _ = try parseCompactSnapshotResponse(bytes("01"))
        }
    }

    @Test func missingSectionsAreTypeErrors() throws {
        var raw = RawSnapshot()
        raw.blobs = nil
        #expect(throws: OdspSnapshotError.undefinedAccess) { _ = try parse(raw) }
        raw = RawSnapshot()
        raw.id = nil
        #expect(throws: OdspSnapshotError.undefinedAccess) { _ = try parse(raw) }
        raw = RawSnapshot()
        raw.sequenceNumber = nil
        #expect(throws: OdspSnapshotError.undefinedAccess) { _ = try parse(raw) }
    }

    @Test func fastPathEntriesAndTelemetry() throws {
        var raw = RawSnapshot()
        raw.treeNodes = { list in
            entry(list) { node in
                node.addString("name")
                node.addString("empty")
            }
            entry(list) { node in
                node.addString("name")
                node.addString("blob")
                node.addString("value")
                node.addString("blobId")
            }
            entry(list) { node in
                node.addString("name")
                node.addString("dir")
                node.addString("children")
                let children = node.addNode(.list)
                entry(children) { child in
                    child.addString("name")
                    child.addString("inner")
                }
            }
        }
        let result = try parse(raw)
        let tree = result.snapshot.snapshotTree
        #expect(tree.trees.keys == ["empty", "dir"])
        #expect(tree.blobs.keys == ["blob"])
        #expect(tree.blobs["blob"] == "blobId")
        #expect(tree.trees["dir"]?.trees.keys == ["inner"])
        #expect(result.telemetryProps.slowTreeStructureCount == 0)
    }

    @Test func serviceStyleEntriesWithNodeType() throws {
        var raw = RawSnapshot()
        raw.treeNodes = { list in
            try entry(list) { node in
                node.addString("name")
                node.addString("b")
                node.addString("nodeType")
                try node.addNumber(3)
                node.addString("value")
                node.addString("id1")
            }
        }
        let result = try parse(raw)
        #expect(result.snapshot.snapshotTree.blobs["b"] == "id1")
        #expect(result.telemetryProps.slowTreeStructureCount == 0, "six-element name/nodeType/value is a fast path")
    }

    @Test func unreferencedMarksTheEnclosingTree() throws {
        var raw = RawSnapshot()
        raw.treeNodes = { list in
            entry(list) { node in
                node.addString("name")
                node.addString("child")
                node.addString("unreferenced")
                node.addBool(true)
                node.addString("children")
                let children = node.addNode(.list)
                entry(children) { inner in
                    inner.addString("name")
                    inner.addString("leaf")
                }
            }
        }
        let tree = try parse(raw).snapshot.snapshotTree
        #expect(tree.unreferenced == true, "the enclosing tree, not the child, becomes unreferenced")
        #expect(tree.trees["child"]?.unreferenced == nil)
    }

    @Test func unreferencedMustBeTrue() throws {
        var raw = RawSnapshot()
        raw.treeNodes = { list in
            entry(list) { node in
                node.addString("name")
                node.addString("child")
                node.addString("unreferenced")
                node.addBool(false)
                node.addString("children")
                node.addNode(.list)
            }
        }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x3db)) { _ = try parse(raw) }
        raw.treeNodes = { list in
            entry(list) { node in
                node.addString("unreferenced")
                node.addBool(false)
                node.addString("name")
                node.addString("child")
            }
        }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x281)) { _ = try parse(raw) }
    }

    @Test func generalPathAcceptsReorderedPairsAndUnknownFields() throws {
        var raw = RawSnapshot()
        raw.treeNodes = { list in
            entry(list) { node in
                node.addString("extra")
                node.addBlob([1])
                node.addString("value")
                node.addString("id9")
                node.addString("name")
                node.addString("b")
            }
            entry(list) { node in
                node.addString("groupId")
                node.addString("G")
                node.addString("children")
                node.addNode(.list)
                node.addString("name")
                node.addString("withGroup")
            }
            entry(list) { node in
                node.addString("groupId")
                node.addString("lost")
                node.addString("name")
                node.addString("emptyWithGroup")
            }
            entry(list) { node in
                node.addString("name")
                node.addString("both")
                node.addString("value")
                node.addString("idV")
                node.addString("children")
                node.addNode(.list)
            }
        }
        let result = try parse(raw)
        let tree = result.snapshot.snapshotTree
        #expect(tree.blobs["b"] == "id9")
        #expect(tree.trees["withGroup"]?.groupId == "G")
        #expect(tree.trees["emptyWithGroup"] == CompactSnapshotTree(), "groupId is dropped on an empty child")
        #expect(tree.blobs["both"] == "idV", "value wins over children")
        #expect(tree.trees["both"] == nil)
        #expect(result.telemetryProps.slowTreeStructureCount == 4)
        #expect(result.telemetryProps.treeStructureCountWithGroupId == 1)
    }

    @Test func duplicateNamesKeepFirstPositionAndLastValue() throws {
        var raw = RawSnapshot()
        raw.treeNodes = { list in
            for value in ["a", "b", "c"] {
                entry(list) { node in
                    node.addString("name")
                    node.addString("same")
                    node.addString("value")
                    node.addString(JSString(value))
                }
            }
            entry(list) { node in
                node.addString("name")
                node.addString("other")
                node.addString("value")
                node.addString("o")
            }
            entry(list) { node in
                node.addString("name")
                node.addString("same")
                node.addString("value")
                node.addString("z")
            }
        }
        let blobs = try parse(raw).snapshot.snapshotTree.blobs
        #expect(blobs.keys == ["same", "other"])
        #expect(blobs["same"] == "z")
    }

    @Test func protoNamedEntriesVanishLikeInTheOracle() throws {
        var raw = RawSnapshot()
        raw.treeNodes = { list in
            entry(list) { node in
                node.addString("name")
                node.addString("__proto__")
            }
            entry(list) { node in
                node.addString("name")
                node.addString("__proto__")
                node.addString("value")
                node.addString("id")
            }
            entry(list) { node in
                node.addString("name")
                node.addString("kept")
            }
        }
        let result = try parse(raw)
        #expect(result.snapshot.snapshotTree.trees.keys == ["kept"])
        #expect(result.snapshot.snapshotTree.blobs.isEmpty)
    }

    @Test func protoKeyInsideAnEntrySuppliesInheritedChildren() throws {
        var raw = RawSnapshot()
        raw.treeNodes = { list in
            entry(list) { node in
                node.addString("__proto__")
                node.addNode()
                node.addString("name")
                node.addString("x")
            }
        }
        #expect(
            throws: OdspSnapshotError.bufferParsing(
                message: "Buffer parsing exception: Trees should be of type NodeCore", nodeType: .unknownType,
                expectedNodeType: .nodeCore)
        ) {
            _ = try parse(raw)
        }
    }

    @Test func entryOddPairCountAndNonStringKeys() throws {
        var raw = RawSnapshot()
        raw.treeNodes = { list in
            entry(list) { node in
                node.addString("name")
                node.addString("x")
                node.addString("value")
            }
        }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x22c)) { _ = try parse(raw) }
    }

    @Test func treeEntryMustBeANode() throws {
        var raw = RawSnapshot()
        raw.treeNodes = { list in
            list.addString("oops")
        }
        #expect(
            throws: OdspSnapshotError.bufferParsing(
                message: "Buffer parsing exception: tree nodes should be nodes", nodeType: .string,
                expectedNodeType: .nodeCore)
        ) {
            _ = try parse(raw)
        }
    }

    @Test func blobSectionFastAndGeneralPaths() throws {
        var raw = RawSnapshot()
        raw.blobs = { list in
            entry(list) { node in
                node.addDictionaryString("id")
                node.addString("one")
                node.addString("data")
                node.addBlob([1])
            }
            entry(list) { node in
                node.addString("data")
                node.addBlob([2, 2])
                node.addString("id")
                node.addString("two")
            }
            entry(list) { node in
                node.addString("id")
                node.addString("one")
                node.addString("data")
                node.addBlob([9])
            }
        }
        let result = try parse(raw)
        #expect(result.snapshot.blobContents.keys == ["one", "two"], "duplicate id keeps first position")
        #expect(result.snapshot.blobContents.get("one") == .buffer([9]), "last write wins")
        #expect(result.snapshot.blobContents.get("two") == .buffer([2, 2]))
        #expect(result.telemetryProps.slowBlobStructureCount == 1)
    }

    @Test func blobEntryTypeErrors() throws {
        var raw = RawSnapshot()
        raw.blobs = { list in
            entry(list) { node in
                node.addString("id")
                node.addString("one")
                node.addString("data")
                node.addString("not a blob")
            }
        }
        #expect(
            throws: OdspSnapshotError.bufferParsing(
                message: "Buffer parsing exception: getBlob should return a blob", nodeType: .string,
                expectedNodeType: .blobCore)
        ) {
            _ = try parse(raw)
        }
        raw.blobs = { list in
            entry(list) { node in
                node.addString("id")
                node.addString("one")
            }
        }
        #expect(throws: OdspSnapshotError.undefinedAccess) { _ = try parse(raw) }
    }

    @Test func deltasMayBeEmptyOrMustMatchTheFirstOp() throws {
        var raw = RawSnapshot()
        raw.deltas = { node in
            node.addString("firstSequenceNumber")
            try node.addNumber(5)
            node.addString("deltas")
            node.addNode(.list)
        }
        #expect(try parse(raw).snapshot.ops.isEmpty, "service bug: deltas serialized even when there are none")

        raw.deltas = { node in
            node.addString("firstSequenceNumber")
            try node.addNumber(5)
            node.addString("deltas")
            let list = node.addNode(.list)
            list.addString(#"{"sequenceNumber":5,"type":"op"}"#)
            list.addString(#"{"sequenceNumber":6}"#)
        }
        let ops = try parse(raw).snapshot.ops
        #expect(ops.count == 2)
        #expect(try ops[0].member("type") == .string("op"))

        raw.deltas = { node in
            node.addString("firstSequenceNumber")
            try node.addNumber(4)
            node.addString("deltas")
            node.addNode(.list).addString(#"{"sequenceNumber":5}"#)
        }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x280)) { _ = try parse(raw) }

        raw.deltas = { node in
            node.addString("firstSequenceNumber")
            try node.addNumber(1)
            node.addString("deltas")
            node.addNode(.list).addString("{")
        }
        #expect(throws: OdspSnapshotError.invalidJSON) { _ = try parse(raw) }

        raw.deltas = { node in
            node.addString("firstSequenceNumber")
            try node.addNumber(1)
            node.addString("deltas")
            node.addNode(.list).addString("null")
        }
        #expect(throws: OdspSnapshotError.undefinedAccess) { _ = try parse(raw) }

        raw.deltas = { node in
            node.addString("firstSequenceNumber")
            try node.addNumber(1)
            node.addString("deltas")
            node.addNode(.list).addString("5")
        }
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x280)) { _ = try parse(raw) }
    }

    @Test func snapshotSequenceNumberMustFitTheProtocolRange() throws {
        var raw = RawSnapshot()
        raw.sequenceNumber = 9_007_199_254_740_993
        #expect(throws: OdspSnapshotError.sequenceNumberOutOfRange) { _ = try parse(raw) }
    }

    @Test func trailingDataAfterTheRootIsAnotherRoot() throws {
        let raw = try RawSnapshot().bytes()
        #expect(throws: OdspSnapshotError.assertionFailed(code: 0x219)) {
            _ = try parseCompactSnapshotResponse(raw + raw)
        }
    }
}
