/// Ports mergeTreeTracking.ts TrackingGroup: identity-based retention of segments.
public final class TrackingGroup {
  public private(set) var segments: [BaseSegment] = []
  public private(set) var references: [LocalReference] = []
  public init() {}
  public var size: Int { segments.count + references.count }
  public func has(_ segment: BaseSegment) -> Bool { segments.contains { $0 === segment } }
  public func has(_ reference: LocalReference) -> Bool { references.contains { $0 === reference } }
  public func link(_ reference: LocalReference) {
    guard !has(reference) else { return }
    references.append(reference)
    reference.trackingCollection.add(self)
  }
  public func unlink(_ reference: LocalReference) {
    references.removeAll { $0 === reference }
    reference.trackingCollection.remove(self)
  }
  public func link(_ segment: BaseSegment) {
    guard !segments.contains(where: { $0 === segment }) else { return }
    segments.append(segment)
    segment.trackingCollection.add(self)
  }
  public func unlink(_ segment: BaseSegment) {
    segments.removeAll { $0 === segment }
    segment.trackingCollection.remove(self)
  }
}

/// Ports mergeTreeTracking.ts TrackingGroupCollection. Groups own their tracked
/// segments; back-links are weak to avoid an ARC ownership cycle.
public final class TrackingGroupCollection {
  private struct Link { weak var group: TrackingGroup? }
  private var links: [Link] = []
  var groups: [TrackingGroup] { links.compactMap(\.group) }
  public var empty: Bool { groups.isEmpty }
  func add(_ group: TrackingGroup) { links.append(Link(group: group)) }
  func remove(_ group: TrackingGroup) { links.removeAll { $0.group == nil || $0.group === group } }
  func matches(_ other: TrackingGroupCollection) -> Bool {
    let lhs = groups
    let rhs = other.groups
    return lhs.count == rhs.count && lhs.allSatisfy { group in rhs.contains { $0 === group } }
  }
  func unlinkAll(_ segment: BaseSegment) {
    for group in groups { group.unlink(segment) }
  }
}
