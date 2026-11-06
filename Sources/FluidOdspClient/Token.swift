/// Ports odsp-client/src/token.ts `IOdspTokenProvider`. The host app supplies tokens for the
/// SharePoint site: storage tokens for REST calls, websocket tokens for the delta stream.
public protocol IOdspTokenProvider: Sendable {
    func fetchWebsocketToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse

    func fetchStorageToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse
}
