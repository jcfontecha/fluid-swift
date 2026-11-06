import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Synchronization

/// Ports routerlicious-driver/src/documentService.ts. Disposal does nothing, as in TS.
public final class DocumentService: IDocumentService {
    public var resolvedUrl: IResolvedUrl { endpoints.withLock { $0 } }
    private let endpoints: Mutex<IResolvedUrl>
    public let tenantId: String
    public let documentId: String
    private var ordererUrl: String { resolvedUrl.endpoints["ordererUrl"]!.description }
    private var deltaStorageUrl: String { resolvedUrl.endpoints["deltaStorageUrl"]!.description }
    private var deltaStreamUrl: String { resolvedUrl.endpoints["deltaStreamUrl"]?.description ?? ordererUrl }
    private var storageUrl: String { resolvedUrl.endpoints["storageUrl"]!.description }
    private let tokenProvider: any ITokenProvider
    private let blobCache: InMemoryCache<[UInt8]>
    private let shreddedSummaryTreeCache: InMemoryCache<ISnapshotTreeVersion>?
    private let wholeSnapshotTreeCache: InMemoryCache<INormalizedWholeSnapshot>?
    private let driverPolicies: IRouterliciousDriverPolicies
    private let ordererRest: RestClient
    private let storageRest: RestClient
    private let refreshSession: @Sendable () async throws -> (IResolvedUrl, Bool)
    private let state = Mutex<(policies: IDocumentServicePolicies?, storage: DocumentStorageService?)>((nil, nil))

    init(
        resolvedUrl: IResolvedUrl, ordererUrl: String, deltaStorageUrl: String, deltaStreamUrl: String, storageUrl: String,
        tokenProvider: any ITokenProvider, tenantId: String, documentId: String, blobCache: InMemoryCache<[UInt8]>,
        shreddedSummaryTreeCache: InMemoryCache<ISnapshotTreeVersion>?,
        wholeSnapshotTreeCache: InMemoryCache<INormalizedWholeSnapshot>?, driverPolicies: IRouterliciousDriverPolicies,
        ordererRest: RestClient, storageRest: RestClient,
        refreshSession: @escaping @Sendable () async throws -> (IResolvedUrl, Bool)
    ) {
        endpoints = Mutex(resolvedUrl)
        self.wholeSnapshotTreeCache = wholeSnapshotTreeCache
        self.driverPolicies = driverPolicies
        self.ordererRest = ordererRest
        self.storageRest = storageRest
        self.refreshSession = refreshSession
        self.tokenProvider = tokenProvider
        self.tenantId = tenantId
        self.documentId = documentId
        self.blobCache = blobCache
        self.shreddedSummaryTreeCache = shreddedSummaryTreeCache
    }

    func initializeRequestResolvers() async {
        await storageRest.setRequestResolver { [weak self] path in
            guard let self else { throw JSONDecodingError("Document service released") }
            let refreshed = try await refreshSessionInfoIfNeeded()
            return (storageUrl, path, refreshed)
        }
        await ordererRest.setRequestResolver { [weak self] path in
            guard let self else { throw JSONDecodingError("Document service released") }
            // Discovery itself uses this wrapper and must not recursively rediscover.
            guard !path.contains("/documents/") else { return ("", path, false) }
            let refreshed = try await refreshSessionInfoIfNeeded()
            let query = path.firstIndex(of: "?").map { String(path[$0...]) } ?? ""
            return ("", deltaStorageUrl + query, refreshed)
        }
    }

    private func refreshSessionInfoIfNeeded() async throws -> Bool {
        let (url, refreshed) = try await refreshSession()
        if refreshed { endpoints.withLock { $0 = url } }
        return refreshed
    }

    /// Undefined until a delta connection reports `enable_single_commit_summary`.
    public var policies: IDocumentServicePolicies? { state.withLock { $0.policies } }

    public func dispose(_ error: (any Error)?) {}

    /// One storage service per document service.
    public func connectToStorage() async throws -> any IDocumentStorageService {
        try documentStorageService()
    }

    private func documentStorageService() throws -> DocumentStorageService {
        state.withLock { state in
            if let storage = state.storage { return storage }
            let rest = storageRest
            let inner: any RouterliciousStorage = driverPolicies.enableWholeSummaryUpload
                ? WholeSummaryDocumentStorageService(id: documentId, rest: rest, blobCache: blobCache, snapshotTreeCache: wholeSnapshotTreeCache, discovery: driverPolicies.enableDiscovery)
                : ShreddedSummaryDocumentStorageService(id: documentId, rest: rest, blobCache: blobCache, snapshotTreeCache: shreddedSummaryTreeCache)
            let storage = DocumentStorageService(
                id: documentId,
                internalStorageService: inner)
            state.storage = storage
            return storage
        }
    }

    public func connectToDeltaStorage() async throws -> any IDocumentDeltaStorageService {
        let storage = try documentStorageService()
        let rest = ordererRest
        return DocumentDeltaStorageService(
            deltaStorageService: DeltaStorageService(url: deltaStorageUrl, rest: rest), documentStorageService: storage)
    }

    /// documentService.ts: an authorization failure retries once with a refreshed token; the
    /// connection's `enable_single_commit_summary` feature sets `summarizeProtocolTree`.
    public func connectToDeltaStream(_ client: IClient) async throws -> any IDocumentDeltaConnection {
        let connection: DocumentDeltaConnection
        do {
            connection = try await connect(client, refreshToken: false)
        } catch let error as DriverError where error.errorType == "authorizationError" {
            connection = try await connect(client, refreshToken: true)
        }
        let summarizeProtocolTree = isTruthy(connection.details.supportedFeatures?["enable_single_commit_summary"])
        state.withLock { state in
            state.policies = IDocumentServicePolicies(
                storageOnly: state.policies?.storageOnly,
                summarizeProtocolTree: summarizeProtocolTree,
                supportGetSnapshotApi: state.policies?.supportGetSnapshotApi)
        }
        return connection
    }

    /// JS truthiness of a received feature flag.
    private func isTruthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null, .bool(false), .string(""): false
        case .number(let number): number != 0 && !number.isNaN
        default: true
        }
    }

    private func connect(_ client: IClient, refreshToken: Bool) async throws -> DocumentDeltaConnection {
        _ = try await refreshSessionInfoIfNeeded()
        let token: ITokenResponse
        if refreshToken {
            token = try await tokenProvider.fetchOrdererToken(tenantId: tenantId, documentId: documentId, refresh: true)
            await ordererRest.setToken(token)
        } else { token = try await ordererRest.getToken() }
        return try await R11sDocumentDeltaConnection.create(
            tenantId: tenantId, id: documentId, token: token.jwt, client: client, url: deltaStreamUrl)
    }
}
