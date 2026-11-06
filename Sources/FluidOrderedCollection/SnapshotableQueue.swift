import FluidSharedObjectBase
import FluidJS

/// Port of `packages/dds/ordered-collection/src/consensusQueue.ts` SnapshotableQueue: a FIFO over
/// `SnapshotableArray`.
public struct SnapshotableQueue: IOrderedCollection {
  var array = SnapshotableArray()

  public init() {}

  public mutating func add(_ value: FluidValue) {
    array.data.append(value)
  }

  /// Throws `SnapshotableQueue is empty` on an empty queue, as TS does.
  public mutating func remove() throws -> FluidValue {
    guard array.size() > 0 else {
      throw SharedObjectError("SnapshotableQueue is empty")
    }
    return array.data.removeFirst()
  }

  public func size() -> Int {
    array.size()
  }

  public func asArray() -> [FluidValue] {
    array.asArray()
  }

  public mutating func loadFrom(_ values: [FluidValue]) throws {
    try array.loadFrom(values)
  }
}
