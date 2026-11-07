import FluidContainerLoader
import FluidDriverDefinitions
import FluidDriverUtils
import FluidJS
import Synchronization
import Testing

private final class FailingStorage: IDocumentStorageService {
    let calls = Mutex(0)
    let failures: Int

    init(failures: Int) { self.failures = failures }

    private func attempt() throws {
        let call = calls.withLock { value in
            value += 1
            return value
        }
        if call <= failures {
            throw NetworkError("503", canRetry: true, retryAfterSeconds: 0.01, endpointReached: true)
        }
    }

    func readBlob(_ id: JSString) async throws -> [UInt8] {
        try attempt()
        return [1, 2, 3]
    }

    func uploadSummaryWithContext(_ summary: SummaryTree, context: ISummaryContext) async throws -> JSString {
        try attempt()
        return "summary"
    }

    func getSnapshotTree(_ version: IVersion?, scenarioName: String?) async throws -> ISnapshotTree? {
        try attempt()
        return nil
    }

    func getVersions(_ versionId: JSString?, count: Int, scenarioName: String?, fetchSource: FetchSource?) async throws -> [IVersion] {
        try attempt()
        return []
    }

    func getSnapshot(_ options: ISnapshotFetchOptions?) async throws -> ISnapshot { throw JSONDecodingError("unused") }
    func createBlob(_ file: [UInt8]) async throws -> ICreateBlobResponse { throw JSONDecodingError("unused") }
    func downloadSummary(_ handle: ISummaryHandle) async throws -> SummaryTree { throw JSONDecodingError("unused") }
}

struct StorageRetryTests {
    @Test func retryAndDisposedService() async throws {
        let driver = FailingStorage(failures: 2)
        let delays = Mutex<[Double]>([])
        let storage = RetriableDocumentStorageService(driver, sleep: { delay in
            delays.withLock { $0.append(delay) }
        })
        #expect(try await storage.readBlob("blob") == [1, 2, 3])
        #expect(delays.withLock { $0 } == [1000, 2000])
        let disposedDriver = FailingStorage(failures: 2)
        let disposed = RetriableDocumentStorageService(disposedDriver, sleep: { _ in Issue.record("disposed storage retried") })
        disposed.dispose()
        await #expect(throws: (any Error).self) { try await disposed.readBlob("blob") }
        #expect(disposedDriver.calls.withLock { $0 } == 1)
    }

    @Test func onlyCreationSummaryRetries() async throws {
        let summary = SummaryTree.singleBlob("data", "value")
        let creationDriver = FailingStorage(failures: 1)
        let creation = RetriableDocumentStorageService(creationDriver, sleep: { _ in })
        let creationContext = try ISummaryContext(json: JSON.parse(#"{"referenceSequenceNumber":0}"#))
        #expect(try await creation.uploadSummaryWithContext(summary, context: creationContext) == "summary")
        #expect(creationDriver.calls.withLock { $0 } == 2)
        let regularDriver = FailingStorage(failures: 1)
        let regular = RetriableDocumentStorageService(regularDriver, sleep: { _ in Issue.record("stale summary retried") })
        let context = try ISummaryContext(json: JSON.parse(#"{"referenceSequenceNumber":1,"ackHandle":"previous"}"#))
        await #expect(throws: (any Error).self) { try await regular.uploadSummaryWithContext(summary, context: context) }
        #expect(regularDriver.calls.withLock { $0 } == 1)
    }
}
