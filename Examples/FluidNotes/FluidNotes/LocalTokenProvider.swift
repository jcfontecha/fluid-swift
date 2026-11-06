import FluidOdspClient

/// `IOdspTokenProvider` for the local ODSP service, whose fake bearer tokens name a user:
/// `storage:<user>` for SharePoint REST calls and `push:<user>` for the push socket (tokens.ts).
struct LocalTokenProvider: IOdspTokenProvider {
    let user: String

    func fetchStorageToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
        TokenResponse(token: "storage:\(user)", fromCache: false)
    }

    func fetchWebsocketToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
        TokenResponse(token: "push:\(user)", fromCache: false)
    }
}
