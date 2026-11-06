import FluidJS

/// odspDeltaStorageService.ts OdspDeltaStorageWithCache. Pull one contiguous batch at a time;
/// socket requests are opportunistic and never replace a missing REST/cache result.
public final class OdspDeltaStorageWithCache {
    public struct FetchResult {
        public let messages: [JSONValue]
        public let partialResult: Bool
        public init(messages: [JSONValue], partialResult: Bool) {
            self.messages = messages
            self.partialResult = partialResult
        }
    }
    private var snapshotOps: [JSONValue]?
    private var useCacheForOps = true
    private let getFromStorage: (Int, Int) async throws -> FetchResult
    private let getCached: (Int, Int) async throws -> [JSONValue]
    private let requestFromSocket: (Int, Int) throws -> Void
    private let opsReceived: ([JSONValue]) throws -> Void
    public init(snapshotOps: [JSONValue]?, getFromStorage: @escaping (Int, Int) async throws -> FetchResult, getCached: @escaping (Int, Int) async throws -> [JSONValue], requestFromSocket: @escaping (Int, Int) throws -> Void, opsReceived: @escaping ([JSONValue]) throws -> Void) {
        self.snapshotOps = snapshotOps
        self.getFromStorage = getFromStorage
        self.getCached = getCached
        self.requestFromSocket = requestFromSocket
        self.opsReceived = opsReceived
    }
    public func beginFetch(isFirstSnapshotFromNetwork: Bool?) {
        useCacheForOps = useCacheForOps && isFirstSnapshotFromNetwork == false
    }
    public func fetchMessages(from: Int, to: Int, cachedOnly: Bool = false) async throws -> FetchResult {
        try Task.checkCancellation()
        if let snapshotOps, !snapshotOps.isEmpty {
            let messages = try snapshotOps.filter {
                let sequence = try $0.member("sequenceNumber").asInt()
                return sequence >= from && sequence < to
            }
            try validate(messages, from: from)
            if let first = messages.first, try first.member("sequenceNumber").asInt() == from {
                self.snapshotOps = try snapshotOps.filter { try $0.member("sequenceNumber").asInt() >= to }
                return FetchResult(messages: messages, partialResult: true)
            }
            self.snapshotOps = nil
        }
        try requestFromSocket(from, to)
        if useCacheForOps {
            let messages = try await getCached(from, to)
            try validate(messages, from: from)
            useCacheForOps = from + messages.count >= to
            if !messages.isEmpty { return FetchResult(messages: messages, partialResult: true) }
        }
        if cachedOnly { return FetchResult(messages: [], partialResult: false) }
        let result = try await getFromStorage(from, to)
        try validate(result.messages, from: from)
        try opsReceived(result.messages)
        return result
    }
    private func validate(_ messages: [JSONValue], from: Int) throws {
        for (index, message) in messages.enumerated() {
            guard try message.member("sequenceNumber").asInt() == from + index else {
                throw OdspNetworkError("genericError", canRetry: false)
            }
        }
    }
}
