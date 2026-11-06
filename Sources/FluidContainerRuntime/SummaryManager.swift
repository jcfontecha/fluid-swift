import FluidJS

/// Ports summary/summaryManager.ts. Container owns creation/close I/O and drives these
/// transitions on its executor; generation guards prevent late cleanup closing a new child.
public final class SummaryManager {
    public enum Mode: Sendable {
        case enabled
        case disabled
        case disableHeuristics
        case summaryOnRequest
    }
    public enum State: String { case off, starting, running, stopping }
    public private(set) var state = State.off
    public private(set) var generation = 0
    public private(set) var pendingStopReason: String?
    public private(set) var startDeadline: Double?
    public private(set) var stopDeadline: Double?
    private let startThrottler = Throttler()
    public private(set) var startWithInitialDelay = false
    public let initialDelayMs: Double
    public init(initialDelayMs: Double = 5000) { self.initialDelayMs = initialDelayMs }
    public func shouldSummarize(clientId: JSString?, connected: Bool, election: SummarizerClientElection) -> Bool {
        connected && clientId != nil && clientId == election.electedParentId &&
            (state == .running || clientId == election.electedClientId)
    }
    public func refresh(clientId: JSString?, connected: Bool, election: SummarizerClientElection, now: Double, opsSinceLastAck: Int) {
        let wasStarting = state == .starting
        let eligible = shouldSummarize(clientId: clientId, connected: connected, election: election)
        if state == .off && eligible {
            state = .starting
            startWithInitialDelay = opsSinceLastAck < 4000
            startDeadline = now + max(startThrottler.getDelay(now: now), startWithInitialDelay ? initialDelayMs : 0)
        } else if state == .running && !eligible {
            stop(reason: !connected ? "parentNotConnected" : "notElectedParent", now: now)
        }
        if wasStarting && state == .starting && opsSinceLastAck >= 4000 { startDeadline = now }
    }
    public func beginCreation(now: Double) -> Int? {
        guard state == .starting, let startDeadline, now >= startDeadline else { return nil }
        state = .running
        self.startDeadline = nil
        return generation
    }
    public func stop(reason: String, now: Double) {
        guard state == .starting || state == .running else { return }
        state = .stopping
        pendingStopReason = reason
        stopDeadline = now + 120000
    }
    public func cleanup(generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        self.generation += 1
        state = .off
        pendingStopReason = nil
        startDeadline = nil
        stopDeadline = nil
        return true
    }
}
