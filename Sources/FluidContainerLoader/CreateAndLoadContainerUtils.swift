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
public func loadExistingContainer(_ props: ILoadExistingContainerProps) async throws -> Container {
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
    try await container.connect()
    return container
}
