import FluidJS

/// Ports summary/summarizerNode/summarizerNode.ts change tracking. A reverted edit is still dirty.
public final class SummarizerNode {
    private var changeNumber = 0
    private var acknowledgedChangeNumber = 0
    private var pendingChangeNumber: Int?
    public var hasChanged: Bool { changeNumber != acknowledgedChangeNumber }
    public init() {}
    public func recordChange() { changeNumber += 1 }
    public func trackSummary() { pendingChangeNumber = changeNumber }
    public func refreshLatestSummary() {
        if let pendingChangeNumber { acknowledgedChangeNumber = pendingChangeNumber }
        pendingChangeNumber = nil
    }
}
