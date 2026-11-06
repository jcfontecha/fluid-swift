import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Foundation

/// Ports routerlicious-driver/src/tokens.ts: ITokenResponse.
public struct ITokenResponse: Sendable {
    public let jwt: String
    public let fromCache: Bool
    public init(jwt: String, fromCache: Bool) {
        self.jwt = jwt
        self.fromCache = fromCache
    }
}
/// Ports routerlicious-driver/src/tokens.ts: ITokenProvider.
public protocol ITokenProvider: Sendable {
    var documentPostCreateCallback: (@Sendable (String, String) async throws -> Void)? { get }
    func fetchOrdererToken(tenantId: String, documentId: String?, refresh: Bool) async throws
        -> ITokenResponse
    func fetchStorageToken(tenantId: String, documentId: String, refresh: Bool) async throws
        -> ITokenResponse
}
public func encodeURIComponent(_ text: String) -> String {
    text.addingPercentEncoding(
        withAllowedCharacters: CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    )
        ?? text
}

extension ITokenProvider {
    public var documentPostCreateCallback: (@Sendable (String, String) async throws -> Void)? { nil }
}
