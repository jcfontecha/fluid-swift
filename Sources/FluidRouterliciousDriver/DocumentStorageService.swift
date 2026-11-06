import FluidDriverDefinitions
import FluidJS
import Synchronization

/// Ports routerlicious-driver/src/documentStorageService.ts over driver-utils'
/// documentStorageServiceProxy.ts. The proxy selects whole or shredded storage. The prefetching wrapper is not ported. Remembers the `.logTail`
/// blob of the last snapshot tree it read, for DocumentDeltaStorageService.
public final class DocumentStorageService: IDocumentStorageService {
    public let id: String
    private let internalStorageService: any RouterliciousStorage
    private let logTail = Mutex<JSString?>(nil)

    init(id: String, internalStorageService: any RouterliciousStorage) {
        self.id = id
        self.internalStorageService = internalStorageService
    }

    public var logTailSha: JSString? { logTail.withLock { $0 } }

    public func getSnapshotTree(_ version: IVersion?, scenarioName: String?) async throws -> ISnapshotTree? {
        guard let tree = try await internalStorageService.getSnapshotTree(version) else { return nil }
        logTail.withLock { $0 = tree.trees[".logTail"]?.blobs["logTail"] }
        return try ISnapshotTree(json: tree.json)
    }

    public func getSnapshot(_ options: ISnapshotFetchOptions?) async throws -> ISnapshot {
        throw JSONDecodingError("getSnapshot api should exist on internal storage in documentStorageServiceProxy class")
    }

    public func getVersions(_ versionId: JSString?, count: Int, scenarioName: String?, fetchSource: FetchSource?)
        async throws -> [IVersion]
    {
        try await internalStorageService.getVersions(versionId, count: count)
    }

    public func createBlob(_ file: [UInt8]) async throws -> ICreateBlobResponse {
        try await internalStorageService.createBlob(file)
    }

    public func readBlob(_ id: JSString) async throws -> [UInt8] {
        try await internalStorageService.readBlob(id)
    }

    public func uploadSummaryWithContext(_ summary: SummaryTree, context: ISummaryContext) async throws -> JSString {
        try await internalStorageService.uploadSummaryWithContext(summary, context: context)
    }

    public func downloadSummary(_ handle: ISummaryHandle) async throws -> SummaryTree {
        try await internalStorageService.downloadSummary(handle)
    }
}

/// The two TS storage implementations share the same proxy contract.
protocol RouterliciousStorage: Sendable {
    func getSnapshotTree(_ version: IVersion?) async throws -> ISnapshotTree?
    func getVersions(_ versionId: JSString?, count: Int) async throws -> [IVersion]
    func createBlob(_ file: [UInt8]) async throws -> ICreateBlobResponse
    func readBlob(_ id: JSString) async throws -> [UInt8]
    func uploadSummaryWithContext(_ summary: SummaryTree, context: ISummaryContext) async throws -> JSString
    func downloadSummary(_ handle: ISummaryHandle) async throws -> SummaryTree
}
