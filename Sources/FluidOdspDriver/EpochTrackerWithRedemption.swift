import FluidJS
import Foundation
import Synchronization

/// TS `Deferred<void>` behind treesLatestDeferral. Completion is synchronous, so the synchronous
/// epoch validation can complete it as TS validateEpochFromResponse does.
private final class RedemptionDeferral: Sendable {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let timer: Task<Void, Never>
    }
    private struct State {
        var result: Result<Void, Error>?
        var waiters: [UUID: Waiter] = [:]
    }
    private let state = Mutex(State())
    var isCompleted: Bool {
        state.withLock { $0.result != nil }
    }
    func complete(_ result: Result<Void, Error>) {
        let pending = state.withLock { state -> [Waiter] in
            guard state.result == nil else { return [] }
            state.result = result
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in pending {
            waiter.timer.cancel()
            waiter.continuation.resume(with: result)
        }
    }
    func wait(sleep: @escaping @Sendable (Double) async throws -> Void) async throws {
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            let completed = state.withLock { state -> Result<Void, Error>? in
                if let result = state.result { return result }
                let timer = Task {
                    do { try await sleep(15000) } catch { return }
                    self.timeout(id)
                }
                state.waiters[id] = Waiter(continuation: continuation, timer: timer)
                return nil
            }
            if let completed { continuation.resume(with: completed) }
        }
    }
    private func timeout(_ id: UUID) {
        state.withLock { $0.waiters.removeValue(forKey: id) }?.continuation.resume()
    }
}

/// epochTracker.ts EpochTrackerWithRedemption. First join failure waits for access discovery or 15 s.
public final class EpochTrackerWithRedemption: EpochTracker, @unchecked Sendable {
    private let treesLatestDeferral = RedemptionDeferral()
    private let sleep: @Sendable (Double) async throws -> Void
    public init(clientIsSummarizer: Bool = false, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, cacheGet: (@Sendable (Entry) async throws -> JSONValue?)? = nil, cachePut: (@Sendable (Entry, JSONValue) async throws -> Void)? = nil, cacheRemove: (@Sendable () async throws -> Void)? = nil, sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) }) {
        self.sleep = sleep
        super.init(clientIsSummarizer: clientIsSummarizer, now: now, cacheGet: cacheGet, cachePut: cachePut, cacheRemove: cacheRemove)
    }
    /// TS validateEpochFromResponse override: any validated epoch, from a response or from a cached
    /// snapshot, means the file is accessible, so any required redemption already happened.
    public override func validateEpoch(_ epoch: String?) throws {
        try super.validateEpoch(epoch)
        treesLatestDeferral.complete(.success(()))
    }
    nonisolated(nonsending) public override func get(_ entry: Entry) async -> JSONValue? {
        let result = await super.get(entry)
        if result != nil, entry.type == "snapshot" || entry.type == "snapshotWithLoadingGroupId" {
            treesLatestDeferral.complete(.success(()))
        }
        return result
    }
    nonisolated(nonsending) public override func fetch<T>(type: OdspFetchType, call: () async throws -> T) async throws -> T {
        let wasCompleted = treesLatestDeferral.isCompleted
        do {
            let result = try await super.fetch(type: type, call: call)
            treesLatestDeferral.complete(.success(()))
            return result
        } catch {
            if type == .treesLatest {
                treesLatestDeferral.complete(.failure(error))
            }
            let status = (error as? OdspNetworkError)?.statusCode
            let redemptionStatus = status.map { (401...404).contains($0) } ?? true
            guard type == .joinSession, !wasCompleted, redemptionStatus else { throw error }
        }
        try await treesLatestDeferral.wait(sleep: sleep)
        let result = try await super.fetch(type: type, call: call)
        treesLatestDeferral.complete(.success(()))
        return result
    }
}
