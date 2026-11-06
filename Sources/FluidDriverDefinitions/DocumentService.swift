import FluidJS

/// Ports core-interfaces IRequest as used by driver-definitions/src/urlResolver.ts.
public struct IRequest: Sendable {
    public let url: String
    public let headers: JSObject<JSONValue>?

    public init(url: String, headers: JSObject<JSONValue>? = nil) {
        self.url = url
        self.headers = headers
    }
}

/// Ports driver-definitions/src/urlResolver.ts IUrlResolver. `nil` means unresolved.
public protocol IUrlResolver: Sendable {
    func resolve(_ request: IRequest) async throws -> IResolvedUrl?
    func getAbsoluteUrl(_ resolvedUrl: IResolvedUrl, relativeUrl: String) async throws -> String
}

/// Ports driver-definitions/src/storage.ts IDocumentServiceFactory.
public protocol IDocumentServiceFactory: Sendable {
    func createDocumentService(_ resolvedUrl: IResolvedUrl, clientIsSummarizer: Bool) async throws
        -> any IDocumentService
    func createContainer(_ createNewSummary: SummaryTree?, resolvedUrl: IResolvedUrl, clientIsSummarizer: Bool)
        async throws -> any IDocumentService
}

/// Ports driver-definitions/src/storage.ts IDocumentServicePolicies. Absent means false.
public struct IDocumentServicePolicies: Sendable {
    public let storageOnly: Bool?
    public let summarizeProtocolTree: Bool?
    public let supportGetSnapshotApi: Bool?

    public init(storageOnly: Bool? = nil, summarizeProtocolTree: Bool? = nil, supportGetSnapshotApi: Bool? = nil) {
        self.storageOnly = storageOnly
        self.summarizeProtocolTree = summarizeProtocolTree
        self.supportGetSnapshotApi = supportGetSnapshotApi
    }
}

/// Ports driver-definitions/src/storage.ts IDocumentService. Disposal does not close delta
/// connections: the caller owns and closes those.
public protocol IDocumentService: AnyObject, Sendable {
    var resolvedUrl: IResolvedUrl { get }
    var policies: IDocumentServicePolicies? { get }
    func connectToStorage() async throws -> any IDocumentStorageService
    func connectToDeltaStorage() async throws -> any IDocumentDeltaStorageService
    func connectToDeltaStream(_ client: IClient) async throws -> any IDocumentDeltaConnection
    func dispose(_ error: (any Error)?)
}

/// Ports driver-definitions/src/storage.ts IDocumentStorageService.
/// `getSnapshot` is optional in TS; a driver without it throws and leaves
/// `IDocumentServicePolicies.supportGetSnapshotApi` unset.
public protocol IDocumentStorageService: AnyObject, Sendable {
    func getSnapshotTree(_ version: IVersion?, scenarioName: String?) async throws -> ISnapshotTree?
    func getSnapshot(_ options: ISnapshotFetchOptions?) async throws -> ISnapshot
    func getVersions(_ versionId: JSString?, count: Int, scenarioName: String?, fetchSource: FetchSource?)
        async throws -> [IVersion]
    func createBlob(_ file: [UInt8]) async throws -> ICreateBlobResponse
    func readBlob(_ id: JSString) async throws -> [UInt8]
    func uploadSummaryWithContext(_ summary: SummaryTree, context: ISummaryContext) async throws -> JSString
    func downloadSummary(_ handle: ISummaryHandle) async throws -> SummaryTree
}

/// Ports driver-definitions/src/storage.ts IDocumentDeltaStorageService. The stream is returned
/// synchronously; the range is [from, to), and `to == nil` is open-ended.
public protocol IDocumentDeltaStorageService: AnyObject, Sendable {
    func fetchMessages(_ from: Int, to: Int?, cachedOnly: Bool, fetchReason: String?)
        -> AsyncThrowingStream<[ISequencedDocumentMessage], any Error>
}

/// Ports driver-definitions/src/storage.ts IDocumentDeltaConnectionEvents.
public enum DocumentDeltaConnectionEvent: Sendable {
    case op(documentId: JSString, messages: [ISequencedDocumentMessage])
    case signal([ISignalMessage])
    case nack(documentId: JSString, nacks: [INack])
    case disconnect(reason: any Error & Sendable)
    case pong(latency: Double)
}

/// Ports driver-definitions/src/storage.ts IDocumentDeltaConnection. `details` is the
/// connect_document_success payload (clientId, existing, mode, claims, initialMessages,
/// initialSignals, initialClients, serviceConfiguration, version, checkpointSequenceNumber).
/// `events` buffers from handshake until the consumer drains it, then finishes after `disconnect`.
public protocol IDocumentDeltaConnection: AnyObject, Sendable {
    var details: IConnected { get }
    var events: AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error> { get }
    /// TS `submit(messages): void`: a synchronous FIFO enqueue onto the connection's one ordered
    /// writer, so ops reach the socket in call order. A disposed connection drops them.
    func submit(_ messages: [IDocumentMessage])
    /// TS `submitSignal(content, targetClientId?): void`, on the same writer as `submit`. Throws
    /// where TS throws a UsageError: a targeted signal on a service without signals v2.
    func submitSignal(_ content: String, targetClientId: String?) throws
    func dispose() async
}
