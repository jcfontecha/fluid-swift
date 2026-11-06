import FluidSharedObjectBase
import FluidJS

/// Port of `packages/dds/ordered-collection/src/snapshotableArray.ts` SnapshotableArray: the item storage
/// that a summary reads and loads.
public struct SnapshotableArray {
  var data: [FluidValue] = []

  public init() {}

  public func asArray() -> [FluidValue] {
    data
  }

  /// TS asserts the storage is empty (0x06b).
  public mutating func loadFrom(_ values: [FluidValue]) throws {
    guard data.isEmpty else {
      throw SharedObjectError("0x06b: Loading snapshot into a non-empty collection")
    }
    data = values
  }

  public func size() -> Int {
    data.count
  }
}
