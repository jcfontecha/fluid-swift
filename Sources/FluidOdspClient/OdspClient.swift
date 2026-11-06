import Foundation
import FluidJS
import FluidContainerLoader
import FluidDriverDefinitions
import FluidOdspDriver
import FluidStatic

/// odspClient.ts `getStorageToken`: the host's storage token, as a driver token response.
private func getStorageToken(
    _ options: TokenFetchOptions,
    _ tokenProvider: any IOdspTokenProvider
) async throws -> FluidOdspDriver.TokenResponse {
    let tokenResponse = try await tokenProvider.fetchStorageToken(siteUrl: options.siteUrl, refresh: options.refresh)
    return .response(token: tokenResponse.token, fromCache: tokenResponse.fromCache)
}

/// odspClient.ts `getWebsocketToken`: the host's push token, as a driver token response.
private func getWebsocketToken(
    _ options: TokenFetchOptions,
    _ tokenProvider: any IOdspTokenProvider
) async throws -> FluidOdspDriver.TokenResponse {
    let tokenResponse = try await tokenProvider.fetchWebsocketToken(siteUrl: options.siteUrl, refresh: options.refresh)
    return .response(token: tokenResponse.token, fromCache: tokenResponse.fromCache)
}

/// Ports odsp-client/src/odspClient.ts `OdspClient`: loads fluid-static containers from
/// SharePoint Embedded through the ODSP driver. The client itself is immutable configuration;
/// each container it returns belongs to the actor passed as `isolation` (ARCHITECTURE.md
/// section 2).
///
/// `createContainer` returns a detached container; `attach()` persists it.
public final class OdspClient: Sendable {
    private let documentServiceFactory: OdspDocumentServiceFactory
    private let urlResolver: OdspDriverUrlResolver
    private let connectionConfig: OdspConnectionConfig

    public init(properties: OdspClientProps) {
        let connectionConfig = properties.connection
        self.connectionConfig = connectionConfig
        documentServiceFactory = OdspDocumentServiceFactory(
            getStorageToken: { options in
                try await getStorageToken(options, connectionConfig.tokenProvider)
            },
            getWebsocketToken: { options in
                try await getWebsocketToken(options, connectionConfig.tokenProvider)
            })
        urlResolver = OdspDriverUrlResolver()
    }

    /// OdspClient.ts createContainer: create locally, then let attach persist the graph.
    public func createContainer(
        _ containerSchema: ContainerSchema,
        isolation owner: isolated any Actor
    ) async throws -> (container: FluidContainer, services: OdspContainerServices) {
        let props = try getLoaderProps(containerSchema, oldestSupportedClient: "2.0.0", request: IRequest(url: ""))
        let container = try await createDetachedContainer(ICreateDetachedContainerProps(
            urlResolver: props.urlResolver, documentServiceFactory: props.documentServiceFactory,
            runtimeFactory: props.runtimeFactory,
            codeDetails: JSON.parse(#"{"package":"no-dynamic-package","config":{}}"#),
            configProvider: props.configProvider), isolation: owner)
        let request = createOdspCreateContainerRequest(siteUrl: connectionConfig.siteUrl, driveId: connectionConfig.driveId, filePath: connectionConfig.filePath, fileName: UUID().uuidString.lowercased())
        let fluidContainer = try await createFluidContainer(container: container, attach: {
            _ = owner
            try await container.attach(request)
            guard let resolved = container.resolvedUrl else {
                throw JSONDecodingError("Resolved Url not available on attached container")
            }
            return try IOdspResolvedUrl(json: resolved.json).itemId
        })
        return (fluidContainer, try OdspContainerServices(container: container))
    }

    /// odspClient.ts `getContainer`: loads the file `id` in the configured drive, owned by
    /// `owner`. `oldestSupportedClient` is TS's default, "2.0.0".
    public func getContainer(
        _ id: String,
        containerSchema: ContainerSchema,
        isolation owner: isolated any Actor
    ) async throws -> (container: FluidContainer, services: OdspContainerServices) {
        let url = createOdspUrl(
            siteUrl: connectionConfig.siteUrl,
            driveId: connectionConfig.driveId,
            itemId: id,
            dataStorePath: "")
        let loaderProps = try getLoaderProps(containerSchema, oldestSupportedClient: "2.0.0", request: IRequest(url: url))
        let container = try await loadExistingContainer(loaderProps, isolation: owner)
        let fluidContainer = try await createFluidContainer(container: container)
        let services = try OdspContainerServices(container: container)
        return (fluidContainer, services)
    }

    /// odspClient.ts `getLoaderProps`. The interactive write client TS passes as
    /// `options.client` is the loader's default client.
    private func getLoaderProps(
        _ schema: ContainerSchema,
        oldestSupportedClient: String,
        request: IRequest
    ) throws -> ILoadExistingContainerProps {
        let runtimeFactory = try createDOProviderContainerRuntimeFactory(
            schema: schema,
            oldestSupportedClient: oldestSupportedClient)
        return ILoadExistingContainerProps(
            request: request,
            urlResolver: urlResolver,
            documentServiceFactory: documentServiceFactory,
            runtimeFactory: runtimeFactory)
    }
}
