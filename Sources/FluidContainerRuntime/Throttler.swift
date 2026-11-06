import Foundation

/// Ports container-runtime/src/throttler.ts with the summarizer's configured exponential delay.
public final class Throttler {
    private var startTimes: [Double] = []
    public let delayWindowMs: Double = 60000
    public let maxDelayMs: Double = 30000
    public var numAttempts: Int { startTimes.count }
    public init() {}
    public func getDelay(now: Double) -> Double {
        if let latest = startTimes.last, latest > now {
            let early = latest - now
            startTimes = startTimes.map { $0 - early }
        }
        startTimes.removeAll { now - $0 >= delayWindowMs }
        let delay = min(startTimes.isEmpty ? 0 : 20 * pow(2, Double(startTimes.count)), maxDelayMs)
        startTimes.append(now)
        startTimes = startTimes.map { $0 + delay }
        if delay == maxDelayMs { startTimes.removeFirst() }
        return delay
    }
}
