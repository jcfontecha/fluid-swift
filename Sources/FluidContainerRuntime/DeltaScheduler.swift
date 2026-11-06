/// Ports deltaScheduler.ts. During a run of inbound ops, the scheduler pauses the inbound queue
/// from its `batchEnd` handler once the run has taken longer than `processingTime` and more ops are
/// queued. The queue resumes on a later turn, so the owner's other work (input, rendering, local
/// edits) runs between runtime batches and never inside one.
///
/// ARCHITECTURE.md section 2 sets a fixed 4 ms slice for every owner. TS starts at 50 ms and adds
/// 10 ms per turn. The container's event loop feeds this from the runtime's `batchBegin` and
/// `batchEnd` events and owns the pause and resume. The lockstep harness peers call the runtime
/// directly, so they never run it.
public final class DeltaScheduler {
    /// deltaScheduler.ts `processingTime`.
    public static let processingTime = Duration.milliseconds(4)

    private let clock = ContinuousClock()
    /// deltaManager.ts `inbound.length`: ops still queued after the one being processed.
    private let inboundLength: () -> Int
    private var processingStartTime: ContinuousClock.Instant?
    /// deltaQueue.ts `pause()`: set at a batch end, cleared by `resume()`.
    public private(set) var paused = false

    public init(inboundLength: @escaping () -> Int) {
        self.inboundLength = inboundLength
    }

    public func batchBegin() {
        if processingStartTime == nil {
            processingStartTime = clock.now
        }
    }

    public func batchEnd() {
        // shouldRunScheduler: only when more ops are queued after this one.
        guard inboundLength() > 0, let processingStartTime else { return }
        guard clock.now - processingStartTime > Self.processingTime else { return }
        paused = true
        self.processingStartTime = nil
    }

    /// The later turn's `inbound.resume()`.
    public func resume() {
        paused = false
    }

    /// deltaScheduler.ts `inboundQueueIdle`: the run is over.
    public func inboundQueueIdle() {
        processingStartTime = nil
    }
}
