import Foundation
import CryptoKit
import FluidJS
import FluidRouterliciousDriver

public struct InsecureTinyliciousTokenProvider: TokenProvider {
    public init() {}
    public func fetchOrdererToken(tenantId: String, documentId: String? = nil, refresh: Bool = false) async throws -> TokenResponse {
        TokenResponse(jwt: signedToken(tenant: tenantId, document: documentId ?? "", userID: UUID().uuidString.lowercased(), now: Int(Date().timeIntervalSince1970.rounded())), fromCache: true)
    }
    public func fetchStorageToken(tenantId: String, documentId: String, refresh: Bool = false) async throws -> TokenResponse {
        try await fetchOrdererToken(tenantId: tenantId, documentId: documentId, refresh: refresh)
    }
    public func signedToken(tenant: String, document: String, userID: String, now: Int) -> String {
        var user = JSObject<JSONValue>(); user["id"] = .string(JSString(userID)); user["name"] = .string(JSString(String(userID.prefix(13))))
        var claims = JSObject<JSONValue>()
        claims["documentId"] = .string(JSString(document))
        claims["scopes"] = .array([.string("doc:read"), .string("doc:write"), .string("summary:write")])
        claims["tenantId"] = .string(JSString(tenant)); claims["user"] = .object(user)
        claims["iat"] = .number(Double(now)); claims["exp"] = .number(Double(now + 3600)); claims["ver"] = .string("1.0")
        let body = Self.base64(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8)) + "." + Self.base64(Data(JSON.stringify(.object(claims)).utf8))
        return body + "." + Self.base64(Data(HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: SymmetricKey(data: Data("12345".utf8)))))
    }
    private static func base64(_ value: Data) -> String { value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

public struct InsecureTinyliciousURLResolver: Sendable {
    public let endpoint: String
    public init(port: Int? = nil, endpoint: String = "http://localhost") throws {
        guard var url = URLComponents(string: endpoint), let scheme = url.scheme, let host = url.host else { throw JSONDecodingError("invalid Tinylicious endpoint") }
        if let port { url.port = port } else if url.port == nil { url.port = 7070 }
        let effectivePort = url.port
        let suffix = effectivePort.map { ($0 == 80 && scheme == "http") || ($0 == 443 && scheme == "https") ? "" : ":\($0)" } ?? ""
        self.endpoint = "\(scheme)://\(host)\(suffix)"
    }
    public func resolve(_ request: String, createNew: Bool = false) throws -> JSONValue {
        let relative = request.replacingOccurrences(of: endpoint + "/", with: "", options: [], range: request.range(of: endpoint + "/"))
        let first = String(relative.split(separator: "/", omittingEmptySubsequences: false).first ?? "")
        let id = createNew ? (first.isEmpty ? "new" : first) : first
        let encoded = encodeURIComponent(id)
        var endpoints = JSObject<JSONValue>()
        endpoints["deltaStorageUrl"] = .string(JSString("\(endpoint)/deltas/tinylicious/\(createNew ? id : encoded)"))
        endpoints["ordererUrl"] = .string(JSString(endpoint)); endpoints["storageUrl"] = .string(JSString("\(endpoint)/repos/tinylicious"))
        var result = JSObject<JSONValue>(); result["endpoints"] = .object(endpoints); result["id"] = .string(JSString(id)); result["tokens"] = .object(.init()); result["type"] = .string("fluid")
        result["url"] = .string(JSString("\(endpoint)/tinylicious/\(createNew ? id : encoded + relative.dropFirst(first.count))"))
        return .object(result)
    }
    public func getAbsoluteURL(_ resolved: JSONValue, relative: String) throws -> String {
        let url = try resolved.member("url").asString().description
        let path = url.replacingOccurrences(of: endpoint + "/tinylicious/", with: "")
        guard let document = path.removingPercentEncoding else { throw JSONDecodingError("invalid URI encoding") }
        return document + "/" + relative
    }

}
