import FluidSharedObjectBase
import FluidJS

/// Port of `packages/dds/ordered-collection/src/interfaces.ts` IOrderedCollection: a collection with a
/// deterministic add and remove order, which backs a `ConsensusOrderedCollection`.
public protocol IOrderedCollection {
  init()

  mutating func add(_ value: FluidValue)

  /// Removes and returns the next item. Throws on an empty collection.
  mutating func remove() throws -> FluidValue

  func size() -> Int

  /// `asArray`: the items in order, as the summary writes them.
  func asArray() -> [FluidValue]

  /// `loadFrom`: fills an empty collection from a summary.
  mutating func loadFrom(_ values: [FluidValue]) throws
}
