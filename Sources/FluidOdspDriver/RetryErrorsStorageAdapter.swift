import FluidDriverDefinitions
import FluidJS
import Synchronization

/// retryErrorsStorageAdapter.ts. Every call runs under retryUtils.ts runWithRetry (coherency 409 and
/// serviceReadOnly only) and stops retrying once disposed.
public final class RetryErrorsStorageAdapter: IDocumentStorageService {
    private let internalStorageService: any IDocumentStorageService
    private let disposedState = Mutex(false)

    public init(_ internalStorageService: any IDocumentStorageService) {
        self.internalStorageService = internalStorageService
    }

    public var disposed: Bool {
        disposedState.withLock { $0 }
    }

    public func dispose() {
        disposedState.withLock { $0 = true }
    }

    public func getSnapshotTree(_ version: IVersion?, scenarioName: String?) async throws -> ISnapshotTree? {
        // TS forwards only the version.
        try await runWithRetry { try await self.internalStorageService.getSnapshotTree(version, scenarioName: nil) }
    }

    public func getSnapshot(_ options: ISnapshotFetchOptions?) async throws -> ISnapshot {
        try await runWithRetry { try await self.internalStorageService.getSnapshot(options) }
    }

    public func getVersions(_ versionId: JSString?, count: Int, scenarioName: String?, fetchSource: FetchSource?) async throws -> [IVersion] {
        try await runWithRetry { try await self.internalStorageService.getVersions(versionId, count: count, scenarioName: scenarioName, fetchSource: fetchSource) }
    }

    public func createBlob(_ file: [UInt8]) async throws -> ICreateBlobResponse {
        try await runWithRetry { try await self.internalStorageService.createBlob(file) }
    }

    public func readBlob(_ id: JSString) async throws -> [UInt8] {
        try await runWithRetry { try await self.internalStorageService.readBlob(id) }
    }

    /// The creation flow with attachment blobs needs retries.
    public func uploadSummaryWithContext(_ summary: SummaryTree, context: ISummaryContext) async throws -> JSString {
        try await runWithRetry { try await self.internalStorageService.uploadSummaryWithContext(summary, context: context) }
    }

    public func downloadSummary(_ handle: ISummaryHandle) async throws -> SummaryTree {
        try await runWithRetry { try await self.internalStorageService.downloadSummary(handle) }
    }

    private func runWithRetry<T>(_ api: () async throws -> T) async throws -> T {
        try await FluidOdspDriver.runWithRetry(sleep: { try await Task.sleep(for: .milliseconds($0)) }, random: { Double.random(in: 0..<1) }, checkDisposed: checkStorageDisposed, call: api)
    }

    private func checkStorageDisposed() throws {
        if disposed { throw OdspNetworkError("genericError", canRetry: false) }
    }
}
