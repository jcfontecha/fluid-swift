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
    private let sessionInfoManager: SessionInfoManager
    private let wholeSnapshotTreeCache: InMemoryCache<INormalizedWholeSnapshot>?
    private let shreddedSummaryTreeCache: InMemoryCache<ISnapshotTreeVersion>?

    public init(tokenProvider: any ITokenProvider, driverPolicies: IRouterliciousDriverPolicies = IRouterliciousDriverPolicies()) {
        self.tokenProvider = tokenProvider
        self.driverPolicies = driverPolicies
        sessionInfoManager = SessionInfoManager(enabled: driverPolicies.enableDiscovery)
        wholeSnapshotTreeCache = driverPolicies.enableInternalSummaryCaching && driverPolicies.enableWholeSummaryUpload ? InMemoryCache(expirationMs: maximumSnapshotCacheDurationMs) : nil
        shreddedSummaryTreeCache =
            driverPolicies.enableInternalSummaryCaching && !driverPolicies.enableWholeSummaryUpload
            ? InMemoryCache(expirationMs: maximumSnapshotCacheDurationMs) : nil
    }

    /// Ports the create-new summary POST and both document-id URL rewrites.
    public func createContainer(_ createNewSummary: SummaryTree?, resolvedUrl: IResolvedUrl, clientIsSummarizer: Bool)
        async throws -> any IDocumentService
    {
        guard case .tree(let summary) = createNewSummary else {
            throw JSONDecodingError("Empty file summary creation isn't supported in this driver.")
        }
        guard case .tree(let app) = summary.tree[".app"], case .tree(let proto) = summary.tree[".protocol"] else {
            throw JSONDecodingError("Protocol and App Summary required in the full summary")
        }
        func protocolBlob(_ name: JSString) throws -> JSONValue {
            guard case .blob(let blob) = proto.tree[name], case .text(let text) = blob.content else {
                throw JSONDecodingError("Missing protocol blob \(name)")
            }
            return try JSON.parse(text.description)
        }
        let attributes = try protocolBlob("attributes")
        let values = try protocolBlob("quorumValues")
        let tenant = URL(string: resolvedUrl.url.description)!.path.split(separator: "/")[0].description
        let rest = RestClient(service: .orderer, baseUrl: resolvedUrl.endpoints["ordererUrl"]!.description, tenantId: tenant, documentId: "", tokens: tokenProvider, useRestLess: driverPolicies.enableRestLess)
        var body = JSObject<JSONValue>()
        let upload = try WholeSummaryUploadManager.payload(.tree(app), parentHandle: nil)
        body["summary"] = .object(r11sObject( [("type", .string("tree")), ("entries", try upload.member("entries"))]))
        body["sequenceNumber"] = try attributes.member("sequenceNumber")
        body["values"] = values
        body["enableDiscovery"] = .bool(driverPolicies.enableDiscovery)
        body["generateToken"] = .bool(tokenProvider.documentPostCreateCallback != nil)
        let resolvedFields = try resolvedUrl.json.asObject()
        body["isEphemeralContainer"] = .bool(resolvedFields["routerliciousResolvedUrl"] == .bool(true) && resolvedFields["createAsEphemeral"] == .bool(true))
        body["enableAnyBinaryBlobOnFirstSummary"] = .bool(true)
        let response = try await rest.post("/documents/\(tenant)", body: .object(body))
        let document: JSString
        var session: JSONValue?
        if case .string(let id) = response { document = id }
        else {
            document = try response.member("id").asString()
            let fields = try response.asObject()
            if driverPolicies.enableDiscovery { session = fields["session"] }
            if let token = fields["token"], let callback = tokenProvider.documentPostCreateCallback {
                do { try await callback(document.description, token.asString().description) }
                catch { throw DocumentPostCreateError(innerError: error) }
            }
        }
        func rewrite(_ value: String) throws -> JSString {
            guard var url = URLComponents(string: value) else { throw JSONDecodingError("Invalid URL") }
            var parts = url.percentEncodedPath.components(separatedBy: "/")
            parts[parts.count - 1] = document.description
            url.percentEncodedPath = parts.joined(separator: "/")
            return JSString(url.string!)
        }
        var updated = try resolvedUrl.json.asObject()
        updated["url"] = .string(try rewrite(resolvedUrl.url.description))
        updated["id"] = .string(document)
        var endpoints = try resolvedUrl.json.member("endpoints").asObject()
        endpoints["deltaStorageUrl"] = .string(try rewrite(resolvedUrl.endpoints["deltaStorageUrl"]!.description))
        updated["endpoints"] = .object(endpoints)
        return try await createService(IResolvedUrl(json: .object(updated)), session: session)
    }

    /// Tenant and document come from the resolved URL's path, `/{tenantId}/{documentId}`.
    public func createDocumentService(_ resolvedUrl: IResolvedUrl, clientIsSummarizer: Bool) async throws
        -> any IDocumentService
    {
        try await createService(resolvedUrl, session: nil)
    }

    private func createService(_ resolvedUrl: IResolvedUrl, session: JSONValue?) async throws -> any IDocumentService {
        guard let parsedUrl = URL(string: resolvedUrl.url.description) else {
            throw JSONDecodingError("Invalid URL: \(resolvedUrl.url)")
        }
        let segments = parsedUrl.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false)
        let tenantId = segments.count > 1 ? String(segments[1]) : ""
        let documentId = segments.count > 2 ? String(segments[2]) : ""
        guard !documentId.isEmpty, !tenantId.isEmpty else {
            throw JSONDecodingError("Couldn't parse documentId and/or tenantId. [documentId:\(documentId)][tenantId:\(tenantId)]")
        }
        let ordererRest = RestClient(service: .orderer, baseUrl: "", tenantId: tenantId, documentId: documentId, tokens: tokenProvider, useRestLess: driverPolicies.enableRestLess)
        try await ordererRest.initializeToken()
        let storageToken = try await tokenProvider.fetchStorageToken(tenantId: tenantId, documentId: documentId, refresh: false)
        let originalUrl = resolvedUrl
        let resolvedUrl = try await sessionInfoManager.initialize(resolvedUrl, tenant: tenantId, document: documentId, rest: ordererRest, session: session)
        let storageUrl = resolvedUrl.endpoints["storageUrl"]?.description ?? ""
        let ordererUrl = resolvedUrl.endpoints["ordererUrl"]?.description ?? ""
        let deltaStorageUrl = resolvedUrl.endpoints["deltaStorageUrl"]?.description ?? ""
        // Backward compatibility: the delta stream is on the orderer unless the URL says otherwise.
        let deltaStreamUrl = resolvedUrl.endpoints["deltaStreamUrl"].map(\.description).flatMap { $0.isEmpty ? nil : $0 } ?? ordererUrl
        guard !ordererUrl.isEmpty, !deltaStorageUrl.isEmpty else {
            throw JSONDecodingError(
                "All endpoints urls must be provided. [ordererUrl:\(ordererUrl)][deltaStorageUrl:\(deltaStorageUrl)]")
        }
        let storageRest = RestClient(service: .storage, baseUrl: storageUrl, tenantId: tenantId, documentId: documentId, tokens: tokenProvider, useRestLess: driverPolicies.enableRestLess)
        try await storageRest.initializeToken(storageToken)
        let service = DocumentService(
            resolvedUrl: resolvedUrl, ordererUrl: ordererUrl, deltaStorageUrl: deltaStorageUrl, deltaStreamUrl: deltaStreamUrl,
            storageUrl: storageUrl, tokenProvider: tokenProvider, tenantId: tenantId, documentId: documentId,
            blobCache: blobCache, shreddedSummaryTreeCache: shreddedSummaryTreeCache,
            wholeSnapshotTreeCache: wholeSnapshotTreeCache, driverPolicies: driverPolicies,
            ordererRest: ordererRest, storageRest: storageRest,
            refreshSession: { try await self.sessionInfoManager.get(originalUrl, tenant: tenantId, document: documentId, rest: ordererRest) })
        await service.initializeRequestResolvers()
        return service
    }
}

public struct DocumentPostCreateError: Error {
    public let innerError: any Error
}
