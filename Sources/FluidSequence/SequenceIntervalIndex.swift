import FluidJS
import FluidMergeTree

/// Ports intervalIndex/intervalIndex.ts SequenceIntervalIndex.
public protocol SequenceIntervalIndex: AnyObject {
  func add(_ interval: SequenceInterval)
  func remove(_ interval: SequenceInterval)
}

func createTransientIntervalFromSequence(_ sequence: SharedSegmentSequence, start: SequencePlace, end: SequencePlace) throws -> BaseSequenceInterval {
  func reference(_ place: SequencePlace) throws -> LocalReference {
    let position: SequencePosition
    if case .position(let value) = place.position, value < 0 || value >= sequence.getLength() { position = .position(-1) }
    else { position = place.position }
    return try sequence.client.createLocalReferencePosition(at: position, refType: 256)
  }
  return try BaseSequenceInterval(id: "", start: reference(start), end: reference(end), startSide: start.side, endSide: end.side)
}

func intervalLowerBound(_ values: [SequenceInterval], matching: (SequenceInterval) -> Bool) -> Int {
  var lower = 0
  var upper = values.count
  while lower < upper {
    let middle = lower + (upper - lower) / 2
    if matching(values[middle]) { upper = middle }
    else { lower = middle + 1 }
  }
  return lower
}
