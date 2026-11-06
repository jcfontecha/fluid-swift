import FluidDriverDefinitions
import FluidJS
import Foundation

/// documentServiceFactory.ts maximumSnapshotCacheDurationMs: five days.
private let maximumSnapshotCacheDurationMs = 432_000_000.0

/// Ports routerlicious-driver/src/documentServiceFactory.ts. The blob cache and the shredded
/// snapshot-tree cache are shared by every document service this factory creates.
public final class RouterliciousDocumentServiceFactory: IDocumentServiceFactory {
    private let tokenProvider: any ITokenProvider
    private let driverPolicies: IRouterliciousDriverPolicies
    private let blobCache = InMemoryCache<[UInt8]>()
    private let shreddedSummaryTreeCache: InMemoryCache<ISnapshotTreeVersion>?

    public init(tokenProvider: any ITokenProvider, driverPolicies: IRouterliciousDriverPolicies = IRouterliciousDriverPolicies()) {
        self.tokenProvider = tokenProvider
        self.driverPolicies = driverPolicies
        shreddedSummaryTreeCache =
            driverPolicies.enableInternalSummaryCaching && !driverPolicies.enableWholeSummaryUpload
            ? InMemoryCache(expirationMs: maximumSnapshotCacheDurationMs) : nil
    }

    /// Creating a document (`POST /documents/{tenantId}`) is not ported.
    public func createContainer(_ createNewSummary: SummaryTree?, resolvedUrl: IResolvedUrl, clientIsSummarizer: Bool)
        async throws -> any IDocumentService
    {
        throw JSONDecodingError("RouterliciousDocumentServiceFactory.createContainer is not ported")
    }

    /// Tenant and document come from the resolved URL's path, `/{tenantId}/{documentId}`.
    public func createDocumentService(_ resolvedUrl: IResolvedUrl, clientIsSummarizer: Bool) async throws
        -> any IDocumentService
    {
        guard !driverPolicies.enableDiscovery, !driverPolicies.enableWholeSummaryUpload else {
            throw JSONDecodingError("routerlicious discovery and whole-summary storage are not ported")
        }
        guard let parsedUrl = URL(string: resolvedUrl.url.description) else {
            throw JSONDecodingError("Invalid URL: \(resolvedUrl.url)")
        }
        let segments = parsedUrl.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false)
        let tenantId = segments.count > 1 ? String(segments[1]) : ""
        let documentId = segments.count > 2 ? String(segments[2]) : ""
        guard !documentId.isEmpty, !tenantId.isEmpty else {
            throw JSONDecodingError("Couldn't parse documentId and/or tenantId. [documentId:\(documentId)][tenantId:\(tenantId)]")
        }
        let storageUrl = resolvedUrl.endpoints["storageUrl"]?.description ?? ""
        let ordererUrl = resolvedUrl.endpoints["ordererUrl"]?.description ?? ""
        let deltaStorageUrl = resolvedUrl.endpoints["deltaStorageUrl"]?.description ?? ""
        // Backward compatibility: the delta stream is on the orderer unless the URL says otherwise.
        let deltaStreamUrl = resolvedUrl.endpoints["deltaStreamUrl"].map(\.description).flatMap { $0.isEmpty ? nil : $0 } ?? ordererUrl
        guard !ordererUrl.isEmpty, !deltaStorageUrl.isEmpty else {
            throw JSONDecodingError(
                "All endpoints urls must be provided. [ordererUrl:\(ordererUrl)][deltaStorageUrl:\(deltaStorageUrl)]")
        }
        return DocumentService(
            resolvedUrl: resolvedUrl, ordererUrl: ordererUrl, deltaStorageUrl: deltaStorageUrl, deltaStreamUrl: deltaStreamUrl,
            storageUrl: storageUrl, tokenProvider: tokenProvider, tenantId: tenantId, documentId: documentId,
            blobCache: blobCache, shreddedSummaryTreeCache: shreddedSummaryTreeCache)
    }
}
