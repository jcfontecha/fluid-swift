import FluidJS

/// Ports intervalIndex/sequenceIntervalEndSet.ts: end-position/ID ordering, ID-independent probes.
public final class SequenceIntervalEndSet {
  private var intervals: [SequenceInterval] = []
  public init() {}

  private func compare(_ lhs: SequenceInterval, _ rhs: SequenceInterval) -> Int {
    let end = lhs.compareEnd(rhs)
    if end != 0 { return end }
    if lhs.id == rhs.id { return 0 }
    return lhs.id.utf16.lexicographicallyPrecedes(rhs.id.utf16) ? -1 : 1
  }
  public func addOrUpdate(_ interval: SequenceInterval) {
    let index = intervalLowerBound(intervals) { compare($0, interval) >= 0 }
    if index < intervals.count && compare(intervals[index], interval) == 0 { intervals[index] = interval }
    else { intervals.insert(interval, at: index) }
  }
  public func remove(_ interval: SequenceInterval) {
    let index = intervalLowerBound(intervals) { compare($0, interval) >= 0 }
    if index < intervals.count && compare(intervals[index], interval) == 0 { intervals.remove(at: index) }
  }
  public func lastAtOrBefore(_ query: BaseSequenceInterval) -> SequenceInterval? {
    let index = intervalLowerBound(intervals) { $0.compareEnd(query) > 0 }
    return index > 0 ? intervals[index - 1] : nil
  }
  public func firstAtOrAfter(_ query: BaseSequenceInterval) -> SequenceInterval? {
    let index = intervalLowerBound(intervals) { $0.compareEnd(query) >= 0 }
    return index < intervals.count ? intervals[index] : nil
  }
}
