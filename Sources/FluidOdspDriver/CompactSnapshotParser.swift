import FluidJS

// Ports odsp-driver/src/compactSnapshotParser.ts.

public let snapshotMinReadVersion: JSString = "1.0"
public let currentReadVersion: JSString = "1.0"

private let nameKey: JSString = "name"
private let childrenKey: JSString = "children"
private let valueKey: JSString = "value"
private let nodeTypeKey: JSString = "nodeType"
private let unreferencedKey: JSString = "unreferenced"
private let idKey: JSString = "id"
private let dataKey: JSString = "data"
private let protoKey: JSString = "__proto__"

/// TS stores entries in plain objects, where a `__proto__` key replaces the prototype instead of
/// creating a property: such a tree or blob is silently dropped (the spec lists this as oracle
/// behavior; the entry is still parsed, so its errors and counters are kept).
private func store<Value>(_ map: inout JSObject<Value>, _ key: JSString, _ value: Value) {
    if key != protoKey {
        map[key] = value
    }
}

/// Recreates blobs section of the tree.
private func readBlobSection(
    _ node: NodeTypes?
) throws -> (blobContents: JSMap<JSString, CompactSnapshotBlobContent>, slowBlobStructureCount: Int) {
    let node = try assertNodeCoreInstance(node, "TreeBlobs should be of type NodeCore")
    var slowBlobStructureCount = 0
    var blobContents = JSMap<JSString, CompactSnapshotBlobContent>()
    for element in node.children {
        let blob = try assertNodeCoreInstance(element, "blob should be node")

        // Perf optimization - the most common case, unrolled: "id": <name>, "data": <blob>.
        if try blob.length == 4 && blob.getMaybeString(0) == idKey && blob.getMaybeString(2) == dataKey {
            let id = try blob.getString(1)
            blobContents.set(id, .buffer(try blob.getBlob(3).buffer))
        } else {
            // More generalized workflow
            slowBlobStructureCount += 1
            let records = try getNodeProps(blob)
            let data = try assertBlobCoreInstance(records[dataKey], "data should be of BlobCore type")
            let id = try getStringInstance(records[idKey], "blob id should be string")
            blobContents.set(id, .buffer(data.buffer))
        }
    }
    return (blobContents, slowBlobStructureCount)
}

/// `ops[0].sequenceNumber`: `nil` is `undefined`; a JSON `null` has no properties (a TypeError).
private func opSequenceNumber(of op: JSONValue) throws -> JSONValue? {
    switch op {
    case .null:
        throw OdspSnapshotError.undefinedAccess
    case .object(let object):
        return object["sequenceNumber"]
    case .bool, .number, .string, .array:
        return nil
    }
}

/// Recreates ops section of the tree.
private func readOpsSection(_ node: NodeTypes?) throws -> [JSONValue] {
    let node = try assertNodeCoreInstance(node, "Deltas should be of type NodeCore")
    var ops: [JSONValue] = []
    let records = try getNodeProps(node)
    let firstSequenceNumber = try assertNumberInstance(
        records["firstSequenceNumber"], "Seq number should be a number")
    let deltas = try assertNodeCoreInstance(records["deltas"], "Deltas should be a Node")
    ops.reserveCapacity(deltas.length)
    for index in 0..<deltas.length {
        let text = try deltas.getString(index)
        do {
            ops.append(try JSON.parse(text.description))
        } catch {
            throw OdspSnapshotError.invalidJSON
        }
    }
    // Due to a bug at service side, in an edge case service was serializing deltas even when there
    // are no ops. So the check only applies to a nonempty list.
    if let first = ops.first {
        let firstOp = try opSequenceNumber(of: first)
        try fluidAssert(firstOp == .number(firstSequenceNumber), 0x280)  // "Validate first op seq number"
    }
    return ops
}

private struct TreeSection {
    var snapshotTree: CompactSnapshotTree
    var slowTreeStructureCount: Int
    var treeStructureCountWithGroupId: Int
}

