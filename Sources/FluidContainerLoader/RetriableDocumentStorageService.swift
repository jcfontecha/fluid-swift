import FluidDriverDefinitions
import FluidDriverUtils
import FluidJS
import Synchronization

/// Ports container-loader/src/retriableDocumentStorageService.ts. Only creation summaries retry:
/// retrying an ordinary upload could publish a stale summary after the summarizer loses its lease.
public final class RetriableDocumentStorageService: IDocumentStorageService {
    private let storage: any IDocumentStorageService
    private let maxRetries: Int?
    private let sleep: RetrySleep
    private let isDisposed = Mutex(false)

    public init(_ storage: any IDocumentStorageService, maxRetries: Int? = nil, sleep: @escaping RetrySleep = retrySleep) {
        self.storage = storage
        self.maxRetries = maxRetries
        self.sleep = sleep
    }

    public var disposed: Bool { isDisposed.withLock { $0 } }

    public func dispose() {
        isDisposed.withLock { $0 = true }
    }

    private nonisolated(nonsending) func retry<T>(_ api: () async throws -> T) async throws -> T {
        try await runWithRetry(api, maxRetries: maxRetries, onRetry: { _, _ in
            if self.disposed {
                throw NetworkError("Storage Service is disposed. Cannot retry", canRetry: false)
            }
        }, sleep: sleep)
    }

    public func getSnapshotTree(_ version: IVersion?, scenarioName: String?) async throws -> ISnapshotTree? {
        try await retry { try await self.storage.getSnapshotTree(version, scenarioName: scenarioName) }
    }

    public func getSnapshot(_ options: ISnapshotFetchOptions?) async throws -> ISnapshot {
        try await retry { try await self.storage.getSnapshot(options) }
    }

    public func getVersions(_ versionId: JSString?, count: Int, scenarioName: String?, fetchSource: FetchSource?) async throws -> [IVersion] {
        try await retry { try await self.storage.getVersions(versionId, count: count, scenarioName: scenarioName, fetchSource: fetchSource) }
    }

    public func createBlob(_ file: [UInt8]) async throws -> ICreateBlobResponse {
        try await retry { try await self.storage.createBlob(file) }
    }

    public func readBlob(_ id: JSString) async throws -> [UInt8] {
        try await retry { try await self.storage.readBlob(id) }
    }

    public func uploadSummaryWithContext(_ summary: SummaryTree, context: ISummaryContext) async throws -> JSString {
        guard (context.referenceSequenceNumber == 0) == (context.ackHandle == nil) else {
            throw JSONDecodingError("0x251: creation summary has to have seq=0 && handle === undefined")
        }
        if context.referenceSequenceNumber != 0 {
            return try await storage.uploadSummaryWithContext(summary, context: context)
        }
        return try await retry { try await self.storage.uploadSummaryWithContext(summary, context: context) }
    }

    public func downloadSummary(_ handle: ISummaryHandle) async throws -> SummaryTree {
        try await retry { try await self.storage.downloadSummary(handle) }
    }
}
