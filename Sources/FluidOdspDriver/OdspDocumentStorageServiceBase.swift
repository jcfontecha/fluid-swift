import FluidDriverDefinitions
import FluidJS
import Foundation

/// odspDocumentStorageServiceBase.ts BlobCache. TS disables purging (`purgeEnabled = false`), so
/// the clear timer never starts and only oversized network reads are marked evicted.
struct BlobCache {
    private(set) var value = JSMap<JSString, [UInt8]>()
    private var blobsEvicted: Set<JSString> = []

    mutating func addBlobs(_ blobs: JSMap<JSString, CompactSnapshotBlobContent>) throws {
        for (id, content) in blobs.entries {
            value.set(id, try content.bytes())
        }
    }

    func getBlob(_ blobId: JSString) -> (blobContent: [UInt8]?, evicted: Bool) {
        (value.get(blobId), blobsEvicted.contains(blobId))
    }

    /// Runtime never reads the same blob twice, so blobs of 256 KiB or more are not cached.
    mutating func setBlob(_ blobId: JSString, _ blob: [UInt8]) {
        if blob.count < 256 * 1024 {
            value.set(blobId, blob)
        } else {
            blobsEvicted.insert(blobId)
        }
    }
}

extension CompactSnapshotBlobContent {
    /// The ArrayBuffer of a blob: parsed buffers as is, IBlob strings decoded (`stringToBuffer`).
    func bytes() throws -> [UInt8] {
        switch self {
        case .buffer(let bytes):
            return Array(bytes)
        case .blob(let contents, let encoding):
            if encoding == .base64 {
                guard let data = Data(base64Encoded: contents.description) else { throw JSONDecodingError("invalid base64 blob") }
                return Array(data)
            }
            return Array(contents.description.utf8)
        }
    }
}

/// ISnapshotTree JSON in the property order the TS producers build.
func snapshotTreeJSON(_ tree: CompactSnapshotTree) -> JSONValue {
    var object = JSObject<JSONValue>()
    if let id = tree.id { object["id"] = .string(id) }
    var blobs = JSObject<JSONValue>()
    for (name, id) in tree.blobs.entries { blobs[name] = .string(id) }
    object["blobs"] = .object(blobs)
    var trees = JSObject<JSONValue>()
    for (name, child) in tree.trees.entries { trees[name] = snapshotTreeJSON(child) }
    object["trees"] = .object(trees)
    if let unreferenced = tree.unreferenced { object["unreferenced"] = .bool(unreferenced) }
    if let groupId = tree.groupId { object["groupId"] = .string(groupId) }
    return .object(object)
}

// The OdspDocumentStorageServiceBase members. Swift actors cannot inherit, so the abstract base
// class is this extension of its only network-backed subclass.
extension OdspDocumentStorageService {
    public func readBlob(_ id: JSString) async throws -> [UInt8] {
        let (blobContent, evicted) = blobCache.getBlob(id)
        if let blobContent { return blobContent }
        return try await fetchBlobFromStorage(id, evicted: evicted)
    }

    public func getSnapshotTree(_ version: IVersion?, scenarioName: String?) async throws -> ISnapshotTree? {
        if snapshotUrl.isEmpty { return nil }
        let id: JSString
        if let versionId = version?.id, !versionId.description.isEmpty {
            id = versionId
        } else {
            let versions = try await getVersions(nil, count: 1, scenarioName: scenarioName, fetchSource: nil)
            guard let first = versions.first else { return nil }
            id = first.id
        }
        guard let snapshotTree = try await readTree(id, scenarioName: scenarioName) else { return nil }
        return try ISnapshotTree(json: combineProtocolAndAppSnapshotTree(snapshotTree))
    }

    public func downloadSummary(_ handle: ISummaryHandle) async throws -> SummaryTree {
        throw JSONDecodingError("Not implemented yet")
    }

    func readTree(_ id: JSString, scenarioName: String?) async throws -> CompactSnapshotTree? {
        if let tree = commitCache[id] { return tree }
        return try await fetchTreeFromSnapshot(id, scenarioName: scenarioName)
    }

    /// The uploaded container snapshot holds the app tree in ".app" and the protocol tree in
    /// ".protocol"; the root keeps only the app content plus the protocol subtree. A missing ".app"
    /// is a TypeError in TS (`hierarchicalAppTree.blobs` of undefined).
    func combineProtocolAndAppSnapshotTree(_ snapshotTree: CompactSnapshotTree) throws -> JSONValue {
        guard let app = snapshotTree.trees[".app"] else { throw JSONDecodingError("TypeError: Cannot read properties of undefined (reading 'blobs')") }
        var blobs = JSObject<JSONValue>()
        for (name, id) in app.blobs.entries { blobs[name] = .string(id) }
        var trees = JSObject<JSONValue>()
        for (name, child) in app.trees.entries { trees[name] = snapshotTreeJSON(child) }
        if let protocolTree = snapshotTree.trees[".protocol"] { trees[".protocol"] = snapshotTreeJSON(protocolTree) }
        var object = JSObject<JSONValue>()
        object["blobs"] = .object(blobs)
        object["trees"] = .object(trees)
        if let id = snapshotTree.id { object["id"] = .string(id) }
        return .object(object)
    }

    /// Returns the root tree ID (`undefined` for an ops-only snapshot).
    func initializeFromSnapshot(_ snapshot: CompactSnapshot, cacheOps: Bool, cacheSnapshot: Bool) throws -> JSString? {
        snapshotSequenceNumber = snapshot.sequenceNumber
        guard let id = snapshot.snapshotTree.id else { throw JSONDecodingError("0x221") }
        if cacheSnapshot { commitCache[id] = snapshot.snapshotTree }
        // Blobs are always cached: the container runtime does not cache them.
        try blobCache.addBlobs(snapshot.blobContents)
        if cacheOps {
            guard ops == nil else { throw JSONDecodingError("0x0a5") }
            ops = snapshot.ops
        }
        return id
    }
}
