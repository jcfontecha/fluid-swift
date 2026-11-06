import FluidJS
import Foundation

private actor RedemptionDeferral {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let timer: Task<Void, Never>
    }
    private var result: Result<Void, Error>?
    private var waiters: [UUID: Waiter] = [:]
    func complete(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            waiter.timer.cancel()
            waiter.continuation.resume(with: result)
        }
    }
    func wait(sleep: @escaping @Sendable (Double) async throws -> Void) async throws {
        if let result { return try result.get() }
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            let timer = Task {
                do { try await sleep(15000) } catch { return }
                self.timeout(id)
            }
            waiters[id] = Waiter(continuation: continuation, timer: timer)
        }
    }
    private func timeout(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }
}

/// epochTracker.ts EpochTrackerWithRedemption. First join failure waits for access discovery or 15 s.
public final class EpochTrackerWithRedemption: EpochTracker {
    private let treesLatestDeferral = RedemptionDeferral()
    private var completed = false
    private let sleep: @Sendable (Double) async throws -> Void
    public init(now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }, cacheGet: ((Entry) async throws -> JSONValue?)? = nil, cachePut: ((Entry, JSONValue) async throws -> Void)? = nil, cacheRemove: (() async throws -> Void)? = nil, sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) }) {
        self.sleep = sleep
        super.init(now: now, cacheGet: cacheGet, cachePut: cachePut, cacheRemove: cacheRemove)
    }
    nonisolated(nonsending) public override func get(_ entry: Entry) async -> JSONValue? {
        let result = await super.get(entry)
        if result != nil, entry.type == "snapshot" || entry.type == "snapshotWithLoadingGroupId" {
            completed = true
            await treesLatestDeferral.complete(.success(()))
        }
        return result
    }
    nonisolated(nonsending) public override func fetch<T>(type: OdspFetchType, call: () async throws -> T) async throws -> T {
        let wasCompleted = completed
        do {
            let result = try await super.fetch(type: type, call: call)
            completed = true
            await treesLatestDeferral.complete(.success(()))
            return result
        } catch {
            if type == .treesLatest {
                completed = true
                await treesLatestDeferral.complete(.failure(error))
            }
            let status = (error as? OdspNetworkError)?.statusCode
            let redemptionStatus = status.map { (401...404).contains($0) } ?? true
            guard type == .joinSession, !wasCompleted, redemptionStatus else { throw error }
        }
        try await treesLatestDeferral.wait(sleep: sleep)
        let result = try await super.fetch(type: type, call: call)
        completed = true
        await treesLatestDeferral.complete(.success(()))
        return result
    }
}
