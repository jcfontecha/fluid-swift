import FluidDriverDefinitions
import FluidJS
import Foundation

/// odspSummaryUploadManager.ts.
public final class OdspSummaryUploadManager {
    public private(set) var lastSummaryProposalHandle: String?
    private let snapshotStorageUrl: String
    private let network: OdspNetwork
    public init(snapshotStorageUrl: String, network: OdspNetwork) {
        self.snapshotStorageUrl = snapshotStorageUrl
        self.network = network
    }
    public func convertSummaryToSnapshotTree(_ tree: ISummaryTree, parentHandle: String?) throws -> [JSONValue] {
        try tree.tree.entries.map { key, child in
            guard !key.description.contains("/") else { throw JSONDecodingError("0x9cd") }
            var entry = JSObject<JSONValue>()
            switch child {
            case .tree(let subtree):
                var value = JSObject<JSONValue>()
                value["type"] = .string("tree")
                value["entries"] = .array(try convertSummaryToSnapshotTree(subtree, parentHandle: parentHandle))
                entry["value"] = .object(value)
                entry["path"] = .string(key)
                entry["type"] = .string("tree")
                if subtree.unreferenced == true { entry["unreferenced"] = .bool(true) }
                if let group = subtree.groupId { entry["groupId"] = .string(group) }
            case .blob(let blob):
                var value = JSObject<JSONValue>()
                value["type"] = .string("blob")
                switch blob.content {
                case .text(let text):
                    value["content"] = .string(text)
                    value["encoding"] = .string("utf-8")
                case .binary(let bytes):
                    value["content"] = .string(JSString(Data(bytes).base64EncodedString()))
                    value["encoding"] = .string("base64")
                }
                entry["value"] = .object(value)
                entry["path"] = .string(key)
                entry["type"] = .string("blob")
            case .handle(let handle):
                guard let parentHandle, !parentHandle.isEmpty else { throw JSONDecodingError("Parent summary does not exist to reference by handle.") }
                let path = handle.handle.description
                entry["path"] = .string(key)
                entry["type"] = .string(handle.handleType == .tree ? "tree" : "blob")
                entry["id"] = .string(JSString(parentHandle + "/.app" + (path.isEmpty || path.hasPrefix("/") ? path : "/" + path)))
            case .attachment(let attachment):
                entry["path"] = .string(key)
                entry["type"] = .string("blob")
                entry["id"] = .string(attachment.id)
            }
            return .object(entry)
        }
    }
    /// `relayServiceTenantAndSessionId` is `${tenantId}/${sessionId}` from the last join session, if any.
    nonisolated(nonsending) public func writeSummaryTree(_ tree: ISummaryTree, context: ISummaryContext, relayServiceTenantAndSessionId: String?) async throws -> String {
        var payload = JSObject<JSONValue>()
        payload["entries"] = .array(try convertSummaryToSnapshotTree(tree, parentHandle: context.ackHandle?.description))
        payload["message"] = .string("app")
        payload["sequenceNumber"] = .number(Double(context.referenceSequenceNumber))
        payload["type"] = .string((tree.tree[".app"] != nil && tree.tree[".protocol"] != nil) || context.ackHandle == nil ? "container" : "channel")
        let bytes = Data(JSON.stringify(.object(payload)).utf8)
        let url = snapshotStorageUrl + "/snapshot"
        let response = try await network.authorized(url: url) { auth, _ in
            var headers = ["Content-Type": "application/json", "Authorization": auth]
            if let relayServiceTenantAndSessionId {
                var match = "fluid:sessionid=" + relayServiceTenantAndSessionId
                if let parent = context.ackHandle?.description, !parent.isEmpty { match += ";containerid=" + parent }
                headers["If-Match"] = match
            }
            return OdspRequest(url: url, headers: headers, body: bytes, timeoutMs: nil, fetchType: .uploadSummary)
        }
        let id = try response.json().member("id").asString().description
        guard !id.isEmpty else { throw JSONDecodingError("Failed to write summary tree") }
        lastSummaryProposalHandle = id
        return id
    }
}
