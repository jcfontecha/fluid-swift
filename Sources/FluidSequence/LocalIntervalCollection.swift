import FluidJS
import FluidMergeTree

/// Ports intervalCollection.ts LocalIntervalCollection. Owns indexing and paired slide listeners.
public final class LocalIntervalCollection: Sequence {
  public let idIntervalIndex = IdIntervalIndex()
  private var slidingIntervals: [JSString: SequenceInterval] = [:]
  public var onPositionChange: ((SequenceInterval, SequenceInterval) -> Void)?

  private var indexes: [any SequenceIntervalIndex] = []
  public init() { indexes = [idIntervalIndex] }

  public func attachIndex(_ index: any SequenceIntervalIndex) {
    guard !indexes.contains(where: { $0 === index }) else { return }
    for interval in idIntervalIndex { index.add(interval) }
    indexes.append(index)
  }

  public func detachIndex(_ index: any SequenceIntervalIndex) -> Bool {
    guard let position = indexes.firstIndex(where: { $0 === index }) else { return false }
    indexes.remove(at: position)
    for interval in idIntervalIndex { index.remove(interval) }
    return true
  }

  private func addToIndexes(_ interval: SequenceInterval) {
    for index in indexes { index.add(interval) }
  }
  private func removeFromIndexes(_ interval: SequenceInterval) {
    for index in indexes { index.remove(interval) }
  }

  public func getIntervalById(_ id: JSString) -> SequenceInterval? { idIntervalIndex.getIntervalById(id) }
  public func makeIterator() -> IndexingIterator<[SequenceInterval]> { idIntervalIndex.makeIterator() }

  public func add(_ interval: SequenceInterval) {
    addToIndexes(interval)
    addIntervalListeners(interval)
  }

  public func removeExistingInterval(_ interval: SequenceInterval) {
    removeFromIndexes(interval)
    removeIntervalListeners(interval)
  }

  func removeIntervalListeners(_ interval: SequenceInterval) {
    interval.start.beforeSlide = nil
    interval.start.afterSlide = nil
    interval.end.beforeSlide = nil
    interval.end.afterSlide = nil
  }

  func addIntervalListeners(_ interval: SequenceInterval) {
    var depth = 0
    var previous: SequenceInterval?
    let before: (LocalReference) -> Void = { [weak self, weak interval] _ in
      guard let self, let interval else { return }
      if depth == 0 {
        previous = interval.cloneForEvent()
        self.slidingIntervals[interval.id] = interval
        self.removeFromIndexes(interval)
      }
      depth += 1
    }
    let after: (LocalReference) -> Void = { [weak self, weak interval] _ in
      guard let self, let interval else { return }
      depth -= 1
      if depth == 0 {
        self.addToIndexes(interval)
        self.slidingIntervals[interval.id] = nil
        if let previous { self.onPositionChange?(interval, previous) }
        previous = nil
      }
    }
    interval.start.beforeSlide = before
    interval.end.beforeSlide = before
    interval.start.afterSlide = after
    interval.end.afterSlide = after
  }
}