/// Recreates snapshot tree out of tree representation.
private func readTreeSection(_ node: NodeCore) throws -> TreeSection {
    var slowTreeStructureCount = 0
    var treeStructureCountWithGroupId = 0
    var trees = JSObject<CompactSnapshotTree>()
    var blobs = JSObject<JSString>()
    var unreferenced: Bool?

    for element in node.children {
        let treeNode = try assertNodeCoreInstance(element, "tree nodes should be nodes")

        // Perf optimization - the most common cases, unrolled.
        let length = treeNode.length
        if try length > 0 && treeNode.getMaybeString(0) == nameKey {
            switch length {
            case 2:
                // empty tree case: "name": <node name>
                store(&trees, try treeNode.getString(1), CompactSnapshotTree())
                continue
            case 4:
                let content = try treeNode.getMaybeString(2)
                // "name": <node name>, "children": <list>
                if content == childrenKey {
                    let result = try readTreeSection(treeNode.getNode(3))
                    store(&trees, try treeNode.getString(1), result.snapshotTree)
                    slowTreeStructureCount += result.slowTreeStructureCount
                    treeStructureCountWithGroupId += result.treeStructureCountWithGroupId
                    continue
                }
                // "name": <node name>, "value": <blob id>
                if content == valueKey {
                    store(&blobs, try treeNode.getString(1), try treeNode.getString(3))
                    continue
                }
            case 6:
                // "name": <node name>, "nodeType": 3, "value": <blob id>
                if try treeNode.getMaybeString(2) == nodeTypeKey && treeNode.getMaybeString(4) == valueKey {
                    store(&blobs, try treeNode.getString(1), try treeNode.getString(5))
                    continue
                }

                // "name": <node name>, "unreferenced": true, "children": <list>
                if try treeNode.getMaybeString(2) == unreferencedKey && treeNode.getMaybeString(4) == childrenKey {
                    let result = try readTreeSection(treeNode.getNode(5))
                    store(&trees, try treeNode.getString(1), result.snapshotTree)
                    slowTreeStructureCount += result.slowTreeStructureCount
                    treeStructureCountWithGroupId += result.treeStructureCountWithGroupId
                    // The flag describes the child, but is applied to the *enclosing* tree.
                    try fluidAssert(treeNode.getBool(3), 0x3db)  // "Unreferenced if present should be true"
                    unreferenced = true
                    continue
                }
            default:
                break
            }
        }

        // More generalized workflow
        slowTreeStructureCount += 1
        let records = try getNodeProps(treeNode)

        if let flag = records[unreferencedKey] {
            let value = try assertBoolInstance(flag, "Unreferenced flag should be bool")
            try fluidAssert(value, 0x281)  // "Unreferenced if present should be true"
            unreferenced = true
        }

        let path = try getStringInstance(records[nameKey], "Path name should be string")
        if let value = records[valueKey] {
            store(&blobs, path, try getStringInstance(value, "Blob value should be string"))
        } else if let children = records[childrenKey] {
            let childrenNode = try assertNodeCoreInstance(children, "Trees should be of type NodeCore")
            let result = try readTreeSection(childrenNode)
            var child = result.snapshotTree
            if let groupId = records["groupId"] {
                child.groupId = try getStringInstance(groupId, "groupId should be a string")
                treeStructureCountWithGroupId += 1
            }
            store(&trees, path, child)
            slowTreeStructureCount += result.slowTreeStructureCount
            treeStructureCountWithGroupId += result.treeStructureCountWithGroupId
        } else {
            // An empty child drops its groupId.
            store(&trees, path, CompactSnapshotTree())
        }
    }
    return TreeSection(
        snapshotTree: CompactSnapshotTree(blobs: blobs, trees: trees, unreferenced: unreferenced),
        slowTreeStructureCount: slowTreeStructureCount,
        treeStructureCountWithGroupId: treeStructureCountWithGroupId)
}

private struct SnapshotSection {
    var sequenceNumber: Double
    var tree: TreeSection
}

