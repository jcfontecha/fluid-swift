import FluidContainerDefinitions
import FluidContainerRuntime
import FluidDriverDefinitions
import FluidJS

/// Ports container-definitions loader.ts LoaderHeader: the request headers the loader reads.
public enum LoaderHeader {
    public static let clientDetails: JSString = "fluid-client-details"
    public static let version: JSString = "version"
}

/// Ports createAndLoadContainerUtils.ts ILoadExistingContainerProps (IContainerHostProps and
/// IContainerDriverServices plus the request). `runtimeFactory` takes the place of TS's code
/// loader, which only resolves to a runtime factory. `summaryMode` is the runtime's
/// ISummaryConfiguration state, read here because the Swift summarizer lives in the loader.
/// `loadRuntime: false` loads protocol state only, for the protocol harness.
public struct ILoadExistingContainerProps: Sendable {
    public let request: IRequest
    public let urlResolver: any IUrlResolver
    public let documentServiceFactory: any IDocumentServiceFactory
    public let runtimeFactory: any IRuntimeFactory<ContainerRuntime>
    public let configProvider: (any IConfigProviderBase)?
    public let summaryMode: SummaryManager.Mode
    public let loadRuntime: Bool

    public init(
        request: IRequest, urlResolver: any IUrlResolver, documentServiceFactory: any IDocumentServiceFactory,
        runtimeFactory: any IRuntimeFactory<ContainerRuntime>, configProvider: (any IConfigProviderBase)? = nil,
        summaryMode: SummaryManager.Mode = .enabled, loadRuntime: Bool = true
    ) {
        self.request = request
        self.urlResolver = urlResolver
        self.documentServiceFactory = documentServiceFactory
        self.runtimeFactory = runtimeFactory
        self.configProvider = configProvider
        self.summaryMode = summaryMode
        self.loadRuntime = loadRuntime
    }
}

/// Ports createAndLoadContainerUtils.ts `loadExistingContainer` through loader.ts `resolve`:
/// resolve the request, take the version from the URL's query or the request header, then load
/// and connect the container. Fails when the resolver does not resolve the request or the resolved
/// URL is not `protocol://host/tenant/document...`.
///
/// `owner` is the actor the container belongs to (ARCHITECTURE.md section 2): `MainActor.shared`
/// in an app, a private actor for headless clients. Loading runs off the owner; the owner then
/// adopts the container, and only code isolated to it can use the result.
public func loadExistingContainer(
    _ props: ILoadExistingContainerProps, isolation owner: isolated any Actor
) async throws -> Container {
    let container = try await prepareContainer(props)
    container.start(on: owner)
    return container
}

/// The off-owner half of `loadExistingContainer`: resolve, load the snapshot, connect and apply
/// what storage has after it, on the cooperative pool. The graph is one disconnected region, so it
/// goes to the owner as `sending`. Socket ops that arrive meanwhile wait in its job queue.
@concurrent
func prepareContainer(_ props: ILoadExistingContainerProps) async throws -> sending Container {
    guard let resolvedUrl = try await props.urlResolver.resolve(props.request) else {
        throw JSONDecodingError("Object is not a IResolveUrl.")
    }
    guard let parsed = tryParseCompatibleResolvedUrl(resolvedUrl.url.description) else {
        throw JSONDecodingError("Invalid URL \(resolvedUrl.url)")
    }
    let headers = props.request.headers
    // If set in both query string and headers, the query string wins.
    let version = try parsed.version.map { JSString($0) } ?? headers?[LoaderHeader.version].flatMap { value in
        value == .null ? nil : try value.asString()
    }
    let container = try Container(
        resolvedUrl: resolvedUrl, urlResolver: props.urlResolver, documentServiceFactory: props.documentServiceFactory,
        runtimeFactory: props.runtimeFactory, configProvider: props.configProvider, specifiedVersion: version,
        clientDetailsOverride: headers?[LoaderHeader.clientDetails], loadRuntime: props.loadRuntime,
        summaryMode: props.summaryMode)
    do {
        try await container.open()
    } catch {
        // A failed load closes the connection and the service it opened.
        container.dispose(error)
        throw error
    }
    return container
}

/// createAndLoadContainerUtils.ts ICreateDetachedContainerProps. Code details seed the quorum.
public struct ICreateDetachedContainerProps: Sendable {
    public let urlResolver: any IUrlResolver
    public let documentServiceFactory: any IDocumentServiceFactory
    public let runtimeFactory: any IRuntimeFactory<ContainerRuntime>
    public let codeDetails: JSONValue
    public let configProvider: (any IConfigProviderBase)?
    public let summaryMode: SummaryManager.Mode

    public init(urlResolver: any IUrlResolver, documentServiceFactory: any IDocumentServiceFactory,
        runtimeFactory: any IRuntimeFactory<ContainerRuntime>, codeDetails: JSONValue,
        configProvider: (any IConfigProviderBase)? = nil, summaryMode: SummaryManager.Mode = .enabled) {
        self.urlResolver = urlResolver
        self.documentServiceFactory = documentServiceFactory
        self.runtimeFactory = runtimeFactory
        self.codeDetails = codeDetails
        self.configProvider = configProvider
        self.summaryMode = summaryMode
    }
}

public func createDetachedContainer(_ props: ICreateDetachedContainerProps, isolation owner: isolated any Actor) async throws -> Container {
    let container = try await prepareDetachedContainer(props)
    container.start(on: owner)
    return container
}

@concurrent
private func prepareDetachedContainer(_ props: ICreateDetachedContainerProps) async throws -> sending Container {
    let container = try Container(resolvedUrl: nil, urlResolver: props.urlResolver,
        documentServiceFactory: props.documentServiceFactory, runtimeFactory: props.runtimeFactory,
        configProvider: props.configProvider, specifiedVersion: nil, clientDetailsOverride: nil,
        loadRuntime: true, summaryMode: props.summaryMode)
    try container.createDetached(codeDetails: props.codeDetails)
    return container
}
