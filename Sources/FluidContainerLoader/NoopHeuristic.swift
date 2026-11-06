import FluidDriverDefinitions

/// Ports container-loader/src/noopHeuristic.ts. The timer itself lives at Container's async edge.
public struct NoopHeuristic {
    public var noopCountFrequency = 50.0
    public var noopTimeFrequency = 2000.0
    public private(set) var opsProcessedSinceOpSent = 0

    private var countCheckScheduled = false

    public init() {}
    public mutating func notifyMessageProcessed(_ message: ISequencedDocumentMessage) {
        guard message.type == "op" else { return }
        opsProcessedSinceOpSent += 1
        if Double(opsProcessedSinceOpSent) == noopCountFrequency { countCheckScheduled = true }
    }
    public mutating func notifyMessageSent() { opsProcessedSinceOpSent = 0 }
    public mutating func notifyDisconnect() { opsProcessedSinceOpSent = 0 }
    /// Mirrors noopHeuristic.ts's end-of-drain microtask (assert 0x243).
    public mutating func takeWantsNoop() -> Bool {
        defer { countCheckScheduled = false }
        return countCheckScheduled && Double(opsProcessedSinceOpSent) >= noopCountFrequency
            && opsProcessedSinceOpSent > 0
    }
}