/// Recreates snapshot tree out of tree representation.
private func readSnapshotSection(_ node: NodeTypes?) throws -> SnapshotSection {
    let node = try assertNodeCoreInstance(node, "Snapshot should be of type NodeCore")
    let records = try getNodeProps(node)

    let treeNodes = try assertNodeCoreInstance(records["treeNodes"], "TreeNodes should be of type NodeCore")
    let sequenceNumber = try assertNumberInstance(
        records["sequenceNumber"], "sequenceNumber should be of type number")
    var tree = try readTreeSection(treeNodes)
    tree.snapshotTree.id = try getStringInstance(records[idKey], "snapshotId should be string")
    return SnapshotSection(sequenceNumber: sequenceNumber, tree: tree)
}

/// A decoded number as a protocol counter: an exact integer below 2^53 (ARCHITECTURE §3).
private func protocolCounter(_ number: Double) throws -> Int {
    guard let value = Int(exactly: number), value <= 9_007_199_254_740_991 else {
        throw OdspSnapshotError.sequenceNumberOutOfRange
    }
    return value
}

/// Converts a snapshot from binary compact representation to tree/blobs/ops.
///
/// Blob contents are slices of `buffer`'s storage, not copies. The TS `logger` parameter is not
/// ported: its only use is a `StringParsingError` event emitted just before the 0x3ea assertion.
public func parseCompactSnapshotResponse(_ buffer: ArraySlice<UInt8>) throws -> ISnapshotContentsWithProps {
    let (builder, telemetryProps) = try TreeBuilder.load(ReadBuffer(buffer))
    try fluidAssert(builder.length == 1, 0x219)  // "1 root should be there"
    let root = try builder.getNode(0)

    let records = try getNodeProps(root)

    let mrv = try getStringInstance(records["mrv"], "minReadVersion should be string")
    let cv = try getStringInstance(records["cv"], "createVersion should be string")
    var latestSequenceNumber: Double?
    if let lsn = records["lsn"] {
        latestSequenceNumber = try assertNumberInstance(lsn, "lsn should be a number")
    }

    // Literal gates, not semver: only the exact creator version "1.0" is readable.
    try fluidAssert(jsParseFloat(snapshotMinReadVersion) >= jsParseFloat(mrv), 0x20f)  // driver >= server minReadVersion
    try fluidAssert(jsParseFloat(cv) >= jsParseFloat(snapshotMinReadVersion), 0x210)  // created with minReadVersion or above
    try fluidAssert(currentReadVersion == cv, 0x2c2)  // create version equals currentReadVersion

    let (snapshot, durationSnapshotTree) = try measure { try readSnapshotSection(records["snapshot"]) }
    let (blobContents, durationBlobs) = try measure { try readBlobSection(records["blobs"]) }
    let ops = try records["deltas"].map { try readOpsSection($0) } ?? []

    let parsed = CompactSnapshot(
        snapshotTree: snapshot.tree.snapshotTree,
        blobContents: blobContents.blobContents,
        ops: ops,
        sequenceNumber: try protocolCounter(snapshot.sequenceNumber),
        latestSequenceNumber: try latestSequenceNumber.map { try protocolCounter($0) })
    return ISnapshotContentsWithProps(
        snapshot: parsed,
        telemetryProps: SnapshotTelemetryProps(
            durationStructure: telemetryProps.durationStructure,
            durationStrings: telemetryProps.durationStrings,
            durationSnapshotTree: durationSnapshotTree,
            durationBlobs: durationBlobs,
            slowTreeStructureCount: snapshot.tree.slowTreeStructureCount,
            slowBlobStructureCount: blobContents.slowBlobStructureCount,
            treeStructureCountWithGroupId: snapshot.tree.treeStructureCountWithGroupId))
}

public func parseCompactSnapshotResponse(_ buffer: [UInt8]) throws -> ISnapshotContentsWithProps {
    try parseCompactSnapshotResponse(buffer[...])
}
