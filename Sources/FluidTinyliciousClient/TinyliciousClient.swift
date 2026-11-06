import FluidContainerDefinitions
import FluidContainerLoader
import FluidDriverDefinitions
import FluidJS
import FluidRouterliciousDriver
import FluidStatic
import FluidTinyliciousDriver

/// TinyliciousClient.ts `getLoaderProps` feature gates, through telemetry-utils
/// `wrapConfigProviderWithDefaults(undefined, featureGates)`: the T9s client requires a write
/// connection by default.
private struct TinyliciousConfigProvider: IConfigProviderBase {
    func getRawConfig(_ name: String) -> JSONValue? {
        name == "Fluid.Container.ForceWriteConnection" ? .bool(true) : nil
    }
}

/// Ports tinylicious-client/src/TinyliciousClient.ts `TinyliciousClient`: loads fluid-static
/// containers from a Tinylicious service. The client itself is immutable configuration; each
/// container it returns belongs to the actor passed as `isolation` (ARCHITECTURE.md section 2).
///
/// `createContainer` returns a detached container; `attach()` persists it.
public final class TinyliciousClient: Sendable {
    private let documentServiceFactory: RouterliciousDocumentServiceFactory
    private let urlResolver: InsecureTinyliciousUrlResolver

    /// TinyliciousClient.ts constructor: the driver's default policies, and the connection's
    /// token provider or else `InsecureTinyliciousTokenProvider`. The resolver gets the
    /// connection's port and the default endpoint (see `TinyliciousConnectionConfig.domain`).
    public init(properties: TinyliciousClientProps? = nil) throws {
        let connection = properties?.connection
        urlResolver = try InsecureTinyliciousUrlResolver(port: connection?.port)
        documentServiceFactory = RouterliciousDocumentServiceFactory(
            tokenProvider: connection?.tokenProvider ?? InsecureTinyliciousTokenProvider())
    }

    /// TinyliciousClient.ts createContainer: create locally, then let attach persist the graph.
    public func createContainer(
        _ containerSchema: ContainerSchema,
        oldestSupportedClient: String,
        isolation owner: isolated any Actor
    ) async throws -> (container: FluidContainer, services: TinyliciousContainerServices) {
        let props = try getLoaderProps(containerSchema, oldestSupportedClient: oldestSupportedClient, request: IRequest(url: ""))
        let container = try await createDetachedContainer(ICreateDetachedContainerProps(
            urlResolver: props.urlResolver, documentServiceFactory: props.documentServiceFactory,
            runtimeFactory: props.runtimeFactory,
            codeDetails: JSON.parse(#"{"package":"no-dynamic-package","config":{}}"#),
            configProvider: props.configProvider), isolation: owner)
        var headers = JSObject<JSONValue>()
        headers["createNew"] = .bool(true)
        let request = IRequest(url: "", headers: headers)
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

    /// TinyliciousClient.ts `getContainer`: loads the container `id`, owned by `owner`.
    /// `oldestSupportedClient` is the oldest Fluid Framework client version that must be able to
    /// open and process documents this client writes (TS `OldestSupportedClientVersion`).
    public func getContainer(
        _ id: String,
        containerSchema: ContainerSchema,
        oldestSupportedClient: String,
        isolation owner: isolated any Actor
    ) async throws -> (container: FluidContainer, services: TinyliciousContainerServices) {
        let loaderProps = try getLoaderProps(containerSchema, oldestSupportedClient: oldestSupportedClient, request: IRequest(url: id))
        let container = try await loadExistingContainer(loaderProps, isolation: owner)
        let fluidContainer = try await createFluidContainer(container: container)
        let services = try getContainerServices(container)
        return (fluidContainer, services)
    }

    /// TinyliciousClient.ts `getContainerServices`.
    private func getContainerServices(_ container: any IContainer) throws -> TinyliciousContainerServices {
        TinyliciousContainerServices(
            audience: try createServiceAudience(container: container, createServiceMember: createTinyliciousAudienceMember))
    }

    /// TinyliciousClient.ts `getLoaderProps`. The interactive write client TS passes as
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
            configProvider: TinyliciousConfigProvider())
    }
}
