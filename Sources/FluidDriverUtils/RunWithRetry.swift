/// Ports driver-utils/src/runWithRetry.ts. The injected delay is the I/O-edge clock; tests use
/// virtual time. Unknown errors are not retryable, and the first retry waits at least 1000 ms.
public typealias RetrySleep = @Sendable (Double) async throws -> Void

public func retrySleep(_ milliseconds: Double) async throws {
    try await Task.sleep(for: .milliseconds(max(0, milliseconds)))
}

public func calculateMaxWaitTime(_ delayMs: Double, error: (any Error)?) -> Double {
    min(max(getRetryDelayFromError(error) ?? 0, delayMs * 2),
        (error as? any RetryableError)?.endpointReached == true ? 60000 : 8000)
}

public nonisolated(nonsending) func runWithRetry<T>(
    _ api: () async throws -> T,
    maxRetries: Int? = nil,
    onRetry: (Double, any Error) throws -> Void = { _, _ in },
    sleep: RetrySleep = retrySleep
) async throws -> T {
    var retryAfterMs = 500.0
    var numRetries = 0
    while true {
        do {
            return try await api()
        } catch {
            guard canRetryOnError(error) else { throw error }
            try Task.checkCancellation()
            numRetries += 1
            if let maxRetries, numRetries > maxRetries {
                throw NetworkError("runWithRetry failed after max retries: \(error)", canRetry: false)
            }
            retryAfterMs = calculateMaxWaitTime(retryAfterMs, error: error)
            try onRetry(retryAfterMs, error)
            try await sleep(retryAfterMs)
        }
    }
}
