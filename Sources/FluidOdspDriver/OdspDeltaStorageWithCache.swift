import FluidDriverUtils
import FluidDriverDefinitions
import FluidJS

/// odspDeltaStorageService.ts OdspDeltaStorageWithCache. Each batch comes from the snapshot's ops,
/// then the ops cache, then the delta feed; socket get_ops requests are opportunistic and never
/// replace a missing REST/cache result.
public actor OdspDeltaStorageWithCache: IDocumentDeltaStorageService {
    public struct FetchResult: Sendable {
        public let messages: [JSONValue]
        public let partialResult: Bool
        public init(messages: [JSONValue], partialResult: Bool) {
            self.messages = messages
            self.partialResult = partialResult
        }
    }
    private var snapshotOps: [JSONValue]?
    private var useCacheForOps = true
    private let batchSize: Int
    private let concurrency: Int
    private let getFromStorage: @Sendable (Int, Int, String?) async throws -> FetchResult
    private let getCached: @Sendable (Int, Int) async throws -> [JSONValue]
    private let requestFromSocket: @Sendable (Int, Int) async throws -> Void
    private let opsReceived: @Sendable ([JSONValue]) async -> Void
    private let storageManagerGetter: @Sendable () async -> OdspDocumentStorageService?

    public init(snapshotOps: [JSONValue]?, batchSize: Int, concurrency: Int, getFromStorage: @escaping @Sendable (Int, Int, String?) async throws -> FetchResult, getCached: @escaping @Sendable (Int, Int) async throws -> [JSONValue], requestFromSocket: @escaping @Sendable (Int, Int) async throws -> Void, opsReceived: @escaping @Sendable ([JSONValue]) async -> Void, storageManagerGetter: @escaping @Sendable () async -> OdspDocumentStorageService?) {
        self.snapshotOps = snapshotOps
        self.batchSize = batchSize
        self.concurrency = concurrency
        self.getFromStorage = getFromStorage
        self.getCached = getCached
        self.requestFromSocket = requestFromSocket
        self.opsReceived = opsReceived
        self.storageManagerGetter = storageManagerGetter
    }

    public nonisolated func fetchMessages(_ from: Int, to: Int?, cachedOnly: Bool, fetchReason: String?) -> AsyncThrowingStream<[ISequencedDocumentMessage], any Error> {
        let (stream, continuation) = AsyncThrowingStream<[ISequencedDocumentMessage], any Error>.makeStream()
        let task = Task {
            do {
                // A fixed range cannot be served from cache alone: the stream would never end.
                guard !cachedOnly || to == nil else { throw JSONDecodingError("0x1e3") }
                await self.beginFetch()
                let batches = requestOps(concurrency: concurrency, fromTotal: from, toTotal: to, payloadSize: batchSize) { batchFrom, batchTo in
                    let result = try await self.requestCallback(from: batchFrom, to: batchTo, cachedOnly: cachedOnly, fetchReason: fetchReason)
                    var messages = result.messages
                    try validateMessages(&messages, from: batchFrom)
                    return (messages, result.partialResult)
                }
                for try await batch in batches {
                    continuation.yield(try batch.map { try ISequencedDocumentMessage(json: $0) })
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        // The loader's abort: a consumer that stops iterating cancels the fetch (parallelRequests.ts:434, :617).
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Don't use the ops cache when the snapshot came from the network or was not fetched at all.
    private func beginFetch() async {
        let fromNetwork = await storageManagerGetter()?.isFirstSnapshotFromNetwork
        useCacheForOps = useCacheForOps && fromNetwork == false
    }

    func requestCallback(from: Int, to: Int, cachedOnly: Bool, fetchReason: String?) async throws -> FetchResult {
        if let snapshotOps, !snapshotOps.isEmpty {
            var messages = try snapshotOps.filter {
                let sequence = try $0.member("sequenceNumber").asInt()
                return sequence >= from && sequence < to
            }
            try validateMessages(&messages, from: from)
            if let first = messages.first, try first.member("sequenceNumber").asInt() == from {
                self.snapshotOps = try snapshotOps.filter { try $0.member("sequenceNumber").asInt() >= to }
                return FetchResult(messages: messages, partialResult: true)
            }
            self.snapshotOps = nil
        }
        // Ask the push service as well, in case it has them.
        try await requestFromSocket(from, to)
        // The cache is continuous in the normal flow: after the first miss it is not consulted again.
        if useCacheForOps {
            var messages = try await getCached(from, to)
            try validateMessages(&messages, from: from)
            useCacheForOps = from + messages.count >= to
            if !messages.isEmpty { return FetchResult(messages: messages, partialResult: true) }
        }
        if cachedOnly { return FetchResult(messages: [], partialResult: false) }
        let result = try await getFromStorage(from, to, fetchReason)
        var messages = result.messages
        try validateMessages(&messages, from: from)
        await opsReceived(messages)
        return FetchResult(messages: messages, partialResult: result.partialResult)
    }
}
