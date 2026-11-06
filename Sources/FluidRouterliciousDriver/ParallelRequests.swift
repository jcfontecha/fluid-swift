import FluidDriverBase
import FluidDriverDefinitions
import FluidJS

/// parallelRequests.ts MissingFetchDelayInMs: the first retry waits twice this.
private let missingFetchDelayInMs = 50.0

/// runWithRetry.ts MaxReconnectDelayInMsWhenEndpointIsNotReachable. Driver errors here never
/// carry `endpointReached`, so the 60000 ms cap for a reachable endpoint does not apply.
private let maxReconnectDelayInMs = 8000.0

private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw JSONDecodingError(message) }
}

/// Ports driver-utils/src/parallelRequests.ts ParallelRequests, run with one worker: ranges are
/// [from, to), a known `to` never shrinks, and an unknown `to` is learned from the first short,
/// non-partial chunk. Confined to the task that runs it.
final class ParallelRequests<T> {
    private enum WorkingState {
        case working
        case done
        case canceled
    }

    private var latestRequested: Int
    private var nextToDeliver: Int
    private var results: [Int: [T]] = [:]
    private var workingState = WorkingState.working
    private var requestsInFlight = 0
    private var requests = 0
    private var to: Int?
    private let knewTo: Bool
    private let payloadSize: Int
    private let requestCallback: (_ request: Int, _ from: Int, _ to: Int, _ strongTo: Bool) async throws
        -> (partial: Bool, cancel: Bool, payload: [T])
    private let responseCallback: ([T]) throws -> Void

    private var working: Bool { workingState == .working }
    var canceled: Bool { workingState == .canceled }

    init(
        from: Int, to: Int?, payloadSize: Int,
        requestCallback: @escaping (Int, Int, Int, Bool) async throws -> (partial: Bool, cancel: Bool, payload: [T]),
        responseCallback: @escaping ([T]) throws -> Void
    ) {
        latestRequested = from
        nextToDeliver = from
        self.to = to
        knewTo = to != nil
        self.payloadSize = payloadSize
        self.requestCallback = requestCallback
        self.responseCallback = responseCallback
    }

    func cancel() {
        if working { workingState = .canceled }
    }

    /// `run(1)`: one worker, then a dispatch that finishes when nothing is in flight.
    func run() async throws {
        try check(working, "0x103: trying to parallel run while not working")
        if let chunk = getNextChunk() {
            try await addRequestCore(chunk.from, chunk.to)
        }
        try dispatch()
    }

    private func done() throws {
        guard let to else { throw JSONDecodingError("0x104: undefined end point for parallel fetch") }
        try check(nextToDeliver >= to, "0x105: unexpected end point for parallel fetch")
        if working { workingState = .done }
    }

    private func dispatch() throws {
        while working, let value = results.removeValue(forKey: nextToDeliver) {
            try check(value.count <= payloadSize, "0x1d9: addRequestCore() should break into smaller chunks")
            nextToDeliver += value.count
            try responseCallback(value)
        }
        guard working else { return }
        if requestsInFlight == 0 {
            try check(results.isEmpty, "0x107: ending dispatch with remaining results to be sent")
            try done()
        } else if let to, nextToDeliver >= to {
            try check(!knewTo, "0x108: ending results dispatch but knew in advance about more requests")
            try done()
        }
    }

    private func getNextChunk() -> (from: Int, to: Int)? {
        guard working else { return nil }
        let from = latestRequested
        if let to, to <= from { return nil }
        latestRequested += payloadSize
        if let to { latestRequested = min(to, latestRequested) }
        return (from, latestRequested)
    }

