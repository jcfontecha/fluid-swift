import FluidMergeTree
import FluidJS

/// Ports intervalIndex/endpointIndex.ts EndpointIndex.
public final class EndpointIndex: SequenceIntervalIndex {
  private weak var sequence: SharedSegmentSequence?
  private let intervals = SequenceIntervalEndSet()
  public init(sequence: SharedSegmentSequence) { self.sequence = sequence }
  public func add(_ interval: SequenceInterval) { intervals.addOrUpdate(interval) }
  public func remove(_ interval: SequenceInterval) { intervals.remove(interval) }
  public func previousInterval(_ position: Int) throws -> SequenceInterval? {
    guard let sequence else { throw JSONDecodingError("index sequence no longer exists") }
    return try intervals.lastAtOrBefore(createTransientIntervalFromSequence(sequence, start: SequencePlace(position), end: SequencePlace(position)))
  }
  public func nextInterval(_ position: Int) throws -> SequenceInterval? {
    guard let sequence else { throw JSONDecodingError("index sequence no longer exists") }
    return try intervals.firstAtOrAfter(createTransientIntervalFromSequence(sequence, start: SequencePlace(position), end: SequencePlace(position)))
  }
}
