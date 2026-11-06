import FluidMergeTree

/// Ports intervalIndex/sequenceIntervalOverlapSet.ts: sorted intervals with a lazy max-end segment tree.
public final class SequenceIntervalOverlapSet {
  public private(set) var intervals: [SequenceInterval] = []
  private var maxEnds: [Int] = [-1, -1]
  public init() {}
  public var isEmpty: Bool { intervals.isEmpty }

  private func locate(_ interval: SequenceInterval) -> (index: Int, exists: Bool) {
    let index = intervalLowerBound(intervals) { $0.compare(interval) >= 0 }
    return (index, index < intervals.count && intervals[index].compare(interval) == 0 && intervals[index].id == interval.id)
  }

  public func add(_ interval: SequenceInterval) {
    let position = locate(interval)
    guard !position.exists else { return }
    intervals.insert(interval, at: position.index)
    maxEnds[1] = -1
  }

  public func remove(_ interval: SequenceInterval) {
    let position = locate(interval)
    guard position.exists else { return }
    intervals.remove(at: position.index)
    if intervals.isEmpty { maxEnds = [-1, -1] }
    else { maxEnds[1] = -1 }
  }

  @discardableResult
  private func build(_ node: Int, _ lower: Int, _ upper: Int) -> Int {
    let greatest: Int
    if upper - lower == 1 { greatest = lower }
    else {
      let middle = lower + (upper - lower) / 2
      let left = build(node * 2, lower, middle)
      let right = build(node * 2 + 1, middle, upper)
      greatest = compareReferencePositions(intervals[left].end, intervals[right].end) >= 0 ? left : right
    }
    maxEnds[node] = greatest
    return greatest
  }

  public func findOverlapping(_ query: BaseSequenceInterval) -> [SequenceInterval] {
    let limit = intervalLowerBound(intervals) { compareReferencePositions($0.start, query.end) > 0 }
    guard limit > 0 else { return [] }
    if maxEnds[1] == -1 {
      if maxEnds.count != intervals.count * 4 { maxEnds = Array(repeating: -1, count: intervals.count * 4) }
      build(1, 0, intervals.count)
    }
    var results: [SequenceInterval] = []
    func gather(_ node: Int, _ lower: Int, _ upper: Int) {
      guard lower < limit, compareReferencePositions(intervals[maxEnds[node]].end, query.start) >= 0 else { return }
      if upper - lower == 1 { results.append(intervals[lower]) }
      else {
        let middle = lower + (upper - lower) / 2
        gather(node * 2, lower, middle)
        gather(node * 2 + 1, middle, upper)
      }
    }
    gather(1, 0, intervals.count)
    return results
  }

  private func equalRange(_ query: BaseSequenceInterval, compare: (SequenceInterval, BaseSequenceInterval) -> Int) -> [SequenceInterval] {
    let lower = intervalLowerBound(intervals) { compare($0, query) >= 0 }
    let upper = intervalLowerBound(intervals) { compare($0, query) > 0 }
    return Array(intervals[lower..<upper])
  }
  public func withSameStart(_ query: BaseSequenceInterval) -> [SequenceInterval] { equalRange(query) { $0.compareStart($1) } }
  public func withSameEnd(_ query: BaseSequenceInterval) -> [SequenceInterval] { intervals.filter { $0.compareEnd(query) == 0 } }
  public func withSameEndpoints(_ query: BaseSequenceInterval) -> [SequenceInterval] {
    equalRange(query) { left, right in
      let start = left.compareStart(right)
      return start == 0 ? left.compareEnd(right) : start
    }
  }
}
