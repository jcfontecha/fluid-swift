import FluidDriverDefinitions
import FluidJS
import Foundation
import Synchronization

/// Ports driver-utils/src/parallelRequests.ts.
/// ParallelRequests: fetches [from, to) in `payloadSize` chunks with bounded concurrency and
/// delivers payloads in order. All state is actor-isolated; each segment between awaits matches
/// a synchronous JS segment.
public actor ParallelRequests<T: Sendable> {
    private enum WorkingState {
        case working, done, canceled
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
    private let requestCallback: @Sendable (Int, Int, Int, Bool) async throws -> (partial: Bool, cancel: Bool, payload: [T])
    private let responseCallback: @Sendable ([T]) throws -> Void
    private var endResult: Result<Void, Error>?
    private var endWaiter: CheckedContinuation<Void, Error>?
    /// The request loops. They share TS's abort signal: cancelling the manager cancels them all.
    private var requestTasks: [Task<Void, Never>] = []

    public init(from: Int, to: Int?, payloadSize: Int, requestCallback: @escaping @Sendable (Int, Int, Int, Bool) async throws -> (partial: Bool, cancel: Bool, payload: [T]), responseCallback: @escaping @Sendable ([T]) throws -> Void) {
        latestRequested = from
        nextToDeliver = from
        self.to = to
        knewTo = to != nil
        self.payloadSize = payloadSize
        self.requestCallback = requestCallback
        self.responseCallback = responseCallback
    }

    private var working: Bool { workingState == .working }
    public var canceled: Bool { workingState == .canceled }

    public func cancel() {
        if working {
            workingState = .canceled
            end(.success(()))
        }
        for task in requestTasks { task.cancel() }
    }

    public func run(_ concurrency: Int) async throws {
        guard concurrency > 0 else { throw JSONDecodingError("0x102") }
        guard working else { throw JSONDecodingError("0x103") }
        for _ in 0..<concurrency { addRequest() }
        // Recalculates and ends the run if there is nothing to fetch.
        try dispatch()
        if let endResult { return try endResult.get() }
        try await withCheckedThrowingContinuation { endWaiter = $0 }
    }

    private func end(_ result: Result<Void, Error>) {
        endResult = result
        endWaiter?.resume(with: result)
        endWaiter = nil
    }

    private func done() throws {
        guard let to else { throw JSONDecodingError("0x104") }
        guard nextToDeliver >= to else { throw JSONDecodingError("0x105") }
        if working {
            workingState = .done
            end(.success(()))
        }
    }

    private func fail(_ error: Error) {
        if working {
            workingState = .done
            end(.failure(error))
        }
    }

    private func dispatch() throws {
        while working, let value = results.removeValue(forKey: nextToDeliver) {
            guard value.count <= payloadSize else { throw JSONDecodingError("0x1d9") }
            nextToDeliver += value.count
            try responseCallback(value)
        }
        if working {
            if requestsInFlight == 0 {
                guard results.isEmpty else { throw JSONDecodingError("0x107") }
                try done()
            } else if let to, nextToDeliver >= to {
                guard !knewTo else { throw JSONDecodingError("0x108") }
                try done()
            }
        }
    }

    private func getNextChunk() throws -> (from: Int, to: Int)? {
        guard working else { return nil }
        let from = latestRequested
        if let to, to <= from { return nil }
        latestRequested += payloadSize
        if let to { latestRequested = min(to, latestRequested) }
        guard from < latestRequested else { throw JSONDecodingError("0x109") }
        return (from, latestRequested)
    }

    private func addRequest() {
        let chunk: (from: Int, to: Int)?
        do { chunk = try getNextChunk() }
        catch {
            fail(error)
            return
        }
        guard let chunk else { return }
        // The synchronous prefix of TS addRequestCore: the request is in flight before run() dispatches.
        guard working else {
            fail(JSONDecodingError("0x10a"))
            return
        }
        requestsInFlight += 1
        requestTasks.append(Task {
            do { try await self.addRequestCore(chunk.from, chunk.to) }
            catch { self.fail(error) }
        })
    }

    private func addRequestCore(_ fromArg: Int, _ toArg: Int) async throws {
        var from = fromArg
        var to = toArg
        while working {
            let requestedLength = to - from
            guard requestedLength > 0 else { throw JSONDecodingError("0x10b") }
            if let end = self.to {
                guard from < end else { throw JSONDecodingError("0x10c") }
                guard to <= end else { throw JSONDecodingError("0x10d") }
            }
            requests += 1
            let request = requests
            let strongTo = self.to != nil
            // TS starts the request and dispatches before awaiting it; delivery order is the same.
            try dispatch()
            let (partial, cancel, received) = try await requestCallback(request, from, to, strongTo)
            var payload = received
            if cancel { self.cancel() }
            if let end = self.to, from >= end {
                guard !knewTo else { throw JSONDecodingError("0x10e") }
                break
            }
            if working {
                let length = payload.count
                var fullChunk = requestedLength <= length
                if length == 0 {
                    guard !partial else { throw JSONDecodingError("0x10f") }
                    guard !knewTo else { throw JSONDecodingError("0x110") }
                } else {
                    let data = Array(payload.prefix(requestedLength))
                    payload.removeFirst(data.count)
                    results[from] = data
                    from += data.count
                }
                if !partial, !fullChunk {
                    if !knewTo {
                        if self.to == nil || self.to.map({ $0 > from }) == true { self.to = from }
                        break
                    }
                    // The service returned a partial chunk; continue with the rest of the range.
                }
                if to == latestRequested {
                    // The last outstanding chunk: keep any extra ops the service returned.
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
                    guard let chunk = try getNextChunk() else { break }
                    from = chunk.from
                    to = chunk.to
                }
            }
        }
        requestsInFlight -= 1
        try dispatch()
    }
}

/// getSingleOpBatch: retries retryable failures, and empty results when the end is known, until
/// ops arrive. 30 s of consecutive empty successes is a non-retryable failure. Task cancellation is
/// TS's abort signal (`while (signal?.aborted !== true)`): the loop stops and returns `nothing`.
public func getSingleOpBatch(strongTo: Bool, get: @Sendable () async throws -> (messages: [JSONValue], partialResult: Bool)) async throws -> (partial: Bool, cancel: Bool, payload: [JSONValue]) {
    var lastSuccessTime: Double?
    var waitTime = 50.0
    while !Task.isCancelled {
        var lastError: Error?
        do {
            let (messages, partialResult) = try await get()
            if !messages.isEmpty || !strongTo {
                return (partialResult, false, messages)
            }
            // The storage is lagging behind the ordering service: wait and try again.
            let now = Date().timeIntervalSince1970 * 1000
            if let lastSuccessTime {
                if now - lastSuccessTime > 30000 { throw NetworkError("Failed to retrieve ops from storage (Too Many Retries)", canRetry: false) }
            } else {
                lastSuccessTime = now
            }
        } catch {
            lastError = error
            guard canRetryOnError(error) else { throw error }
        }
        waitTime = calculateMaxWaitTime(waitTime, error: lastError)
        do { try await Task.sleep(for: .milliseconds(waitTime)) }
        catch { break }
    }
    return (false, true, [])
}

/// requestOps: an ordered stream of contiguous op batches for [fromTotal, toTotal). Ending the
/// stream's iteration aborts the fetch; as TS's abort listener does, that cancels the manager at once.
public func requestOps(concurrency: Int, fromTotal: Int, toTotal: Int?, payloadSize: Int, get: @escaping @Sendable (Int, Int) async throws -> (messages: [JSONValue], partialResult: Bool)) -> AsyncThrowingStream<[JSONValue], Error> {
    let (stream, continuation) = AsyncThrowingStream<[JSONValue], Error>.makeStream()
    let lastFetch = LastFetch()
    let manager = ParallelRequests<JSONValue>(from: fromTotal, to: toTotal, payloadSize: payloadSize, requestCallback: { _, from, to, strongTo in
        try await getSingleOpBatch(strongTo: strongTo) { try await get(from, to) }
    }, responseCallback: { deltas in
        try lastFetch.deliver(deltas, fromTotal: fromTotal)
        continuation.yield(deltas)
    })
    let task = Task {
        do {
            try await withTaskCancellationHandler {
                try await manager.run(concurrency)
            } onCancel: {
                Task { await manager.cancel() }
            }
            if await !manager.canceled {
                if let toTotal {
                    guard let last = lastFetch.value, last >= toTotal - 1 else { throw JSONDecodingError("0x270") }
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

/// The sequence-number cursor requestOps asserts against (0x26d, 0x26e, 0x26f).
private final class LastFetch: Sendable {
    private let state = Mutex<Int?>(nil)
    var value: Int? { state.withLock { $0 } }
    func deliver(_ deltas: [JSONValue], fromTotal: Int) throws {
        guard let firstDelta = deltas.first, let lastDelta = deltas.last else { throw JSONDecodingError("TypeError: Cannot read properties of undefined (reading 'sequenceNumber')") }
        let first = try firstDelta.member("sequenceNumber").asInt()
        let last = try lastDelta.member("sequenceNumber").asInt()
        try state.withLock { lastFetch in
            if let previous = lastFetch {
                guard first == previous + 1 else { throw JSONDecodingError("0x26e") }
            } else {
                guard first == fromTotal else { throw JSONDecodingError("0x26d") }
            }
            guard last - first + 1 == deltas.count else { throw JSONDecodingError("0x26f") }
            lastFetch = last
        }
    }
}
