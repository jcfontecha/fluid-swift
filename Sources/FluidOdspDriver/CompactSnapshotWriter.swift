import FluidDriverDefinitions
import FluidJS

// Ports odsp-driver/src/compactSnapshotWriter.ts.

/// Writes header section of the snapshot.
private func writeSnapshotProps(_ node: NodeCore, _ latestSequenceNumber: Double?) throws {
    addStringProperty(node, "mrv", snapshotMinReadVersion)
    addStringProperty(node, "cv", snapshotMinReadVersion)
    try addNumberProperty(node, "lsn", latestSequenceNumber)
}

/// Represents blobs in the tree. Blob bytes are written raw (there is no base64 in the stream).
private func writeBlobsSection(
    _ snapshotNode: NodeCore,
    _ blobs: JSMap<JSString, CompactSnapshotBlobContent>
) {
    snapshotNode.addDictionaryString("blobs")
    let blobsNode = snapshotNode.addNode(.list)
    for (storageBlobId, blob) in blobs.entries {
        let blobNode = blobsNode.addNode()
        addDictionaryStringProperty(blobNode, "id", storageBlobId)
        blobNode.addString("data")
        switch blob {
        case .buffer(let bytes):
            blobNode.addBlob(bytes)
        case .blob(let contents, let encoding):
            switch encoding {
            case .base64:
                blobNode.addBlob(decodeNodeBase64(contents))
            case .utf8, nil:
                blobNode.addBlob(encodeUTF8(contents))
            }
        }
    }
}

/// Represents and serializes tree part of the snapshot.
private func writeTreeSection(_ snapshotNode: NodeCore, _ snapshotTree: CompactSnapshotTree) throws {
    snapshotNode.addDictionaryString("treeNodes")
    let treesNode = snapshotNode.addNode(.list)
    writeTreeSectionCore(treesNode, snapshotTree)
}

private func writeTreeSectionCore(_ treesNode: NodeCore, _ snapshotTree: CompactSnapshotTree) {
    for (path, value) in snapshotTree.trees.entries {
        let treeNode = treesNode.addNode()
        // Many leaf nodes in the tree have same names like "content", "body", "header".
        // The dictionary is used for all of them: reuse is likely enough.
        addDictionaryStringProperty(treeNode, "name", path)
        // The flag is read from the enclosing tree, not from `value`.
        if snapshotTree.unreferenced == true {
            addBoolProperty(treeNode, "unreferenced", true)
        }
        // Only write children prop if either blobs or trees are present.
        if !value.blobs.isEmpty || !value.trees.isEmpty {
            treeNode.addDictionaryString("children")
            let childNode = treeNode.addNode(.list)
            writeTreeSectionCore(childNode, value)
        }
        if let groupId = value.groupId {
            addDictionaryStringProperty(treeNode, "groupId", groupId)
        }
    }

    for (path, id) in snapshotTree.blobs.entries {
        let blobNode = treesNode.addNode()
        addDictionaryStringProperty(blobNode, "name", path)
        addDictionaryStringProperty(blobNode, "value", id)
    }
}

/// Represents (serializes) snapshot tree as generalized tree.
private func writeSnapshotSection(
    _ rootNode: NodeCore,
    _ snapshotTree: CompactSnapshotTree,
    _ snapshotSequenceNumber: Int
) throws {
    rootNode.addDictionaryString("snapshot")
    let snapshotNode = rootNode.addNode()

    guard let snapshotId = snapshotTree.id else {
        throw OdspSnapshotError.assertionFailed(code: 0x21b)  // "Snapshot id should be provided"
    }
    addStringProperty(snapshotNode, "id", snapshotId)
    addStringProperty(snapshotNode, "message", JSString("Snapshot@\(snapshotSequenceNumber)"))
    try addNumberProperty(snapshotNode, "sequenceNumber", Double(snapshotSequenceNumber))

    // Add Trees
    try writeTreeSection(snapshotNode, snapshotTree)
}

/// `op.sequenceNumber` for a JSON operation: `nil` is `undefined`, and `null` has no properties.
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

/// What `addNumber` receives for a JS value: only a number can be an integer.
private func numberOrNil(_ value: JSONValue?) -> Double? {
    if case .number(let number) = value {
        return number
    }
    return nil
}

/// Represents ops in the tree.
private func writeOpsSection(_ rootNode: NodeCore, _ ops: [JSONValue]) throws {
    guard let firstOp = ops.first else {
        return
    }
    // An operation without a sequence number silently omits the whole section.
    guard let firstSequenceNumber = try opSequenceNumber(of: firstOp) else {
        return
    }
    rootNode.addDictionaryString("deltas")
    let opsNode = rootNode.addNode()
    try addNumberProperty(opsNode, "firstSequenceNumber", numberOrNil(firstSequenceNumber))
    opsNode.addDictionaryString("deltas")
    let deltaNode = opsNode.addNode(.list)
    for op in ops {
        deltaNode.addString(JSString(JSON.stringify(op)))
    }
}

/// Converts trees/blobs/ops to binary compact representation.
public func convertToCompactSnapshot(_ snapshotContents: CompactSnapshot) throws -> [UInt8] {
    let builder = TreeBuilderSerializer()
    // Create the root node.
    let rootNode = builder.addNode()
    guard let sequenceNumber = snapshotContents.sequenceNumber else {
        throw OdspSnapshotError.assertionFailed(code: 0x21c)  // "Seq number should be provided"
    }

    let latestSequenceNumber: Double?
    if let explicit = snapshotContents.latestSequenceNumber {
        latestSequenceNumber = Double(explicit)
    } else if let lastOp = snapshotContents.ops.last {
        latestSequenceNumber = numberOrNil(try opSequenceNumber(of: lastOp))
    } else {
        latestSequenceNumber = Double(sequenceNumber)
    }

    try writeSnapshotProps(rootNode, latestSequenceNumber)

    try writeSnapshotSection(rootNode, snapshotContents.snapshotTree, sequenceNumber)

    // Add Blobs
    writeBlobsSection(rootNode, snapshotContents.blobContents)

    // Then write the ops node.
    try writeOpsSection(rootNode, snapshotContents.ops)

    return try builder.serialize()
}
