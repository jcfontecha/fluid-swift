import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Foundation
import Synchronization

/// definitions.ts ISnapshotTreeVersion: a cached snapshot tree and the version it was read for.
struct ISnapshotTreeVersion: Sendable {
    let id: JSString
    let snapshotTree: ISnapshotTreeEx
}

/// shreddedSummaryDocumentStorageService.ts `blobsShaCache`: the blob shas storage already has.
/// Only the keys matter. Shared between the storage service and its upload managers.
final class BlobsShaCache: Sendable {
    let shas = Mutex<[String: String]>([:])
}

/// Ports shreddedSummaryDocumentStorageService.ts: git storage read and written piece by piece,
/// through the historian REST API (historian.ts) under the resolved URL's storage endpoint.
/// It has no getSnapshot.
final class ShreddedSummaryDocumentStorageService: Sendable {
    let id: String
    private let rest: RestClient
    private let blobCache: InMemoryCache<[UInt8]>?
    private let snapshotTreeCache: InMemoryCache<ISnapshotTreeVersion>?
    private let blobsShaCache = BlobsShaCache()

    /// TS keeps the factory's caches when `enableRestLess` is set or in Node; this client is never a
    /// browser, so it always does. A nil snapshot-tree cache is the factory's NullCache.
    init(id: String, rest: RestClient, blobCache: InMemoryCache<[UInt8]>, snapshotTreeCache: InMemoryCache<ISnapshotTreeVersion>?) {
        self.id = id
        self.rest = rest
        self.blobCache = blobCache
        self.snapshotTreeCache = snapshotTreeCache
    }

    /// historian.ts getCommits: a 400 or 404 means no versions.
    func getVersions(_ versionId: JSString?, count: Int) async throws -> [IVersion] {
        let requested = versionId?.description ?? ""
        let id = requested.isEmpty ? self.id : requested
        let commits: [JSONValue]
        do {
            commits = try await rest.get("/commits?count=\(count)&sha=\(encodeURIComponent(id))").asArray()
        } catch let error as DriverError where error.statusCode == 400 || error.statusCode == 404 {
            commits = []
        }
        return try commits.map { value in
            let commit = try Git.ICommitDetails(json: value)
            var version = JSObject<JSONValue>()
            version["date"] = .string(commit.commit.author.date)
            version["id"] = .string(commit.sha)
            version["treeId"] = .string(commit.commit.tree.sha)
            return try IVersion(json: .object(version))
        }
    }

    func getSnapshotTree(_ version: IVersion?) async throws -> ISnapshotTreeEx? {
        var requestVersion = version
        if requestVersion == nil {
            let versions = try await getVersions(JSString(id), count: 1)
            guard let latest = versions.first else { return nil }
            requestVersion = latest
        }
        guard let requestVersion, let treeId = requestVersion.treeId else {
            throw JSONDecodingError("routerlicious version without a tree id")
        }
        if let cached = snapshotTreeCache?.get(cacheKey(treeId)) {
            return cached.snapshotTree
        }
        let rawTree = try Git.ITree(json: await rest.get("/git/trees/\(encodeURIComponent(treeId.description))?recursive=1"))
        let tree = try blobsShaCache.shas.withLock { shas in
            try buildGitTreeHierarchy(rawTree, blobsShaToPathCache: &shas, removeAppTreePrefix: true)
        }
        snapshotTreeCache?.put(cacheKey(tree.id), ISnapshotTreeVersion(id: requestVersion.id, snapshotTree: tree))
        return tree
    }

    func readBlob(_ blobId: JSString) async throws -> [UInt8] {
        if let cached = blobCache?.get(cacheKey(blobId)) {
            return cached
        }
        let value = try Git.IBlob(json: await rest.get("/git/blobs/\(encodeURIComponent(blobId.description))"))
        blobsShaCache.shas.withLock { $0[value.sha.description] = "" }
        let bytes = try stringToBuffer(value.content, encoding: value.encoding)
        blobCache?.put(cacheKey(value.sha), bytes)
        return bytes
    }

    func uploadSummaryWithContext(_ summary: SummaryTree, context: ISummaryContext) async throws -> JSString {
        let manager = SummaryTreeUploadManager(rest: rest, blobsShaCache: blobsShaCache) { parentHandle in
            try await self.getPreviousFullSnapshot(parentHandle)
        }
        return try await manager.writeSummaryTree(summary, parentHandle: context.ackHandle ?? "")
    }

    func downloadSummary(_ handle: ISummaryHandle) async throws -> SummaryTree {
        throw JSONDecodingError("NOT IMPLEMENTED!")
    }

    func createBlob(_ file: [UInt8]) async throws -> ICreateBlobResponse {
        var body = JSObject<JSONValue>()
        body["content"] = .string(JSString(Data(file).base64EncodedString()))
        body["encoding"] = .string("base64")
        let response = try Git.ICreateBlobResponse(json: await rest.post("/git/blobs", body: .object(body)))
        var result = JSObject<JSONValue>()
        result["id"] = .string(response.sha)
        result["url"] = .string(response.url)
        return try ICreateBlobResponse(json: .object(result))
    }

    /// A missing parent version falls through to the latest snapshot, as in TS. The sha cache is
    /// cleared first and refilled only when the tree is not already cached.
    private func getPreviousFullSnapshot(_ parentHandle: JSString) async throws -> ISnapshotTreeEx? {
        guard !parentHandle.description.isEmpty else { return nil }
        let versions = try await getVersions(parentHandle, count: 1)
        blobsShaCache.shas.withLock { $0.removeAll() }
        return try await getSnapshotTree(versions.first)
    }

    private func cacheKey(_ blobId: JSString) -> String {
        "\(id):\(blobId)"
    }
}

/// client-utils stringToBuffer for the encodings git blobs carry. Base64 decoding is lenient, as
/// Node's Buffer is.
func stringToBuffer(_ content: JSString, encoding: JSString) throws -> [UInt8] {
    switch encoding.description {
    case "base64":
        guard let data = Data(base64Encoded: content.description, options: .ignoreUnknownCharacters) else {
            throw JSONDecodingError("invalid base64 blob")
        }
        return Array(data)
    case "utf-8", "utf8":
        return Array(content.description.utf8)
    default:
        throw JSONDecodingError("unsupported blob encoding \(encoding)")
    }
}
