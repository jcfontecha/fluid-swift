import FluidDriverUtils
import FluidJS
import Synchronization
import Testing

private final class VirtualClock: Sendable {
    let delays = Mutex<[Double]>([])
    func sleep(_ milliseconds: Double) async throws {
        delays.withLock { $0.append(milliseconds) }
    }
}

struct RetryTests {
    // driver-utils/runWithRetry.ts: starts at 500, doubles before the first retry.
    @Test func retryBackoffAndLimit() async throws {
        let clock = VirtualClock()
        let attempts = Mutex(0)
        let result = try await runWithRetry({
            let attempt = attempts.withLock { value in
                value += 1
                return value
            }
            if attempt < 6 { throw NetworkError("offline", canRetry: true) }
            return 42
        }, sleep: clock.sleep)
        #expect(result == 42)
        #expect(clock.delays.withLock { $0 } == [1000, 2000, 4000, 8000, 8000])
        await #expect(throws: (any Error).self) {
            try await runWithRetry({ throw NetworkError("offline", canRetry: true) }, maxRetries: 0, sleep: clock.sleep)
        }
        #expect(clock.delays.withLock { $0.count } == 5)
    }

    @Test func endpointAndRetryAfter() {
        let throttle = NetworkError("429", canRetry: true, retryAfterSeconds: 120, endpointReached: true)
        #expect(getRetryDelayFromError(throttle) == 120000)
        #expect(calculateMaxWaitTime(500, error: throttle) == 60000)
        #expect(calculateMaxWaitTime(500, error: NetworkError("offline", canRetry: true, retryAfterSeconds: 120)) == 8000)
        #expect(!canRetryOnError(JSONDecodingError("unknown")))
        #expect(!canRetryOnError(NetworkError("fatal", canRetry: false)))
    }
}
