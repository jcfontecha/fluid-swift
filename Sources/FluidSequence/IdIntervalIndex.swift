import FluidJS

/// Ports sequence/src/intervalIndex/idIntervalIndex.ts IdIntervalIndex.
/// JS Map iteration preserves insertion order even for numeric-looking IDs.
public final class IdIntervalIndex: Sequence, SequenceIntervalIndex {
  private var values: [JSString: SequenceInterval] = [:]
  private var order: [JSString] = []

  public init() {}

  public func add(_ interval: SequenceInterval) {
    if values.updateValue(interval, forKey: interval.id) == nil {
      order.append(interval.id)
    }
  }

  public func remove(_ interval: SequenceInterval) {
    if values.removeValue(forKey: interval.id) != nil {
      order.removeAll { $0 == interval.id }
    }
  }

  public func getIntervalById(_ id: JSString) -> SequenceInterval? { values[id] }

  public func makeIterator() -> IndexingIterator<[SequenceInterval]> {
    order.compactMap { values[$0] }.makeIterator()
  }
}
