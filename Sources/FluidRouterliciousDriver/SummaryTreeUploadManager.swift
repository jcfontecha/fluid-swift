import CryptoKit
import FluidDriverDefinitions
import FluidJS
import Foundation

/// Ports routerlicious-driver/src/summaryTreeUploadManager.ts: write a summary as git blobs and
/// trees, resolving handles against the parent summary's snapshot tree. Children are written in
/// tree order, one at a time; TS writes them concurrently and keeps the same entry order.
final class SummaryTreeUploadManager {
    private let rest: RestClient
    private let blobsShaCache: BlobsShaCache
    private let getPreviousFullSnapshot: (JSString) async throws -> ISnapshotTreeEx?

    init(rest: RestClient, blobsShaCache: BlobsShaCache, getPreviousFullSnapshot: @escaping (JSString) async throws -> ISnapshotTreeEx?) {
        self.rest = rest
        self.blobsShaCache = blobsShaCache
        self.getPreviousFullSnapshot = getPreviousFullSnapshot
    }

    func writeSummaryTree(_ summary: SummaryTree, parentHandle: JSString) async throws -> JSString {
        let previousFullSnapshot = try await getPreviousFullSnapshot(parentHandle)
        guard case .tree(let tree) = summary else { throw JSONDecodingError("summary root must be a tree") }
        return try await writeSummaryTreeCore(tree, previousFullSnapshot: previousFullSnapshot)
    }

    private func writeSummaryTreeCore(_ summaryTree: ISummaryTree, previousFullSnapshot: ISnapshotTreeEx?) async throws -> JSString {
        var entries: [JSONValue] = []
        for (key, entry) in summaryTree.tree.entries {
            let pathHandle = try await writeSummaryTreeObject(entry, previousFullSnapshot: previousFullSnapshot)
            var treeEntry = JSObject<JSONValue>()
            treeEntry["mode"] = .string(getGitMode(entry))
            treeEntry["path"] = .string(JSString(encodeURIComponent(key.description)))
            treeEntry["sha"] = .string(pathHandle)
            treeEntry["type"] = .string(getGitType(entry))
            entries.append(.object(treeEntry))
        }
        var body = JSObject<JSONValue>()
        body["tree"] = .array(entries)
        return try await rest.post("/git/trees", body: .object(body)).member("sha").asString()
    }

    private func writeSummaryTreeObject(_ object: SummaryObject, previousFullSnapshot: ISnapshotTreeEx?) async throws -> JSString {
        switch object {
        case .blob(let blob):
            return try await writeSummaryBlob(blob.content)
        case .handle(let handle):
            guard let previousFullSnapshot else {
                throw JSONDecodingError("Parent summary does not exist to reference by handle.")
            }
            return try getIdFromPath(handle.handleType, handle.handle, previousFullSnapshot)
        case .tree(let tree):
            return try await writeSummaryTreeCore(tree, previousFullSnapshot: previousFullSnapshot)
        case .attachment(let attachment):
            return attachment.id
        }
    }

    /// The git blob sha is computed locally; a blob storage already has is not uploaded again.
    private func writeSummaryBlob(_ content: SummaryBlobContent) async throws -> JSString {
        let bytes: Data
        let parsedContent: JSString
        let encoding: JSString
        switch content {
        case .text(let text):
            bytes = Data(text.description.utf8)
            parsedContent = text
            encoding = "utf-8"
        case .binary(let value):
            bytes = Data(value)
            parsedContent = JSString(bytes.base64EncodedString())
            encoding = "base64"
        }
        let header = Data("blob \(bytes.count)\0".utf8)
        let hash = Insecure.SHA1.hash(data: header + bytes).map { String(format: "%02x", $0) }.joined()
        let isNew = blobsShaCache.shas.withLock { shas in
            guard shas[hash] == nil else { return false }
            shas[hash] = ""
            return true
        }
        if isNew {
            var body = JSObject<JSONValue>()
            body["content"] = .string(parsedContent)
            body["encoding"] = .string(encoding)
            let blob = try Git.ICreateBlobResponse(json: await rest.post("/git/blobs", body: .object(body)))
            guard blob.sha.description == hash else { throw JSONDecodingError("0x0b6: Blob.sha and hash do not match!!") }
        }
        return JSString(hash)
    }

    private func getIdFromPath(_ handleType: SummaryTypeNoHandle, _ handlePath: JSString, _ previousFullSnapshot: ISnapshotTreeEx) throws
        -> JSString
    {
        var path = try handlePath.description.components(separatedBy: "/").map { part in
            guard let decoded = part.removingPercentEncoding else { throw JSONDecodingError("URIError: URI malformed") }
            return decoded
        }
        if path.first == "" { path.removeFirst() }
        if path.isEmpty { return previousFullSnapshot.id }
        return try getIdFromPathCore(handleType, path[...], previousFullSnapshot)
    }

    private func getIdFromPathCore(_ handleType: SummaryTypeNoHandle, _ path: ArraySlice<String>, _ previousSnapshot: ISnapshotTreeEx) throws
        -> JSString
    {
        guard let part = path.first else { throw JSONDecodingError("0x0b3: Expected at least 1 path part") }
        let key = JSString(part)
        if path.count == 1 {
            switch handleType {
            case .blob:
                guard let id = previousSnapshot.blobs[key], !id.description.isEmpty else {
                    throw JSONDecodingError("0x0b4: Parent summary does not have blob handle for specified path.")
                }
                return id
            case .tree:
                guard let id = previousSnapshot.trees[key]?.id, !id.description.isEmpty else {
                    throw JSONDecodingError("0x0b5: Parent summary does not have tree handle for specified path.")
                }
                return id
            case .attachment:
                throw JSONDecodingError("Unexpected handle summary object type: \"\(handleType.rawValue)\".")
            }
        }
        guard let subtree = previousSnapshot.trees[key] else {
            throw JSONDecodingError("Parent summary does not have tree handle for specified path.")
        }
        return try getIdFromPathCore(handleType, path.dropFirst(), subtree)
    }
}

/// driver-utils/src/protocol/gitHelper.ts getGitMode.
private func getGitMode(_ value: SummaryObject) -> JSString {
    switch value {
    case .tree: "040000"
    case .handle(let handle): handle.handleType == .tree ? "040000" : "100644"
    case .blob, .attachment: "100644"
    }
}

/// driver-utils/src/protocol/gitHelper.ts getGitType.
private func getGitType(_ value: SummaryObject) -> JSString {
    switch value {
    case .tree: "tree"
    case .handle(let handle): handle.handleType == .tree ? "tree" : "blob"
    case .blob, .attachment: "blob"
    }
}
