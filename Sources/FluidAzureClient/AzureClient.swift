import FluidContainerDefinitions
import FluidContainerLoader
import FluidDriverDefinitions
import FluidJS
import FluidRouterliciousDriver
import FluidStatic

/// AzureClient.ts `LOCAL_MODE_TENANT_ID`: the tenant of a local Azure Fluid Relay.
private let localModeTenantId = "local"

/// AzureClient.ts `MAX_VERSION_COUNT`: versions `getContainerVersions` returns by default.
private let maxVersionCount = 5

/// AzureClient.ts `getTenantId`.
private func getTenantId(_ connectionProperties: AzureConnectionConfig) -> String {
    switch connectionProperties {
    case .remote(let config):
        config.tenantId
    case .local:
        localModeTenantId
    }
}

/// telemetry-utils config.ts `wrapConfigProviderWithDefaults`: the base provider's value, or the
/// default when it is undefined or null (`??`).
private struct ConfigProviderWithDefaults: IConfigProviderBase {
    let original: (any IConfigProviderBase)?
    let defaults: [String: JSONValue]

    func getRawConfig(_ name: String) -> JSONValue? {
        if let value = original?.getRawConfig(name), value != .null {
            return value
        }
        return defaults[name]
    }
}

/// AzureClient.ts `azureClientFeatureGates`: used only where the supplied config provider does
/// not set the gate. Azure client requires a write connection by default.
private let azureClientFeatureGates: [String: JSONValue] = [
    "Fluid.Container.ForceWriteConnection": .bool(true)
]

/// Ports azure-client/src/AzureClient.ts `AzureClient`: loads fluid-static containers from the
/// Azure Fluid Relay or, in local mode, from a local relay (tinylicious). The client itself is
/// immutable configuration; each container it returns belongs to the actor passed as
/// `isolation` (ARCHITECTURE.md section 2).
///
/// Not ported: `createContainer` (the loader cannot create a detached container yet) and
/// `viewContainerVersion` (the loader has no `loadContainerPaused`).
public final class AzureClient: Sendable {
    private let documentServiceFactory: RouterliciousDocumentServiceFactory
    private let urlResolver: AzureUrlResolver
    private let configProvider: any IConfigProviderBase
    /// The connection's endpoint without its trailing slash.
    private let endpoint: String
    private let tenantId: String

    /// AzureClient.ts constructor. The local service differs from the Azure Fluid Relay in blob
    /// storage format: only the relay supports whole-summary upload and discovery, so both
    /// driver policies are on exactly for a remote connection.
    public init(properties: AzureClientProps) {
        let connection = properties.connection
        // Remove the trailing slash from the URL, if any (TS `replace(/\/$/, "")`).
        endpoint = connection.endpoint.hasSuffix("/") ? String(connection.endpoint.dropLast()) : connection.endpoint
        tenantId = getTenantId(connection)
        urlResolver = AzureUrlResolver()
        let isRemoteConnection = connection.type == .remote
        documentServiceFactory = RouterliciousDocumentServiceFactory(
            tokenProvider: connection.tokenProvider,
            driverPolicies: IRouterliciousDriverPolicies(
                enableDiscovery: isRemoteConnection,
                enableWholeSummaryUpload: isRemoteConnection))
        configProvider = ConfigProviderWithDefaults(original: properties.configProvider, defaults: azureClientFeatureGates)
    }

    /// AzureClient.ts createContainer: create locally, then let attach persist the graph.
    public func createContainer(
        _ containerSchema: ContainerSchema,
        oldestSupportedClient: String,
        isolation owner: isolated any Actor
    ) async throws -> (container: FluidContainer, services: AzureContainerServices) {
        let props = try getLoaderProps(containerSchema, oldestSupportedClient: oldestSupportedClient, request: IRequest(url: ""))
        let container = try await createDetachedContainer(ICreateDetachedContainerProps(
            urlResolver: props.urlResolver, documentServiceFactory: props.documentServiceFactory,
            runtimeFactory: props.runtimeFactory,
            codeDetails: JSON.parse(#"{"package":"no-dynamic-package","config":{}}"#),
            configProvider: props.configProvider), isolation: owner)
        let request = try createAzureCreateNewRequest(endpointUrl: endpoint, tenantId: tenantId)
        let fluidContainer = try await createFluidContainer(container: container, attach: {
            _ = owner
            try await container.attach(request)
            guard let resolved = container.resolvedUrl else {
                throw JSONDecodingError("Resolved Url not available on attached container")
            }
            return resolved.id.description
        })
        return (fluidContainer, try getContainerServices(container))
    }

    /// AzureClient.ts `getContainer`: loads the container `id`, owned by `owner`.
    /// `oldestSupportedClient` is the oldest Fluid Framework client version that must be able to
    /// open and process documents this client writes (TS `OldestSupportedClientVersion`).
    public func getContainer(
        _ id: String,
        containerSchema: ContainerSchema,
        oldestSupportedClient: String,
        isolation owner: isolated any Actor
    ) async throws -> (container: FluidContainer, services: AzureContainerServices) {
        let url = try createAzureRequestUrl(endpoint: endpoint, tenantId: tenantId, containerId: id)
        let loaderProps = try getLoaderProps(containerSchema, oldestSupportedClient: oldestSupportedClient, request: IRequest(url: url))
        let container = try await loadExistingContainer(loaderProps, isolation: owner)
        let fluidContainer = try await createFluidContainer(container: container)
        let services = try getContainerServices(container)
        return (fluidContainer, services)
    }

    /// AzureClient.ts `getContainerVersions`: up to `options.maxCount` (default 5) versions of
    /// the container `id`, from storage.
    public func getContainerVersions(_ id: String, options: AzureGetVersionsOptions? = nil) async throws
        -> [AzureContainerVersion]
    {
        let url = try createAzureRequestUrl(endpoint: endpoint, tenantId: tenantId, containerId: id)
        guard let resolvedUrl = try await urlResolver.resolve(IRequest(url: url)) else {
            throw JSONDecodingError("Unable to resolved URL")
        }
        let documentService = try await documentServiceFactory.createDocumentService(resolvedUrl, clientIsSummarizer: false)
        let storage = try await documentService.connectToStorage()
        let versions = try await storage.getVersions(
            nil,
            count: options?.maxCount ?? maxVersionCount,
            scenarioName: nil,
            fetchSource: nil)
        return versions.map { item in
            AzureContainerVersion(id: item.id.description, date: item.date?.description)
        }
    }

    /// AzureClient.ts `getContainerServices`.
    private func getContainerServices(_ container: any IContainer) throws -> AzureContainerServices {
        AzureContainerServices(
            audience: try createServiceAudience(container: container, createServiceMember: createAzureAudienceMember))
    }

    /// AzureClient.ts `getLoaderProps`. The interactive write client TS passes as
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
            runtimeFactory: runtimeFactory,
            configProvider: configProvider)
    }
}
