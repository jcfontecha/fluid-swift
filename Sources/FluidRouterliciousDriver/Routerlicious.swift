import Foundation
import FluidJS
import FluidDriverBase

public struct TokenResponse: Sendable {
    public let jwt: String
    public let fromCache: Bool
    public init(jwt: String, fromCache: Bool) { self.jwt = jwt; self.fromCache = fromCache }
}
public protocol TokenProvider: Sendable {
    func fetchOrdererToken(tenantId: String, documentId: String?, refresh: Bool) async throws -> TokenResponse
    func fetchStorageToken(tenantId: String, documentId: String, refresh: Bool) async throws -> TokenResponse
}
public func encodeURIComponent(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")) ?? text
}

public enum R11sDocumentDeltaConnection {
    public static func message(document: String, token: String, client: JSONValue) throws -> JSONValue {
        var message = JSObject<JSONValue>()
        message["client"] = client; message["id"] = .string(JSString(document)); message["mode"] = try client.member("mode")
        message["tenantId"] = .string("tinylicious"); message["token"] = .string(JSString(token))
        message["versions"] = .array(["^0.4.0", "^0.3.0", "^0.2.0", "^0.1.0"].map { .string(JSString($0)) })
        let environment = try client.member("details").asObject()["environment"]?.asString().description ?? ""
        message["relayUserAgent"] = .string(JSString(environment + "; driverVersion:3.11.0"))
        return .object(message)
    }
}

public struct DocumentStorageService: Sendable {
    public let endpoint: String
    public let document: String
    public let tokens: any TokenProvider
    public init(endpoint: String, document: String, tokens: any TokenProvider) { self.endpoint = endpoint; self.document = document; self.tokens = tokens }
    public func get(_ path: String, storage: Bool = true) async throws -> JSONValue {
        guard let url = URL(string: endpoint + path) else { throw JSONDecodingError("invalid REST URL") }
        var request = URLRequest(url: url)
        let tokenResponse = try await storage
            ? tokens.fetchStorageToken(tenantId: "tinylicious", documentId: document, refresh: false)
            : tokens.fetchOrdererToken(tenantId: "tinylicious", documentId: document, refresh: false)
        let jwt = tokenResponse.jwt
        request.setValue(storage ? "Basic " + Data("tinylicious:\(jwt)".utf8).base64EncodedString() : "Basic " + jwt, forHTTPHeaderField: "Authorization")
        request.setValue("3.11.0", forHTTPHeaderField: "x-driver-version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw DriverError("REST \(path)", .string(JSString(String(decoding: data, as: UTF8.self)))) }
        return try JSON.parse(String(decoding: data, as: UTF8.self))
    }
    public func deltas(from: Int, to: Int, reason: String = "") async throws -> [JSONValue] {
        try await get("/deltas/tinylicious/\(encodeURIComponent(document))?from=\(from - 1)&to=\(to)&fetchReason=\(encodeURIComponent(reason))", storage: false).asArray()
    }
    /// Tinylicious 7 uses shredded git summaries (the 3.11 default driver policy).
    public func protocolSnapshot() async throws -> JSONValue {
        let commits = try await get("/repos/tinylicious/commits?count=1&sha=\(encodeURIComponent(document))").asArray()
        guard let latest = commits.first else { throw JSONDecodingError("no document version") }
        let treeID = try latest.member("commit").member("tree").member("sha").asString().description
        let tree = try await get("/repos/tinylicious/git/trees/\(encodeURIComponent(treeID))?recursive=1")
        let entries = try tree.member("tree").asArray()
        var result = JSObject<JSONValue>()
        for name in ["attributes", "quorumMembers", "quorumProposals", "quorumValues"] {
            guard let entry = try entries.first(where: { try $0.member("path").asString().description == ".protocol/" + name }) else { throw JSONDecodingError("missing protocol blob \(name)") }
            let id = try entry.member("sha").asString().description
            let blob = try await get("/repos/tinylicious/git/blobs/\(encodeURIComponent(id))")
            let content = try blob.member("content").asString().description
            let encoding = try blob.member("encoding").asString().description
            let text: String
            if encoding == "base64" {
                guard let data = Data(base64Encoded: content), let decoded = String(data: data, encoding: .utf8) else { throw JSONDecodingError("invalid base64 blob") }
                text = decoded
            } else { text = content }
            result[JSString(name)] = try JSON.parse(text)
        }
        return .object(result)
    }
}
