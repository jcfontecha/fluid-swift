import CryptoKit
import FluidDriverDefinitions
import FluidJS
import Foundation

/// Ports routerlicious-driver/src/summaryTreeUploadManager.ts.
public final class SummaryTreeUploadManager {
    private let rest: RestClient
    private var blobsShaCache: Set<String> = []
    init(rest: RestClient) { self.rest = rest }

    public nonisolated(nonsending) func writeSummaryTree(_ summary: SummaryTree, parentHandle: JSString?) async throws -> JSString {
        var previous: [String: (JSString, JSString)] = [:]
        if let parentHandle, !parentHandle.description.isEmpty {
            let commits = try await rest.get("/repos/tinylicious/commits?count=1&sha=\(encodeURIComponent(parentHandle.description))").asArray()
            guard let commit = commits.first else { throw JSONDecodingError("Parent summary does not exist") }
            let treeId = try Git.ICommitDetails(json: commit).commit.tree.sha
            let tree = try Git.ITree(json: await rest.get("/repos/tinylicious/git/trees/\(encodeURIComponent(treeId.description))?recursive=1"))
            blobsShaCache.removeAll()
            previous[""] = (treeId, "tree")
            for entry in tree.tree {
                let path = entry.path.description.hasPrefix(".app/") ? String(entry.path.description.dropFirst(5)) : entry.path.description
                previous[path] = (entry.sha, entry.type)
                if entry.type == "blob" { blobsShaCache.insert(entry.sha.description) }
            }
        }
        return try await write(try SummaryObject(json: summary.json), previous: previous)
    }
    private nonisolated(nonsending) func write(_ object: SummaryObject, previous: [String: (JSString, JSString)]) async throws -> JSString {
        switch object {
        case .attachment(let attachment): return attachment.id
        case .handle(let handle):
            guard handle.handleType == .tree || handle.handleType == .blob else {
                throw JSONDecodingError("Unexpected handle summary object type")
            }
            var parts = handle.handle.description.components(separatedBy: "/")
            if parts.first == "" { parts.removeFirst() }
            let path = try parts.map { part in
                guard let decoded = part.removingPercentEncoding else {
                    throw JSONDecodingError("invalid encoded handle path")
                }
                return decoded
            }.joined(separator: "/")
            guard let (id, type) = previous[path], type == (handle.handleType == .tree ? "tree" : "blob") else {
                throw JSONDecodingError("Parent summary does not have handle for specified path: \(path)")
            }
            return id
        case .blob(let blob):
            let bytes: Data
            let content: JSString
            let encoding: JSString
            switch blob.content {
            case .text(let text):
                bytes = Data(text.description.utf8)
                content = text
                encoding = "utf-8"
            case .binary(let value):
                bytes = Data(value)
                content = JSString(bytes.base64EncodedString())
                encoding = "base64"
            }
            let hash = Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8) + bytes).map { String(format: "%02x", $0) }.joined()
            if blobsShaCache.insert(hash).inserted {
                var body = JSObject<JSONValue>()
                body["content"] = .string(content)
                body["encoding"] = .string(encoding)
                let response = try await rest.post("/repos/tinylicious/git/blobs", body: .object(body))
                guard try response.member("sha").asString().description == hash else { throw JSONDecodingError("0x0b6: Blob.sha and hash do not match") }
            }
            return JSString(hash)
        case .tree(let tree):
            var entries: [JSONValue] = []
            for (key, child) in tree.tree.entries {
                let id = try await write(child, previous: previous)
                let isTree: Bool
                switch child {
                case .tree: isTree = true
                case .handle(let handle): isTree = handle.handleType == .tree
                default: isTree = false
                }
                var entry = JSObject<JSONValue>()
                entry["mode"] = .string(isTree ? "040000" : "100644")
                entry["path"] = .string(JSString(encodeURIComponent(key.description)))
                entry["sha"] = .string(id)
                entry["type"] = .string(isTree ? "tree" : "blob")
                entries.append(.object(entry))
            }
            var body = JSObject<JSONValue>()
            body["tree"] = .array(entries)
            return try await rest.post("/repos/tinylicious/git/trees", body: .object(body)).member("sha").asString()
        }
    }
}
