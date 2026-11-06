import FluidJS

/// Ports mergeTreeNodes.ts SegmentGroup: ordered identities affected by one
/// pending edit. Split halves append to the group, not to physical document order.
final class SegmentGroup {
  let localSequence: Int
  let operation: JSONValue
  var segments: [BaseSegment] = []
  init(localSequence: Int, operation: JSONValue) {
    self.localSequence = localSequence
    self.operation = operation
  }
  func link(_ segment: BaseSegment) {
    segments.append(segment)
    segment.pendingGroups.append(self)
  }
  func unlink(_ segment: BaseSegment) {
    segment.pendingGroups.removeAll { $0 === self }
  }
}
