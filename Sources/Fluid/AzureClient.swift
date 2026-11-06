public import Foundation
internal import FluidAzureClient
internal import FluidRouterliciousDriver

/// Supplies Azure Fluid Relay tokens for one tenant: orderer tokens for the delta stream and
/// storage tokens for summaries and blobs. `documentID` is nil only when creating a container.
public protocol AzureTokenProvider: Sendable {
    func fetchOrdererToken(tenantID: String, documentID: String?, refresh: Bool) async throws -> TokenResponse
    func fetchStorageToken(tenantID: String, documentID: String, refresh: Bool) async throws -> TokenResponse
}

/// Loads containers from the Azure Fluid Relay, or from a local relay (tinylicious) in local mode.
public struct AzureClient: Sendable {
    private let port: FluidAzureClient.AzureClient

    /// A connection to the Azure Fluid Relay service at `endpoint`, for `tenantID`.
    public init(endpoint: URL, tenantID: String, tokenProvider: any AzureTokenProvider) {
        port = FluidAzureClient.AzureClient(properties: AzureClientProps(connection: .remote(AzureRemoteConnectionConfig(
            endpoint: endpoint.absoluteString,
            tokenProvider: AzurePortTokenProvider(provider: tokenProvider),
            tenantId: tenantID))))
    }

    /// A connection to a local relay at `localEndpoint`.
    public init(localEndpoint: URL, tokenProvider: any AzureTokenProvider) {
        port = FluidAzureClient.AzureClient(properties: AzureClientProps(connection: .local(AzureLocalConnectionConfig(
            endpoint: localEndpoint.absoluteString,
            tokenProvider: AzurePortTokenProvider(provider: tokenProvider)))))
    }

    /// Loads the container `id`. The container and its objects belong to `owner`. Documents this
    /// client writes stay readable by Fluid Framework 2.0 clients and later.
    public func loadContainer<Schema: ContainerSchema>(
        _ id: String, schema: Schema.Type, isolation owner: isolated any Actor
    ) async throws -> FluidContainer<Schema> {
        let (container, _) = try await port.getContainer(
            id, containerSchema: InitialObjects.schema(of: schema), oldestSupportedClient: "2.0.0", isolation: owner)
        return try FluidContainer(port: container)
    }
}

/// routerlicious-driver's token response has a non-optional `fromCache`; an unknown one is false.
private struct AzurePortTokenProvider: ITokenProvider {
    let provider: any AzureTokenProvider

    func fetchOrdererToken(tenantId: String, documentId: String?, refresh: Bool) async throws -> ITokenResponse {
        let response = try await provider.fetchOrdererToken(tenantID: tenantId, documentID: documentId, refresh: refresh)
        return ITokenResponse(jwt: response.token, fromCache: response.fromCache ?? false)
    }

    func fetchStorageToken(tenantId: String, documentId: String, refresh: Bool) async throws -> ITokenResponse {
        let response = try await provider.fetchStorageToken(tenantID: tenantId, documentID: documentId, refresh: refresh)
        return ITokenResponse(jwt: response.token, fromCache: response.fromCache ?? false)
    }
}
