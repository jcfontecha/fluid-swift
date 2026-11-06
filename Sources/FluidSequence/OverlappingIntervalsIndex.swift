import FluidMergeTree
import FluidJS

/// Ports intervalIndex/overlappingIntervalsIndex.ts OverlappingIntervalsIndex.
public final class OverlappingIntervalsIndex: SequenceIntervalIndex {
  private weak var sequence: SharedSegmentSequence?
  private let intervalSet = SequenceIntervalOverlapSet()
  public init(sequence: SharedSegmentSequence) { self.sequence = sequence }
  public func add(_ interval: SequenceInterval) { intervalSet.add(interval) }
  public func remove(_ interval: SequenceInterval) { intervalSet.remove(interval) }

  public func findOverlappingIntervals(start: Int, end: Int) throws -> [SequenceInterval] {
    try findOverlappingIntervals(start: SequencePlace(start), end: SequencePlace(end))
  }
  public func findOverlappingIntervals(start: SequencePlace, end: SequencePlace) throws -> [SequenceInterval] {
    if case .position(let lower) = start.position, case .position(let upper) = end.position, upper < lower { return [] }
    if start.position == .end && end.position != .end { return [] }
    if start.position != .start && end.position == .start { return [] }
    guard !intervalSet.isEmpty else { return [] }
    guard let sequence else { throw JSONDecodingError("index sequence no longer exists") }
    return try intervalSet.findOverlapping(createTransientIntervalFromSequence(sequence, start: start, end: end))
  }
  public func gatherIterationResults(_ results: inout [SequenceInterval], forward: Bool,
    start: SequencePlace? = nil, end: SequencePlace? = nil) throws {
    let matches: [SequenceInterval]
    if start == nil && end == nil { matches = intervalSet.intervals }
    else {
      guard let sequence else { throw JSONDecodingError("index sequence no longer exists") }
      let query = try createTransientIntervalFromSequence(sequence, start: start ?? .start, end: end ?? .end)
      if start == nil { matches = intervalSet.withSameEnd(query) }
      else if end == nil { matches = intervalSet.withSameStart(query) }
      else { matches = intervalSet.withSameEndpoints(query) }
    }
    if forward { results.append(contentsOf: matches) }
    else { results.append(contentsOf: matches.reversed()) }
  }
}
