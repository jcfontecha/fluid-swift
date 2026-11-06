import FluidDriverDefinitions
import FluidJS
import Foundation
import Synchronization

struct INormalizedWholeSnapshot: Sendable {
    let id: JSString
    let snapshotTree: ISnapshotTree
    let blobs: [String: [UInt8]]
}

/// Ports r11sSnapshotParser.ts. Flat entries are breadth-first; .app children are lifted.
func convertWholeFlatSnapshotToSnapshotTreeAndBlobs(_ value: JSONValue, treePrefixToRemove: String = ".app") throws -> INormalizedWholeSnapshot {
    final class Node {
        var fields = JSObject<JSONValue>()
        var blobs = JSObject<JSONValue>()
        var trees = JSObject<Node>()
        var json: JSONValue {
            var result = fields
            result["blobs"] = .object(blobs)
            var children = JSObject<JSONValue>()
            for (name, tree) in trees.entries { children[name] = tree.json }
            result["trees"] = .object(children)
            return .object(result)
        }
    }
    let flat = try value.member("trees").asArray()[0]
    let root = Node()
    root.fields["id"] = try flat.member("id")
    var lookup = ["": root]
    for entry in try flat.member("entries").asArray() {
        var path = try entry.member("path").asString().description
        if path.hasPrefix(treePrefixToRemove + "/") { path.removeFirst(treePrefixToRemove.count + 1) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let parent = parts.dropLast().joined(separator: "/")
        guard let node = lookup[parent], let name = parts.last?.removingPercentEncoding else {
            throw JSONDecodingError("Invalid flat summary path")
        }
        if try entry.member("type").asString() == "tree" {
            let child = Node()
            let fields = try entry.asObject()
            child.fields["unreferenced"] = fields["unreferenced"]
            child.fields["groupId"] = fields["groupId"]
            node.trees[JSString(name)] = child
            lookup[path] = child
        } else if try entry.member("type").asString() == "blob" {
            node.blobs[JSString(name)] = try entry.member("id")
        } else { throw JSONDecodingError("Unknown entry type!!") }
    }
    var blobs: [String: [UInt8]] = [:]
    if case .array(let entries) = try value.asObject()["blobs"] {
        for blob in entries {
            let encoding = try blob.asObject()["encoding"]?.asString() ?? "utf-8"
            blobs[try blob.member("id").asString().description] = try stringToBuffer(blob.member("content").asString(), encoding: encoding)
        }
    }
    return try INormalizedWholeSnapshot(id: value.member("id").asString(), snapshotTree: ISnapshotTree(json: root.json), blobs: blobs)
}

/// Ports wholeSummaryDocumentStorageService.ts. Whole reads seed both tree and blob caches.
final class WholeSummaryDocumentStorageService: RouterliciousStorage {
    let id: String
    let rest: RestClient
    let blobCache: InMemoryCache<[UInt8]>
    let snapshotTreeCache: InMemoryCache<INormalizedWholeSnapshot>?
    let discovery: Bool
    private let firstVersionsCall = Mutex(true)
    init(id: String, rest: RestClient, blobCache: InMemoryCache<[UInt8]>, snapshotTreeCache: InMemoryCache<INormalizedWholeSnapshot>?, discovery: Bool) {
        self.id = id
        self.rest = rest
        self.blobCache = blobCache
        self.snapshotTreeCache = snapshotTreeCache
        self.discovery = discovery
    }
    private func key(_ id: JSString) -> String { "\(self.id):\(id)" }
    private func fetch(_ version: JSString, disableCache: Bool = false) async throws -> INormalizedWholeSnapshot {
        let suffix = disableCache ? "?disableCache=true" : ""
        let snapshot = try convertWholeFlatSnapshotToSnapshotTreeAndBlobs(await rest.get("/git/summaries/\(encodeURIComponent(version.description))\(suffix)"))
        snapshotTreeCache?.put(key(version), snapshot)
        return snapshot
    }
    private func cacheBlobs(_ snapshot: INormalizedWholeSnapshot) {
        for (id, bytes) in snapshot.blobs { blobCache.put(key(JSString(id)), bytes) }
    }
    func getVersions(_ versionId: JSString?, count: Int) async throws -> [IVersion] {
        if let versionId, versionId.description != id {
            var result = JSObject<JSONValue>()
            result["id"] = .string(versionId)
            return [try IVersion(json: .object(result))]
        }
        if firstVersionsCall.withLock({ $0 }), count == 1 {
            // TS always starts the network request, even when the latest cache wins.
            let cached = snapshotTreeCache?.get(key("latest"))
            let network = Task { try await self.fetch("latest", disableCache: self.discovery) }
            let selected: INormalizedWholeSnapshot
            if let cached { selected = cached }
            else { selected = try await network.value }
            snapshotTreeCache?.put(key(selected.id), selected)
            cacheBlobs(selected)
            firstVersionsCall.withLock { $0 = false }
            var result = JSObject<JSONValue>()
            result["id"] = .string(selected.id)
            result["treeId"] = .string(selected.snapshotTree.id!)
            return [try IVersion(json: .object(result))]
        }
        let commits = try await rest.get("/commits?count=\(count)&sha=\(encodeURIComponent(versionId?.description ?? id))").asArray()
        return try commits.map { raw in
            let commit = try Git.ICommitDetails(json: raw)
            return try IVersion(json: .object(r11sObject( [("date", .string(commit.commit.author.date)), ("id", .string(commit.sha)), ("treeId", .string(commit.commit.tree.sha))])))
        }
    }
    func getSnapshotTree(_ version: IVersion?) async throws -> ISnapshotTree? {
        let requested: IVersion
        if let version { requested = version }
        else {
            guard let latest = try await getVersions(JSString(id), count: 1).first else { return nil }
            requested = latest
        }
        if let cached = snapshotTreeCache?.get(key(requested.id)) { return cached.snapshotTree }
        let snapshot = try await fetch(requested.id)
        cacheBlobs(snapshot)
        return snapshot.snapshotTree
    }
    func readBlob(_ id: JSString) async throws -> [UInt8] {
        if let bytes = blobCache.get(key(id)) { return bytes }
        let blob = try Git.IBlob(json: await rest.get("/git/blobs/\(encodeURIComponent(id.description))"))
        let bytes = try stringToBuffer(blob.content, encoding: blob.encoding)
        blobCache.put(key(blob.sha), bytes)
        return bytes
    }
    func createBlob(_ file: [UInt8]) async throws -> ICreateBlobResponse {
        let result = try await rest.post("/git/blobs", body: .object(r11sObject( [("content", .string(JSString(Data(file).base64EncodedString()))), ("encoding", .string("base64"))])))
        return try ICreateBlobResponse(json: .object(r11sObject( [("id", try result.member("sha")), ("url", try result.member("url"))])))
    }
    func uploadSummaryWithContext(_ summary: SummaryTree, context: ISummaryContext) async throws -> JSString {
        try await WholeSummaryUploadManager(manager: rest).writeSummaryTree(summary, parentHandle: context.ackHandle ?? "")
    }
    func downloadSummary(_ handle: ISummaryHandle) async throws -> SummaryTree {
        let snapshot = try convertWholeFlatSnapshotToSnapshotTreeAndBlobs(await rest.get("/git/summaries/\(encodeURIComponent(handle.handle.description))"), treePrefixToRemove: "")
        func convert(_ tree: ISnapshotTree) throws -> SummaryTree {
            var entries = JSObject<SummaryObject>()
            for (name, id) in tree.blobs.entries {
                guard let bytes = snapshot.blobs[id.description] else { throw JSONDecodingError("Missing summary blob") }
                entries[name] = .blob(ISummaryBlob(content: .text(JSString(String(decoding: bytes, as: UTF8.self)))))
            }
            for (name, child) in tree.trees.entries { entries[name] = try SummaryObject(json: convert(child).json) }
            var result = try ISummaryTree(tree: entries).json.asObject()
            if let unreferenced = tree.unreferenced { result["unreferenced"] = .bool(unreferenced) }
            if let groupId = tree.groupId { result["groupId"] = .string(groupId) }
            return try SummaryTree(json: .object(result))
        }
        return try convert(snapshot.snapshotTree)
    }
}

func r11sObject(_ entries: [(JSString, JSONValue)]) -> JSObject<JSONValue> {
    var result = JSObject<JSONValue>()
    for (key, value) in entries { result[key] = value }
    return result
}
