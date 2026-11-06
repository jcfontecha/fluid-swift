import FluidDriverDefinitions
import FluidJS
import Foundation

/// Ports routerlicious-driver/src/wholeSummaryUploadManager.ts and storageUtils.ts.
public struct WholeSummaryUploadManager: Sendable {
    let rest: RestClient
    public static func payload(_ summary: SummaryTree, parentHandle: JSString?) throws -> JSONValue {
        func entries(_ tree: ISummaryTree) throws -> [JSONValue] {
            try tree.tree.entries.map { key, child in
                var entry = JSObject<JSONValue>()
                var value = JSObject<JSONValue>()
                var id: JSString?
                var type: JSString = "blob"
                switch child {
                case .tree(let tree):
                    type = "tree"
                    value["type"] = .string(type)
                    value["entries"] = .array(try entries(tree))
                    entry["value"] = .object(value)
                    if tree.unreferenced == true { entry["unreferenced"] = .bool(true) }
                case .blob(let blob):
                    value["type"] = .string(type)
                    switch blob.content {
                    case .text(let text):
                        value["content"] = .string(text)
                        value["encoding"] = .string("utf-8")
                    case .binary(let bytes):
                        value["content"] = .string(JSString(Data(bytes).base64EncodedString()))
                        value["encoding"] = .string("base64")
                    }
                    entry["value"] = .object(value)
                case .attachment(let attachment): id = attachment.id
                case .handle(let handle):
                    type = handle.handleType == .tree ? "tree" : "blob"
                    if try handle.json.asObject()["embedded"] == .bool(true) { id = handle.handle }
                    else {
                        guard let parentHandle, !parentHandle.description.isEmpty else { throw JSONDecodingError("Parent summary required") }
                        let parts = [parentHandle.description, ".app", handle.handle.description].map { part in
                            var result = part
                            if result.hasPrefix("/") { result.removeFirst() }
                            if result.hasSuffix("/") { result.removeLast() }
                            return result
                        }.filter { !$0.isEmpty }
                        id = JSString(parts.joined(separator: "/"))
                    }
                }
                entry["path"] = .string(JSString(encodeURIComponent(key.description)))
                entry["type"] = .string(type)
                if let id {
                    guard !id.description.isEmpty else { throw JSONDecodingError("Invalid tree entry") }
                    entry["id"] = .string(id)
                }
                return .object(entry)
            }
        }
        guard case .tree(let tree) = summary else { throw JSONDecodingError("summary root must be a tree") }
        var payload = JSObject<JSONValue>()
        payload["entries"] = .array(try entries(tree))
        payload["message"] = .string("")
        payload["sequenceNumber"] = .number(0)
        payload["type"] = .string("channel")
        return .object(payload)
    }
    public func writeSummaryTree(_ summary: SummaryTree, parentHandle: JSString?) async throws -> JSString {
        try await rest.post("/repos/tinylicious/git/summaries?initial=false", body: Self.payload(summary, parentHandle: parentHandle)).member("id").asString()
    }
}

extension DocumentStorageService {
    public func latestVersion() async throws -> JSString {
        let rest = RestClient(endpoint: endpoint, document: document, tokens: tokens)
        let commits = try await rest.get("/repos/tinylicious/commits?count=1&sha=\(encodeURIComponent(document))").asArray()
        guard let commit = commits.first else { throw JSONDecodingError("no document version") }
        return try Git.ICommitDetails(json: commit).sha
    }
    public func uploadSummaryWithContext(_ summary: SummaryTree, context: ISummaryContext, wholeSummary: Bool = false) async throws -> JSString {
        let rest = RestClient(endpoint: endpoint, document: document, tokens: tokens)
        if wholeSummary {
            return try await WholeSummaryUploadManager(rest: rest).writeSummaryTree(summary, parentHandle: context.ackHandle)
        }
        return try await SummaryTreeUploadManager(rest: rest).writeSummaryTree(summary, parentHandle: context.ackHandle)
    }
}
