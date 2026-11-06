public import Foundation
internal import FluidOdspClient

/// An access token from the app's sign-in.
public struct TokenResponse: Sendable {
    public let token: String
    /// Whether the token came from a cache; nil when the provider does not know.
    public let fromCache: Bool?

    public init(token: String, fromCache: Bool? = nil) {
        self.token = token
        self.fromCache = fromCache
    }
}

/// Supplies SharePoint tokens: storage tokens for REST calls and websocket tokens for the push
/// channel. `refresh` asks for a new token instead of a cached one.
public protocol OdspTokenProvider: Sendable {
    func fetchStorageToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse
    func fetchWebsocketToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse
}

/// Loads containers stored as files in a SharePoint Embedded drive.
public struct OdspClient: Sendable {
    private let port: FluidOdspClient.OdspClient

    public init(siteURL: URL, driveID: String, tokenProvider: any OdspTokenProvider) {
        port = FluidOdspClient.OdspClient(properties: OdspClientProps(connection: OdspConnectionConfig(
            tokenProvider: OdspPortTokenProvider(provider: tokenProvider),
            siteUrl: siteURL.absoluteString,
            driveId: driveID,
            filePath: "")))
    }

    /// Loads the file `itemID`. The container and its objects belong to `owner`: an app passes
    /// `MainActor.shared` and uses them from main-actor code.
    public func loadContainer<Schema: ContainerSchema>(
        _ itemID: String, schema: Schema.Type, isolation owner: isolated any Actor
    ) async throws -> FluidContainer<Schema> {
        let (container, _) = try await port.getContainer(
            itemID, containerSchema: InitialObjects.schema(of: schema), isolation: owner)
        return try FluidContainer(port: container)
    }
}

private struct OdspPortTokenProvider: IOdspTokenProvider {
    let provider: any OdspTokenProvider

    func fetchStorageToken(siteUrl: String, refresh: Bool) async throws -> FluidOdspClient.TokenResponse {
        let response = try await provider.fetchStorageToken(siteUrl: siteUrl, refresh: refresh)
        return FluidOdspClient.TokenResponse(token: response.token, fromCache: response.fromCache)
    }

    func fetchWebsocketToken(siteUrl: String, refresh: Bool) async throws -> FluidOdspClient.TokenResponse {
        let response = try await provider.fetchWebsocketToken(siteUrl: siteUrl, refresh: refresh)
        return FluidOdspClient.TokenResponse(token: response.token, fromCache: response.fromCache)
    }
}
