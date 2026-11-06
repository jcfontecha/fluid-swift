import Foundation

/// driver-utils/src/rateLimiter.ts. FIFO slots limit transport work, not response validation.
public actor RateLimiter {
    private let maximum: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    public init(_ maximum: Int) {
        precondition(maximum > 0)
        self.maximum = maximum
    }
    public func acquire() async {
        if running < maximum {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }
    public func release() {
        if !waiting.isEmpty { waiting.removeFirst().resume() }
        else { running -= 1 }
    }
}