    private func addRequestCore(_ fromArg: Int, _ toArg: Int) async throws {
        try check(working, "0x10a: cannot add parallel request while not working")
        var from = fromArg
        var to = toArg
        requestsInFlight += 1
        while working {
            let requestedLength = to - from
            try check(requestedLength > 0, "0x10b: invalid parallel request range")
            if let end = self.to {
                try check(from < end, "0x10c: invalid parallel request start point")
                try check(to <= end, "0x10d: invalid parallel request end point")
            }
            requests += 1
            // TS dispatches buffered results after issuing the request, before awaiting it.
            try dispatch()
            var (partial, cancel, payload) = try await requestCallback(requests, from, to, self.to != nil)
            if cancel { self.cancel() }
            if let end = self.to, from >= end {
                try check(!knewTo, "0x10e: should not throw result if we knew about boundary in advance")
                break
            }
            guard working else { continue }
            let length = payload.count
            // We can get more than we asked for.
            var fullChunk = requestedLength <= length
            if length == 0 {
                try check(!partial, "0x10f: empty/partial chunks should not be returned by caching")
                try check(!knewTo, "0x110: callback should retry until valid fetch before it learns new boundary")
            } else {
                let data = Array(payload.prefix(requestedLength))
                payload.removeFirst(data.count)
                results[from] = data
                from += data.count
            }
            if !partial && !fullChunk {
                if !knewTo {
                    if let end = self.to {
                        if end > from { self.to = from }
                    } else {
                        self.to = from
                    }
                    break
                }
                // ParallelRequests_Partial: with a known end, a short chunk is never end of file.
            }
            if to == latestRequested {
                while !payload.isEmpty {
                    let data = Array(payload.prefix(requestedLength))
                    payload.removeFirst(data.count)
                    results[from] = data
                    from += data.count
                }
                latestRequested = from
                fullChunk = true
            }
            if fullChunk {
                guard let chunk = getNextChunk() else { break }
                from = chunk.from
                to = chunk.to
            }
        }
        requestsInFlight -= 1
        try dispatch()
    }
}

/// parallelRequests.ts getSingleOpBatch: retry until the range yields ops (when they must exist)
/// or a non-retryable error. An empty answer for a range that must exist fails after 30 s.
private func getSingleOpBatch(
    _ get: () async throws -> IDeltasFetchResult, strongTo: Bool
) async throws -> (partial: Bool, cancel: Bool, payload: [ISequencedDocumentMessage]) {
    let clock = ContinuousClock()
    var lastSuccessTime: ContinuousClock.Instant?
    var waitTime = missingFetchDelayInMs
    while !Task.isCancelled {
        var lastError: (any Error)?
        do {
            let result = try await get()
            // Without a "to" there is no expectation of how many ops come back.
            if !result.messages.isEmpty || !strongTo {
                return (result.partialResult, false, result.messages)
            }
            if let lastSuccessTime {
                if clock.now - lastSuccessTime > .milliseconds(30000) {
                    throw DriverError(
                        "Failed to retrieve ops from storage (Too Many Retries)",
                        .string("tooManyRetries"), canRetry: false)
                }
            } else {
                lastSuccessTime = clock.now
            }
        } catch {
            lastError = error
            // network.ts canRetryOnError: only an error that says it can be retried is.
            guard let driverError = error as? DriverError, driverError.canRetry else { throw error }
        }
        // runWithRetry.ts calculateMaxWaitTime.
        let retryAfterMs = (lastError as? DriverError)?.retryAfterSeconds.map { $0 * 1000 } ?? 0
        waitTime = min(max(retryAfterMs, waitTime * 2), maxReconnectDelayInMs)
        do {
            try await Task.sleep(for: .milliseconds(waitTime))
        } catch {
            break
        }
    }
    return (false, true, [])
}

/// Ports driver-utils/src/parallelRequests.ts `requestOps` at concurrency 1, the only concurrency
/// the routerlicious driver uses (deltaStorageService.ts). Lives in this driver because no
/// driver-utils target exists. Ranges are [fromTotal, toTotal); a nil `toTotal` reads to the end.
/// Ending the stream's iteration cancels the fetch.
public func requestOps(
    _ get: @escaping @Sendable (_ from: Int, _ to: Int) async throws -> IDeltasFetchResult,
    fromTotal: Int, toTotal: Int?, payloadSize: Int
) -> AsyncThrowingStream<[ISequencedDocumentMessage], any Error> {
    let (stream, continuation) = AsyncThrowingStream<[ISequencedDocumentMessage], any Error>.makeStream()
    let task = Task {
        var lastFetch: Int?
        let manager = ParallelRequests<ISequencedDocumentMessage>(
            from: fromTotal, to: toTotal, payloadSize: payloadSize,
            requestCallback: { _, from, to, strongTo in
                try await getSingleOpBatch({ try await get(from, to) }, strongTo: strongTo)
            },
            responseCallback: { deltas in
                guard let first = deltas.first, let last = deltas.last else { return }
                if let lastFetch {
                    try check(first.sequenceNumber == lastFetch + 1, "0x26e: wrong start")
                } else {
                    try check(first.sequenceNumber == fromTotal, "0x26d: wrong start")
                }
                lastFetch = last.sequenceNumber
                try check(
                    last.sequenceNumber - first.sequenceNumber + 1 == deltas.count,
                    "0x26f: continuous and no duplicates")
                continuation.yield(deltas)
            })
        do {
            try await manager.run()
            if !manager.canceled {
                if let toTotal {
                    try check((lastFetch ?? Int.min) >= toTotal - 1, "0x270: All requested ops fetched")
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
}
