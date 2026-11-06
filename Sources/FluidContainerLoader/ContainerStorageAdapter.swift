import FluidDriverDefinitions
import FluidJS

/// containerStorageAdapter.ts: the blob manager's tree and its redirect table.
private let blobsTreeName: JSString = ".blobs"
private let redirectTableBlobName: JSString = ".redirectTable"

/// Ports containerStorageAdapter.ts ISerializableBlobContents: blob id to UTF-8 text.
typealias ISerializableBlobContents = JSObject<JSString>

/// Ports containerStorageAdapter.ts `getBlobContentsFromTree`. An ISnapshot carries its blobs;
/// a snapshot tree's blobs are read from storage, except under the root `.blobs` tree, where
/// only the redirect table is read. Text is decoded as UTF-8 with replacement, as bufferToString does.
func getBlobContentsFromTree(_ snapshot: FetchedSnapshot, storage: any IDocumentStorageService) async throws
    -> ISerializableBlobContents
{
    var blobs = ISerializableBlobContents()
    switch snapshot {
    case .snapshot(let snapshot):
        for (id, content) in snapshot.blobContents.buffers.entries {
            blobs[id] = JSString(String(decoding: content, as: UTF8.self))
        }
    case .tree(let tree):
        try await getBlobContentsFromTreeCore(tree, blobs: &blobs, storage: storage, root: true)
    }
    return blobs
}

private func getBlobContentsFromTreeCore(
    _ tree: ISnapshotTree, blobs: inout ISerializableBlobContents, storage: any IDocumentStorageService, root: Bool
) async throws {
    for (key, subTree) in tree.trees.entries {
        if root && key == blobsTreeName {
            try await getBlobManagerTreeFromTree(subTree, blobs: &blobs, storage: storage)
        } else {
            try await getBlobContentsFromTreeCore(subTree, blobs: &blobs, storage: storage, root: false)
        }
    }
    for (_, id) in tree.blobs.entries {
        let blob = try await storage.readBlob(id)
        blobs[id] = JSString(String(decoding: blob, as: UTF8.self))
    }
}

/// containerStorageAdapter.ts `getBlobManagerTreeFromTree`, assert 0x9ce.
private func getBlobManagerTreeFromTree(
    _ tree: ISnapshotTree, blobs: inout ISerializableBlobContents, storage: any IDocumentStorageService
) async throws {
    guard let id = tree.blobs[redirectTableBlobName] else {
        throw JSONDecodingError("0x9ce: id is undefined in getBlobManagerTreeFromTree")
    }
    let blob = try await storage.readBlob(id)
    blobs[id] = JSString(String(decoding: blob, as: UTF8.self))
}

/// Swift-only bridge to the synchronous runtime, which loads a snapshot whose blobs are already
/// read (SnapshotLoad.swift). Combines the snapshot tree with its blob contents, as utils.ts
/// `combineSnapshotTreeAndSnapshotBlobs` does, then gives each node its blobs, then its trees,
/// the order ISnapshotTree exposes them. Under the root `.blobs` tree every entry but the
/// redirect table is an attachment id.
func summaryTreeFromSnapshot(_ tree: ISnapshotTree, blobContents: ISerializableBlobContents) throws -> SummaryTree {
    .tree(try summaryTreeNode(tree, blobContents: blobContents, root: true, blobManagerTree: false))
}

private func summaryTreeNode(
    _ tree: ISnapshotTree, blobContents: ISerializableBlobContents, root: Bool, blobManagerTree: Bool
) throws -> ISummaryTree {
    var entries = JSObject<SummaryObject>()
    for (name, id) in tree.blobs.entries {
        if blobManagerTree && name != redirectTableBlobName {
            var attachment = JSObject<JSONValue>()
            attachment["type"] = .number(Double(SummaryType.attachment.rawValue))
            attachment["id"] = .string(id)
            entries[name] = .attachment(try ISummaryAttachment(json: .object(attachment)))
            continue
        }
        guard let content = blobContents[id] else {
            throw JSONDecodingError("0x2ec: Blob must be present in blobsContents")
        }
        entries[name] = .blob(ISummaryBlob(content: .text(content)))
    }
    for (name, subtree) in tree.trees.entries {
        let child = try summaryTreeNode(
            subtree, blobContents: blobContents, root: false, blobManagerTree: root && name == blobsTreeName)
        entries[name] = .tree(child)
    }
    return ISummaryTree(tree: entries)
}
