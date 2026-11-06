/// Ports summary/summaryDelayLoadedModule/summarizerHeuristics.ts. Clock values are milliseconds.
public final class SummarizeHeuristicData {
    public struct Attempt {
        public let refSequenceNumber: Int
        public let summaryTime: Double
    }
    public var lastOpSequenceNumber: Int
    public private(set) var lastAttempt: Attempt
    public private(set) var lastSuccessfulSummary: Attempt
    public var numRuntimeOps = 0
    public var numNonRuntimeOps = 0
    public var totalOpsSize = 0
    public var hasMissingOpData = false
    private var runtimeBefore = 0
    private var nonRuntimeBefore = 0
    private var sizeBefore = 0
    public var opsSinceLastSummary: Int { runtimeBefore + nonRuntimeBefore }

    public init(lastOpSequenceNumber: Int, summaryTime: Double) {
        self.lastOpSequenceNumber = lastOpSequenceNumber
        lastAttempt = Attempt(refSequenceNumber: lastOpSequenceNumber, summaryTime: summaryTime)
        lastSuccessfulSummary = lastAttempt
    }
    public func updateWithLastSummaryAckInfo(_ attempt: Attempt) {
        lastAttempt = attempt
        lastSuccessfulSummary = attempt
    }
    public func recordAttempt(now: Double, refSequenceNumber: Int? = nil) {
        lastAttempt = Attempt(refSequenceNumber: refSequenceNumber ?? lastOpSequenceNumber, summaryTime: now)
        runtimeBefore = numRuntimeOps
        nonRuntimeBefore = numNonRuntimeOps
        sizeBefore = totalOpsSize
    }
    public func markLastAttemptAsSuccessful() {
        lastSuccessfulSummary = lastAttempt
        numRuntimeOps -= runtimeBefore
        numNonRuntimeOps -= nonRuntimeBefore
        totalOpsSize -= sizeBefore
        runtimeBefore = 0
        nonRuntimeBefore = 0
        sizeBefore = 0
        hasMissingOpData = false
    }
}

/// Ports summaryHelpers.ts DefaultSummaryConfiguration and summarizerHeuristics.ts runner.
/// The container owns timer scheduling; this synchronous runner owns the timing decisions.
public final class SummarizeHeuristicRunner {
    public struct Configuration {
        public var minIdleTime: Double = 0
        public var maxIdleTime: Double = 30000
        public var maxTime: Double = 60000
        public var maxOps: Double = 100
        public var minOpsForLastSummaryAttempt: Double = 10
        public var maxAckWaitTime: Double = 180000
        public var runtimeOpWeight: Double = 1
        public var nonRuntimeOpWeight: Double = 0.1
        public init() {}
    }
    public let data: SummarizeHeuristicData
    public let configuration: Configuration
    public private(set) var idleDeadline: Double?
    public init(data: SummarizeHeuristicData, configuration: Configuration = Configuration()) {
        self.data = data
        self.configuration = configuration
    }
    private var weightedOps: Double {
        Double(data.numRuntimeOps) * configuration.runtimeOpWeight + Double(data.numNonRuntimeOps) * configuration.nonRuntimeOpWeight
    }
    public var idleTime: Double {
        let ratio = weightedOps / configuration.maxOps
        return ratio >= 1 ? configuration.minIdleTime : configuration.maxIdleTime - (configuration.maxIdleTime - configuration.minIdleTime) * ratio
    }
    public var opsSinceLastAck: Int { data.lastOpSequenceNumber - data.lastSuccessfulSummary.refSequenceNumber }
    public func start(now: Double) { idleDeadline = now + idleTime }
    public func run(now: Double) -> String? {
        if now - data.lastSuccessfulSummary.summaryTime > configuration.maxTime {
            return trigger("maxTime")
        }
        if weightedOps > configuration.maxOps { return trigger("maxOps") }
        start(now: now)
        return nil
    }
    public func timerFired(now: Double) -> String? {
        guard let idleDeadline, now >= idleDeadline else { return nil }
        return trigger("idle")
    }
    private func trigger(_ reason: String) -> String? {
        idleDeadline = nil
        return opsSinceLastAck > 0 ? reason : nil
    }
    public func shouldRunLastSummary() -> Bool { weightedOps >= configuration.minOpsForLastSummaryAttempt }
    public func dispose() { idleDeadline = nil }
}
