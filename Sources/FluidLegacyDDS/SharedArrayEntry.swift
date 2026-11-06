import FluidJS
import FluidSharedObjectBase

/// One position in a SharedArray's physical list, live or a tombstone. Port of `packages/dds/legacy-dds/src/array/interfaces.ts`
/// SharedArrayEntry (and its persisted part, SharedArrayEntryCore).
///
/// A class, because the physical list and the ID map hold the same mutable entry, as they do in TS.
/// `prevEntryId` and `nextEntryId` link the positions one value has held after moves; they are not physical
/// neighbors. The counters are numbers, not booleans: they can go negative, and chain traversal tests them for
/// truthiness, not for `> 0`.
final class SharedArrayEntry {
  let entryId: JSString
  var value: FluidValue
  var isAckPending: Bool
  var isDeleted: Bool
  var prevEntryId: JSString?
  var nextEntryId: JSString?
  var isLocalPendingDelete: Int
  var isLocalPendingMove: Int

  /// `isRollback` is undefined until a rollback marks the entry. It is never persisted.
  var isRollback: Bool?

  /// `createNewEntry`: a new entry awaits its ack and has no pending operations.
  init(entryId: JSString, value: FluidValue, prevEntryId: JSString? = nil) {
    self.entryId = entryId
    self.value = value
    isAckPending = true
    isDeleted = false
    self.prevEntryId = prevEntryId
    nextEntryId = nil
    isLocalPendingDelete = 0
    isLocalPendingMove = 0
  }

  /// A persisted entry, as `loadCore` reads it. Its local flags are cleared by the caller.
  init(
    entryId: JSString, value: FluidValue, isDeleted: Bool, prevEntryId: JSString?,
    nextEntryId: JSString?
  ) {
    self.entryId = entryId
    self.value = value
    isAckPending = false
    self.isDeleted = isDeleted
    self.prevEntryId = prevEntryId
    self.nextEntryId = nextEntryId
    isLocalPendingDelete = 0
    isLocalPendingMove = 0
  }

  /// `unsetLocalFlags`. `isRollback` is deliberately not cleared.
  func unsetLocalFlags() {
    isAckPending = false
    isLocalPendingDelete = 0
    isLocalPendingMove = 0
  }
}
