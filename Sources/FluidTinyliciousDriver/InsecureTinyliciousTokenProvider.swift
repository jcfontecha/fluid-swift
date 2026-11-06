import CryptoKit
import FluidDriverDefinitions
import FluidJS
import FluidRouterliciousDriver
import Foundation

/// Ports tinylicious-driver/src/insecureTinyliciousTokenProvider.ts.
public struct InsecureTinyliciousTokenProvider: ITokenProvider {
    public init() {}
    public func fetchOrdererToken(
        tenantId: String, documentId: String? = nil, refresh: Bool = false
    )
        async throws -> ITokenResponse
    {
        ITokenResponse(
            jwt: try signedToken(
                tenant: tenantId, document: documentId ?? "",
                userID: UUID().uuidString.lowercased(),
                now: Int(Date().timeIntervalSince1970.rounded())), fromCache: true)
    }
    public func fetchStorageToken(tenantId: String, documentId: String, refresh: Bool = false)
        async throws -> ITokenResponse
    {
        try await fetchOrdererToken(tenantId: tenantId, documentId: documentId, refresh: refresh)
    }
    public func signedToken(tenant: String, document: String, userID: String, now: Int) throws
        -> String
    {
        var user = JSObject<JSONValue>()
        user["id"] = .string(JSString(userID))
        user["name"] = .string(JSString(String(userID.prefix(13))))
        var claims = JSObject<JSONValue>()
        claims["documentId"] = .string(JSString(document))
        claims["scopes"] = .array([
            .string("doc:read"), .string("doc:write"), .string("summary:write"),
        ])
        claims["tenantId"] = .string(JSString(tenant))
        claims["user"] = .object(user)
        claims["iat"] = .number(Double(now))
        claims["exp"] = .number(Double(now + 3600))
        claims["ver"] = .string("1.0")
        let body =
            Self.base64(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8)) + "."
            + Self.base64(Data(JSON.stringify(try ITokenClaims(json: .object(claims)).json).utf8))
        return body + "."
            + Self.base64(
                Data(
                    HMAC<SHA256>.authenticationCode(
                        for: Data(body.utf8), using: SymmetricKey(data: Data("12345".utf8)))))
    }
    private static func base64(_ value: Data) -> String {
        value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
            of: "/", with: "_"
        ).replacingOccurrences(of: "=", with: "")
    }
}
