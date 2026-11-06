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
    public func protocolSnapshot() async throws -> IProtocolState {
        let commits = try await rest.get(
            "/repos/tinylicious/commits?count=1&sha=\(encodeURIComponent(document))"
        ).asArray().map { try Git.ICommitDetails(json: $0) }
        guard let latest = commits.first else { throw JSONDecodingError("no document version") }
        let treeID = latest.commit.tree.sha.description
        let tree = try Git.ITree(
            json: await rest.get(
                "/repos/tinylicious/git/trees/\(encodeURIComponent(treeID))?recursive=1")
        )
        let entries = tree.tree
        var result = JSObject<JSONValue>()
        for name in ["attributes", "quorumMembers", "quorumProposals", "quorumValues"] {
            guard let entry = entries.first(where: { $0.path.description == ".protocol/" + name })
            else {
                throw JSONDecodingError("missing protocol blob \(name)")
            }
            let id = entry.sha.description
            let blob = try Git.IBlob(
                json: await rest.get("/repos/tinylicious/git/blobs/\(encodeURIComponent(id))"))
            let content = blob.content.description
            let encoding = blob.encoding.description
            let text: String
            if encoding == "base64" {
                guard let data = Data(base64Encoded: content),
                    let decoded = String(data: data, encoding: .utf8)
                else { throw JSONDecodingError("invalid base64 blob") }
                text = decoded
            } else {
                text = content
            }
            result[JSString(name)] = try JSON.parse(text)
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
