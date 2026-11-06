import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Synchronization

/// Ports routerlicious-driver/src/documentService.ts. Session discovery is not ported, so the
/// endpoints never change after creation. Disposal does nothing, as in TS.
public final class DocumentService: IDocumentService {
    public let resolvedUrl: IResolvedUrl
    public let tenantId: String
    public let documentId: String
    private let ordererUrl: String
    private let deltaStorageUrl: String
    private let deltaStreamUrl: String
    private let storageUrl: String
    private let tokenProvider: any ITokenProvider
    private let blobCache: InMemoryCache<[UInt8]>
    private let shreddedSummaryTreeCache: InMemoryCache<ISnapshotTreeVersion>?
    private let state = Mutex<(policies: IDocumentServicePolicies?, storage: DocumentStorageService?)>((nil, nil))

    init(
        resolvedUrl: IResolvedUrl, ordererUrl: String, deltaStorageUrl: String, deltaStreamUrl: String, storageUrl: String,
        tokenProvider: any ITokenProvider, tenantId: String, documentId: String, blobCache: InMemoryCache<[UInt8]>,
        shreddedSummaryTreeCache: InMemoryCache<ISnapshotTreeVersion>?
    ) {
        self.resolvedUrl = resolvedUrl
        self.ordererUrl = ordererUrl
        self.deltaStorageUrl = deltaStorageUrl
        self.deltaStreamUrl = deltaStreamUrl
        self.storageUrl = storageUrl
        self.tokenProvider = tokenProvider
        self.tenantId = tenantId
        self.documentId = documentId
        self.blobCache = blobCache
        self.shreddedSummaryTreeCache = shreddedSummaryTreeCache
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
            let rest = RestClient(
                service: .storage, baseUrl: storageUrl, tenantId: tenantId, documentId: documentId, tokens: tokenProvider)
            let storage = DocumentStorageService(
                id: documentId,
                internalStorageService: ShreddedSummaryDocumentStorageService(
                    id: documentId, rest: rest, blobCache: blobCache, snapshotTreeCache: shreddedSummaryTreeCache))
            state.storage = storage
            return storage
        }
    }

    public func connectToDeltaStorage() async throws -> any IDocumentDeltaStorageService {
        let storage = try documentStorageService()
        let rest = RestClient(service: .orderer, baseUrl: "", tenantId: tenantId, documentId: documentId, tokens: tokenProvider)
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
        let token = try await tokenProvider.fetchOrdererToken(tenantId: tenantId, documentId: documentId, refresh: refreshToken)
        return try await R11sDocumentDeltaConnection.create(
            tenantId: tenantId, id: documentId, token: token.jwt, client: client, url: deltaStreamUrl)
    }
}
