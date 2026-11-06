import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Foundation

/// Ports routerlicious-driver/src/documentStorageService.ts and shreddedSummaryDocumentStorageService.ts.
public struct DocumentStorageService: Sendable {
    public let endpoint: String
    public let document: String
    public let tokens: any ITokenProvider
    public init(endpoint: String, document: String, tokens: any ITokenProvider) {
        self.endpoint = endpoint
        self.document = document
        self.tokens = tokens
    }
    private var rest: RestClient {
        RestClient(endpoint: endpoint, document: document, tokens: tokens)
    }
    /// Tinylicious 7 uses shredded git summaries (the 3.11 default driver policy).
    public func snapshot(version: JSString? = nil) async throws -> SummaryTree {
        let commits = try await rest.get(
            "/repos/tinylicious/commits?count=1&sha=\(encodeURIComponent(version?.description ?? document))"
        ).asArray().map { try Git.ICommitDetails(json: $0) }
        guard let latest = commits.first else { throw JSONDecodingError("no document version") }
        let treeID = latest.commit.tree.sha.description
        let tree = try Git.ITree(
            json: await rest.get(
                "/repos/tinylicious/git/trees/\(encodeURIComponent(treeID))?recursive=1")
        )
        var entries = JSObject<SummaryObject>()
        for entry in tree.tree where entry.type == "blob" || entry.type == "commit" {
            if entry.path.description.hasPrefix(".blobs/"), entry.path != ".blobs/.redirectTable" {
                var attachment = JSObject<JSONValue>()
                attachment["type"] = .number(4)
                attachment["id"] = .string(entry.sha)
                entries[entry.path] = .attachment(try ISummaryAttachment(json: .object(attachment)))
                continue
            }
            let blob = try Git.IBlob(json: await rest.get("/repos/tinylicious/git/blobs/\(encodeURIComponent(entry.sha.description))"))
            let text: String
            if blob.encoding == "base64" {
                guard let data = Data(base64Encoded: blob.content.description),
                    let decoded = String(data: data, encoding: .utf8)
                else { throw JSONDecodingError("invalid UTF-8 snapshot blob") }
                text = decoded
            } else {
                text = blob.content.description
            }
            entries[entry.path] = .blob(ISummaryBlob(content: .text(JSString(text))))
        }
        func subtree(_ prefix: String) -> SummaryTree {
            var children = JSObject<SummaryObject>()
            for (path, value) in entries.entries {
                let path = path.description
                guard path.hasPrefix(prefix) else { continue }
                let relative = String(path.dropFirst(prefix.count))
                if let slash = relative.firstIndex(of: "/") {
                    let name = String(relative[..<slash])
                    if children[JSString(name)] == nil, case .tree(let tree) = subtree(prefix + name + "/") {
                        children[JSString(name)] = .tree(tree)
                    }
                } else {
                    children[JSString(relative)] = value
                }
            }
            return SummaryTree(tree: children)
        }
        return subtree("")
    }

    public func protocolSnapshot() async throws -> IProtocolState {
        try Self.protocolState(await snapshot())
    }

    public static func protocolState(_ snapshot: SummaryTree) throws -> IProtocolState {
        let protocolTree = try SummaryTree(json: snapshot.json.member("tree").member(".protocol"))
        var result = JSObject<JSONValue>()
        for name: JSString in ["attributes", "quorumMembers", "quorumProposals", "quorumValues"] {
            result[name] = try protocolTree.readAndParse(name)
        }
        let attributes = try IDocumentAttributes(json: .object(result).member("attributes"))
        var state = JSObject<JSONValue>()
        state["sequenceNumber"] = .number(Double(attributes.sequenceNumber))
        state["minimumSequenceNumber"] = .number(Double(attributes.minimumSequenceNumber))
        state["members"] = result["quorumMembers"]
        state["proposals"] = result["quorumProposals"]
        state["values"] = result["quorumValues"]
        return try IProtocolState(json: .object(state))
    }
}
