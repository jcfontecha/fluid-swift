import FluidJS

/// Port of `packages/dds/legacy-dds/src/array/interfaces.ts` IRevertible.
public protocol IRevertible: AnyObject {
  func revert() throws
  func dispose()
}

/// The part of the array a revertible drives. Port of `interfaces.ts` ISharedArrayRevertible.
public protocol ISharedArrayRevertible: AnyObject {
  func toggle(_ entryId: JSString) throws
  func toggleMove(_ oldEntryId: JSString, _ newEntryId: JSString) throws
}

/// Undoes (or redoes) one local operation by toggling. Port of `packages/dds/legacy-dds/src/array/sharedArrayRevertible.ts`
/// SharedArrayRevertible.
public final class SharedArrayRevertible: IRevertible {
  private let sharedArray: any ISharedArrayRevertible
  private let op: ISharedArrayOperation

  public init(_ sharedArray: any ISharedArrayRevertible, _ op: ISharedArrayOperation) {
    self.sharedArray = sharedArray
    self.op = op
  }

  /// An insert, delete or toggle is reverted by toggling its entry. A move is reverted by toggling back to
  /// the old position, and a toggleMove by toggling to the position it left.
  public func revert() throws {
    switch op {
    case .insert(let insert):
      try sharedArray.toggle(insert.entryId)
    case .delete(let delete):
      try sharedArray.toggle(delete.entryId)
    case .toggle(let toggle):
      try sharedArray.toggle(toggle.entryId)
    case .move(let move):
      try sharedArray.toggleMove(move.entryId, move.changedToEntryId)
    case .toggleMove(let toggleMove):
      try sharedArray.toggleMove(toggleMove.changedToEntryId, toggleMove.entryId)
    }
  }

  public func dispose() {}
}
