import FluidDriverDefinitions
import FluidJS

/// Ports summary/summaryDelayLoadedModule/runningSummarizer.ts synchronous scheduling.
public final class RunningSummarizer {
    public let heuristicData: SummarizeHeuristicData
    public let heuristicRunner: SummarizeHeuristicRunner
    public private(set) var summarizing = false
    public private(set) var stopping = false
    private var heuristicsPending = false
    public init(sequenceNumber: Int, now: Double) {
        heuristicData = SummarizeHeuristicData(lastOpSequenceNumber: sequenceNumber, summaryTime: now)
        heuristicRunner = SummarizeHeuristicRunner(data: heuristicData)
        heuristicRunner.start(now: now)
    }
    public func process(_ message: ISequencedDocumentMessage, now: Double) -> String? {
        heuristicData.lastOpSequenceNumber = message.sequenceNumber
        if message.type == "op" { heuristicData.numRuntimeOps += 1 }
        else { heuristicData.numNonRuntimeOps += 1 }
        if let contents = message.contents { heuristicData.totalOpsSize += JSON.stringify(contents).utf16.count }
        guard !stopping,
            message.type != "summarize", message.type != "summaryAck", message.type != "summaryNack",
            message.type == "op" || heuristicRunner.opsSinceLastAck >= 20 else { return nil }
        if summarizing {
            heuristicsPending = true
            return nil
        }
        return heuristicRunner.run(now: now)
    }
    public func runAfterSummary(now: Double) -> String? {
        guard heuristicsPending, !summarizing, !stopping else { return nil }
        heuristicsPending = false
        return heuristicRunner.run(now: now)
    }
    public func begin(now: Double, referenceSequenceNumber: Int) throws {
        guard !summarizing else { throw JSONDecodingError("summary already running") }
        summarizing = true
        heuristicData.recordAttempt(now: now, refSequenceNumber: referenceSequenceNumber)
    }
    public func complete(acknowledged: Bool) {
        if acknowledged { heuristicData.markLastAttemptAsSuccessful() }
        summarizing = false
    }
    public func stop() -> Bool {
        stopping = true
        heuristicRunner.dispose()
        return !summarizing && heuristicRunner.shouldRunLastSummary()
    }
}

/// Ports summary/summaryDelayLoadedModule/summarizer.ts ownership of the running worker.
public final class Summarizer {
    public let runningSummarizer: RunningSummarizer
    public let parentClientId: JSString
    public private(set) var stopReason: String?
    public init(parentClientId: JSString, sequenceNumber: Int, now: Double) {
        self.parentClientId = parentClientId
        runningSummarizer = RunningSummarizer(sequenceNumber: sequenceNumber, now: now)
    }
    public func stop(_ reason: String) -> Bool {
        stopReason = reason
        return runningSummarizer.stop()
    }
}
