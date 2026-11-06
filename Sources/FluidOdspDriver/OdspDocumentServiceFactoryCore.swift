import FluidDriverDefinitions
import FluidJS
import Foundation

/// odspDocumentServiceFactoryCore.ts. Owns the per-factory caches (join session, persisted) and
/// the Socket.IO registry; TS keeps sockets in a module-global cache unless `isolateSocketCache`,
/// so this is TS with socket isolation per factory.
public final class OdspDocumentServiceFactoryCore: IDocumentServiceFactory {
    private let getStorageToken: TokenFetcher
    private let getWebsocketToken: TokenFetcher?
    private let persistedCache: LocalPersistentCache
    private let hostPolicy: HostStoragePolicy
    /// NonPersistentCache.sessionJoinCache.
    private let sessionJoinCache = OdspSessionJoinCache()
    private let socketIOFactory = OdspSocketIOFactory()

    /// `getStorageToken` is the "Vroom" token; `getWebsocketToken` is the "Push" token. Without a
    /// websocket fetcher the token comes with the join-session response.
    public init(getStorageToken: @escaping TokenFetcher, getWebsocketToken: TokenFetcher?, persistedCache: LocalPersistentCache = LocalPersistentCache(), hostPolicy: HostStoragePolicy = HostStoragePolicy()) {
        self.getStorageToken = getStorageToken
        self.getWebsocketToken = getWebsocketToken
        self.persistedCache = persistedCache
        self.hostPolicy = hostPolicy
    }

    public func createDocumentService(_ resolvedUrl: IResolvedUrl, clientIsSummarizer: Bool) async throws -> any IDocumentService {
        createDocumentServiceCore(try getOdspResolvedUrl(resolvedUrl), network: nil, clientIsSummarizer: clientIsSummarizer)
    }

    public func createContainer(_ createNewSummary: SummaryTree?, resolvedUrl: IResolvedUrl, clientIsSummarizer: Bool) async throws -> any IDocumentService {
        let odspResolvedUrl = try getOdspResolvedUrl(resolvedUrl)
        let summary: ISummaryTree?
        switch createNewSummary {
        case .tree(let tree): summary = tree
        case .handle: throw JSONDecodingError("App and protocol summary required for create new path!!")
        case nil: summary = nil
        }
        if let summary, isCombinedAppAndProtocolSummary(summary), case .tree(let protocolSummary) = summary.tree[".protocol"] {
            guard try getDocAttributesFromProtocolSummary(protocolSummary).asObject()["sequenceNumber"] == .number(0) else {
                throw JSONDecodingError("Seq number in detached ODSP container should be 0")
            }
        }
        let network = createOdspCacheAndTracker(odspResolvedUrl, clientIsSummarizer: clientIsSummarizer)
        let createdUrl: IOdspResolvedUrl
        if !odspResolvedUrl.itemId.isEmpty {
            let fileInfo = IExistingFileInfo(siteUrl: odspResolvedUrl.siteUrl, driveId: odspResolvedUrl.driveId, itemId: odspResolvedUrl.itemId)
            createdUrl = try await createNewContainerOnExistingFile(network: network, fileInfo: fileInfo, createNewSummary: summary, persistedCache: persistedCache, createNewCaching: hostPolicy.cacheCreateNewSummary ?? true, isClpCompliantApp: odspResolvedUrl.isClpCompliantApp, eTag: odspResolvedUrl.eTag)
        } else if !odspResolvedUrl.fileName.isEmpty {
            let url = try odspResolvedUrl.json.member("url").asString().description
            let parts = url.components(separatedBy: "?")
            let searchParams = URLSearchParams(parts.count > 1 ? parts[1] : "")
            let fileInfo = INewFileInfo(siteUrl: odspResolvedUrl.siteUrl, driveId: odspResolvedUrl.driveId, location: try getNewFileLocation(searchParams), filename: odspResolvedUrl.fileName)
            createdUrl = try await createNewFluidFile(network: network, newFileInfo: fileInfo, createNewSummary: summary, persistedCache: persistedCache, createNewCaching: hostPolicy.cacheCreateNewSummary ?? true, resolvedUrl: odspResolvedUrl)
        } else {
            throw JSONDecodingError("A new or existing file must be specified to create container!")
        }
        return createDocumentServiceCore(createdUrl, network: network, clientIsSummarizer: clientIsSummarizer)
    }

    /// epochTracker.ts createOdspCacheAndTracker: one redemption-aware tracker per file whose cache
    /// removal clears the factory's persisted entries for the current docId.
    private func createOdspCacheAndTracker(_ resolvedUrl: IOdspResolvedUrl, clientIsSummarizer: Bool) -> OdspNetwork {
        let fileEntry = OdspFileEntry(resolvedUrl)
        let persistedCache = self.persistedCache
        let epochTracker = EpochTrackerWithRedemption(clientIsSummarizer: clientIsSummarizer, cacheRemove: {
            persistedCache.removeEntries(docId: fileEntry.docId)
        })
        return OdspNetwork(fileEntry: fileEntry, epochTracker: epochTracker, tokenFetcher: getStorageToken)
    }

    private func createDocumentServiceCore(_ resolvedUrl: IOdspResolvedUrl, network: OdspNetwork?, clientIsSummarizer: Bool) -> OdspDocumentService {
        let network = network ?? createOdspCacheAndTracker(resolvedUrl, clientIsSummarizer: clientIsSummarizer)
        let websocketTokenFetcher = getWebsocketToken.map { plainTokenFetcher($0, resolvedUrl: resolvedUrl) }
        return OdspDocumentService(network: network, getWebsocketToken: websocketTokenFetcher, sessionJoinCache: sessionJoinCache, persistedCache: persistedCache, hostPolicy: hostPolicy, socketIOFactory: socketIOFactory, clientIsSummarizer: clientIsSummarizer)
    }
}

/// odspDocumentServiceFactory.ts OdspDocumentServiceFactory adds nothing to the core in TS beyond
/// the public name.
public typealias OdspDocumentServiceFactory = OdspDocumentServiceFactoryCore

/// getNewFileLocation: exactly one of a folder path or a non-empty parent folder item ID.
private func getNewFileLocation(_ searchParams: URLSearchParams) throws -> NewFileLocation {
    let filePath = tryGetNewFilePath(searchParams)
    let parentFolderId = tryGetNewFileParentFolderId(searchParams)
    guard let parentFolderId else {
        guard let filePath else { throw JSONDecodingError("Either a file path or a parent folder ID must be provided to create a new file") }
        return .filePath(filePath)
    }
    if filePath != nil { throw JSONDecodingError("Only one of a file path or a parent folder ID can be provided to create a new file") }
    if parentFolderId.isEmpty { throw JSONDecodingError("The parent folder ID for a new file must not be empty") }
    return .parentFolderId(parentFolderId)
}
