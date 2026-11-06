import FluidDriverDefinitions
import FluidJS
import FluidLegacyDDS
import FluidSharedObjectBase
import FluidTestRuntimeUtils
import Testing

// MARK: - sharedArray.spec.ts, "SharedArray in local state"

/// sharedArray.spec.ts "Can insert new data and get sharedArray data".
@Test func arrayInsertsAndGetsDetached() throws {
  let array = makeArray("a")
  try fillEntries(array, [1, 2, 3, 4])
  #expect(numbers(array) == [1, 2, 3, 4])
}

/// sharedArray.spec.ts "Can delete data and get sharedArray data", for every index.
@Test(arguments: [0, 1, 2, 3])
func arrayDeletesDetached(deleteIndex: Int) throws {
  let array = makeArray("a")
  try fillEntries(array, [1, 2, 3, 4])
  var expected: [Double] = [1, 2, 3, 4]
  expected.remove(at: deleteIndex)
  try array.delete(deleteIndex)
  #expect(numbers(array) == expected)
}

/// sharedArray.spec.ts "Can move data and get sharedArray data": case 1 moves forward (oldIndex < newIndex),
/// case 2 backward (oldIndex > newIndex). The target index is a boundary in the sequence before the move.
@Test func arrayMovesDetached() throws {
  let array = makeArray("a")
  try fillEntries(array, [1, 2, 3, 4])
  try array.move(0, 2)
  #expect(numbers(array) == [2, 1, 3, 4])
  try array.move(3, 1)
  #expect(numbers(array) == [2, 4, 1, 3])
}

/// A move to its own index, or to the boundary right after itself, changes nothing and emits nothing.
@Test func arrayMoveToSamePlaceIsNoOp() throws {
  let array = makeArray("a")
  try fillEntries(array, [1, 2, 3])
  let changes = ValueChanges(array)
  try array.move(1, 1)
  try array.move(1, 2)
  #expect(numbers(array) == [1, 2, 3])
  #expect(changes.events.isEmpty)
}

/// sharedArray.spec.ts "Should fire correct SharedArray events": valueChanged, then revertible.
@Test func arrayFiresValueChangedThenRevertible() throws {
  let array = makeArray("a")
  var order: [String] = []
  array.valueChanged = { _, isLocal, _ in order.append("valueChanged local=\(isLocal)") }
  array.revertible = { _ in order.append("revertible") }
  try array.insert(0, number(4))
  #expect(order == ["valueChanged local=true", "revertible"])
}

/// sharedArray.spec.ts "Can load a SharedArray from snapshot".
@Test func arrayLoadsFromSnapshot() throws {
  let array = makeArray("a")
  try fillEntries(array, [1, 2, 3, 4])
  let loaded = try SharedArrayClass.load(id: "b", summary: array.summarize())
  #expect(numbers(loaded) == [1, 2, 3, 4])
}

/// sharedArray.spec.ts "SharedArray IFluidHandle as value": insert, get and snapshot load.
@Test func arrayHoldsHandles() throws {
  let handle = FluidValue.handle(FluidHandle(absolutePath: "/store/handle"))
  let array = makeArray("a")
  try array.insert(0, handle)
  #expect(array.get() == [handle])
  let loaded = try SharedArrayClass.load(id: "b", summary: array.summarize())
  #expect(loaded.get() == [handle])
}

/// Index validation: negative indexes throw, and so do indexes beyond the live count.
@Test func arrayRejectsInvalidIndexes() throws {
  let array = makeArray("a")
  try fillEntries(array, [1, 2])
  #expect(throws: (any Error).self) { try array.insert(-1, number(9)) }
  #expect(throws: (any Error).self) { try array.delete(-1) }
  #expect(throws: (any Error).self) { try array.move(-1, 1) }
  #expect(throws: (any Error).self) { try array.move(0, -1) }
  #expect(throws: (any Error).self) { try array.insert(3, number(9)) }
  #expect(throws: (any Error).self) { try array.delete(2) }
  #expect(numbers(array) == [1, 2])
}

// MARK: - Summary format and retained entries

/// The spec's summary example: A moved from u1 to u3 keeps its tombstone, and the header lists every entry in
/// physical order with only the defined fields.
@Test func arraySummaryRetainsTombstonesByteExact() throws {
  let array = makeArray("a")
  try array.insert(0, text("A"))
  try array.insert(1, text("B"))
  try array.move(0, 2)
  #expect(strings(array) == ["B", "A"])
  let expected =
    #"{"dataArray":[{"entryId":"u1","value":"A","isDeleted":true,"nextEntryId":"u3"},"#
    + #"{"entryId":"u2","value":"B","isDeleted":false},"#
    + #"{"entryId":"u3","value":"A","isDeleted":false,"prevEntryId":"u1"}]}"#
  #expect(array.summarize() == .singleBlob("header", JSString(expected)))
}

/// An empty array summarizes to `{"dataArray":[]}`.
@Test func arrayEmptySummary() {
  #expect(makeArray("a").summarize() == .singleBlob("header", #"{"dataArray":[]}"#))
}

/// Loading keeps tombstones and chains: toggling the tombstone's chain after a load still works.
@Test func arrayLoadKeepsRetainedEntries() throws {
  let array = makeArray("a")
  try array.insert(0, text("A"))
  try array.insert(1, text("B"))
  try array.move(0, 2)
  let loaded = try SharedArrayClass.load(id: "b", summary: array.summarize())
  #expect(loaded.summarize() == array.summarize())
  try loaded.toggle("u1")
  #expect(strings(loaded) == ["B"])
}

/// A summary clears the live entries' pending flags (sharedArray.ts summarizeCore, unsetLocalFlags), so a remote
/// delete that arrives afterward is not recorded as racing the local pending delete, and rolling back the local
/// delete then resurrects the entry. Without the summary, the remote delete is remembered and the entry stays
/// deleted (`arrayRemoteDeleteSurvivesRollbackOfLocalDelete`).
@Test func arraySummaryClearsPendingFlags() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let a = connectedArray(factory, "A", flushMode: .turnBased)
  let b = connectedArray(factory, "B", flushMode: .turnBased)
  try a.array.insert(0, text("x"))
  a.runtime.flush()
  try factory.processAllMessages()
  try a.array.delete(0)
  _ = a.array.summarize()
  try b.array.delete(0)
  b.runtime.flush()
  try factory.processAllMessages()
  #expect(strings(a.array).isEmpty)
  try a.runtime.rollback()
  #expect(strings(a.array) == ["x"])
}

// MARK: - Wire format

/// The wire ops of the spec: type numbers, field order, and omitted optionals.
@Test func arrayOpsUseUpstreamWireFormat() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let client = connectedArray(factory, "A")
  let array = client.array
  try array.insert(0, text("A"))
  try array.insert(1, text("B"))
  try array.move(0, 2)
  try array.delete(0)
  try array.toggleMove("A-1", "A-3")
  try array.toggle("A-1")
  #expect(
    sentContents(client.runtime) == [
      #"{"type":0,"entryId":"A-1","value":"A"}"#,
      #"{"type":0,"entryId":"A-2","value":"B","insertAfterEntryId":"A-1"}"#,
      #"{"type":2,"entryId":"A-1","insertAfterEntryId":"A-2","changedToEntryId":"A-3"}"#,
      #"{"type":1,"entryId":"A-2"}"#,
      #"{"type":4,"entryId":"A-1","changedToEntryId":"A-3"}"#,
      #"{"type":3,"entryId":"A-1","isDeleted":true}"#,
    ])
}

/// A handle value rides as `{"type":"__fluid_handle__","url":...}`.
@Test func arrayEncodesHandleValuesOnTheWire() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let client = connectedArray(factory, "A")
  try client.array.insert(0, .handle(FluidHandle(absolutePath: "/store/blob", payloadPending: true)))
  #expect(
    sentContents(client.runtime) == [
      #"{"type":0,"entryId":"A-1","value":{"type":"__fluid_handle__","url":"/store/blob","payloadPending":true}}"#
    ])
}

/// A detached array applies edits, emits events and submits nothing.
@Test func arrayDetachedEditsEmitButDoNotSubmit() throws {
  let array = makeArray("a")
  let changes = ValueChanges(array)
  try array.insert(0, text("A"))
  #expect(changes.events.count == 1)
  #expect(changes.events[0].isLocal)
}

// MARK: - sharedArrayConnected.spec.ts

/// "Can insert data multiple times and converge".
@Test func arrayInsertsConverge() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let local = connectedArray(factory, "A")
  let remote = connectedArray(factory, "B")
  try fillEntries(local.array, [1, 2])
  try fillEntries(remote.array, [3, 4])
  try factory.processAllMessages()
  #expect(numbers(local.array) == numbers(remote.array))
  #expect(numbers(local.array).count == 4)
}

/// "Fires correct events after insertion": the remote sees valueChanged, the local sees revertible.
@Test func arrayFiresRemoteValueChangedAndLocalRevertible() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let local = connectedArray(factory, "A")
  let remote = connectedArray(factory, "B")
  let remoteChanges = ValueChanges(remote.array)
  var revertibles = 0
  local.array.revertible = { _ in revertibles += 1 }
  try local.array.insert(0, number(10))
  try factory.processAllMessages()
  #expect(remoteChanges.events.count == 1)
  #expect(!remoteChanges.events[0].isLocal)
  #expect(revertibles == 1)
}

/// A local ack emits no valueChanged and no revertible.
@Test func arrayAckEmitsNothing() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let local = connectedArray(factory, "A")
  let changes = ValueChanges(local.array)
  var revertibles = 0
  local.array.revertible = { _ in revertibles += 1 }
  try local.array.insert(0, number(1))
  try factory.processAllMessages()
  #expect(changes.events.count == 1)
  #expect(revertibles == 1)
}

/// "Undo and Redo for insert op": reverting an insert toggles it deleted, reverting that toggles it back.
@Test func arrayUndoRedoInsert() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let local = connectedArray(factory, "A")
  let remote = connectedArray(factory, "B")
  var revertible: SharedArrayRevertible?
  local.array.revertible = { revertible = $0 }
  try fillEntries(local.array, [1, 2, 3, 4])
  try factory.processAllMessages()
  try revertible?.revert()
  try factory.processAllMessages()
  #expect(numbers(local.array) == [1, 2, 3])
  #expect(numbers(remote.array) == [1, 2, 3])
  try revertible?.revert()
  try factory.processAllMessages()
  #expect(numbers(local.array) == [1, 2, 3, 4])
  #expect(numbers(remote.array) == [1, 2, 3, 4])
}

/// "Undo and Redo for delete op".
@Test func arrayUndoRedoDelete() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let local = connectedArray(factory, "A")
  let remote = connectedArray(factory, "B")
  try fillEntries(local.array, [1, 2, 3, 4])
  try factory.processAllMessages()
  var revertible: SharedArrayRevertible?
  local.array.revertible = { revertible = $0 }
  try local.array.delete(1)
  try factory.processAllMessages()
  #expect(numbers(remote.array) == [1, 3, 4])
  try revertible?.revert()
  try factory.processAllMessages()
  #expect(numbers(local.array) == [1, 2, 3, 4])
  #expect(numbers(remote.array) == [1, 2, 3, 4])
  try revertible?.revert()
  try factory.processAllMessages()
  #expect(numbers(local.array) == [1, 3, 4])
  #expect(numbers(remote.array) == [1, 3, 4])
}

/// "Undo and Redo for move op": reverting a move is a toggleMove, and reverting that is the inverse toggleMove.
@Test func arrayUndoRedoMove() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let local = connectedArray(factory, "A")
  let remote = connectedArray(factory, "B")
  try fillEntries(local.array, [1, 2, 3, 4])
  try factory.processAllMessages()
  var revertible: SharedArrayRevertible?
  local.array.revertible = { revertible = $0 }
  try local.array.move(0, 3)
  try factory.processAllMessages()
  #expect(numbers(remote.array) == [2, 3, 1, 4])
  try revertible?.revert()
  try factory.processAllMessages()
  #expect(numbers(local.array) == [1, 2, 3, 4])
  #expect(numbers(remote.array) == [1, 2, 3, 4])
  try revertible?.revert()
  try factory.processAllMessages()
  #expect(numbers(local.array) == [2, 3, 1, 4])
  #expect(numbers(remote.array) == [2, 3, 1, 4])
}

/// A remote delete and move converge, with the remote's events marked non-local and the original op passed on.
@Test func arrayRemoteOpsEmitOriginalOps() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let local = connectedArray(factory, "A")
  let remote = connectedArray(factory, "B")
  try fillEntries(local.array, [1, 2, 3])
  try factory.processAllMessages()
  let changes = ValueChanges(remote.array)
  try local.array.delete(0)
  try local.array.move(0, 2)
  try factory.processAllMessages()
  #expect(numbers(remote.array) == numbers(local.array))
  #expect(
    changes.events.map(\.op) == [
      .delete(IDeleteOperation(entryId: "A-1")),
      .move(IMoveOperation(entryId: "A-2", insertAfterEntryId: "A-3", changedToEntryId: "A-4")),
    ])
  #expect(changes.events.allSatisfy { !$0.isLocal })
}

// MARK: - insertBulkAfter and rearrangeToFront

/// insertBulkAfter inserts after the last live entry equal to `ref`, in order.
@Test func arrayInsertBulkAfterFindsReference() throws {
  let array = makeArray("a")
  try fillEntries(array, [1, 2, 3])
  try array.insertBulkAfter(number(2), [number(7), number(8)])
  #expect(numbers(array) == [1, 2, 7, 8, 3])
}

/// An undefined `ref` inserts at the start.
@Test func arrayInsertBulkAfterUndefinedInsertsAtStart() throws {
  let array = makeArray("a")
  try fillEntries(array, [1, 2])
  try array.insertBulkAfter(nil, [number(7), number(8)])
  #expect(numbers(array) == [7, 8, 1, 2])
}

/// Upstream's scan stops before physical index 0, so a `ref` that is only at index 0, or absent, inserts at
/// physical index 1 in a non-empty array, contrary to the method's comment (spec: Array identity and local operations).
@Test func arrayInsertBulkAfterNoMatchInsertsAtIndexOne() throws {
  let array = makeArray("a")
  try fillEntries(array, [1, 2, 3])
  try array.insertBulkAfter(number(99), [number(7)])
  #expect(numbers(array) == [1, 7, 2, 3])
  let first = makeArray("b")
  try fillEntries(first, [1, 2, 3])
  try first.insertBulkAfter(number(1), [number(7)])
  #expect(numbers(first) == [1, 7, 2, 3])
}

/// On an empty array every `ref` inserts at 0.
@Test func arrayInsertBulkAfterOnEmptyArray() throws {
  let array = makeArray("a")
  try array.insertBulkAfter(number(5), [number(7), number(8)])
  #expect(numbers(array) == [7, 8])
}

/// rearrangeToFront moves each value, in order, to the front using physical indexes.
@Test func arrayRearrangeToFront() throws {
  let array = makeArray("a")
  try fillEntries(array, [1, 2, 3, 4])
  try array.rearrangeToFront([number(3), number(1)])
  #expect(numbers(array) == [3, 1, 2, 4])
}

/// rearrangeToFront stops at the first equal entry even when it is deleted, so a deleted match shadows a live one.
@Test func arrayRearrangeToFrontStopsAtDeletedMatch() throws {
  let array = makeArray("a")
  try array.insert(0, number(1))
  try array.insert(1, number(5))
  try array.insert(2, number(5))
  try array.delete(1)
  try array.rearrangeToFront([number(5)])
  #expect(numbers(array) == [1, 5])
}

// MARK: - Concurrent behavior, exactly as upstream

/// The harness's TS-only counterexample (PROTOCOL.md "SharedArray convergence counterexample"): A undoes a move
/// while B deletes the entry; after B undoes the delete the replicas disagree. Upstream behavior, reproduced.
@Test func arrayReproducesUpstreamMoveUndoDeleteDivergence() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let a = connectedArray(factory, "A")
  let b = connectedArray(factory, "B")
  var moveRevertible: SharedArrayRevertible?
  a.array.revertible = { moveRevertible = $0 }
  try a.array.insert(0, text("1"))
  try a.array.insert(1, text("2"))
  try a.array.move(0, 2)
  try factory.processAllMessages()
  #expect(strings(a.array) == ["2", "1"])
  #expect(strings(b.array) == ["2", "1"])
  var deleteRevertible: SharedArrayRevertible?
  b.array.revertible = { deleteRevertible = $0 }
  try moveRevertible?.revert()
  try b.array.delete(1)
  try factory.processAllMessages()
  #expect(strings(a.array) == ["2"])
  #expect(strings(b.array) == ["2"])
  try deleteRevertible?.revert()
  try factory.processAllMessages()
  #expect(strings(a.array) == ["1", "2"])
  #expect(strings(b.array) == ["2", "1"])
}

/// Two inserts after the same anchor: the one sequenced later sits first, and a pending local insert stays ahead
/// of an incoming one until its ack (handleInsertOp, getInternalInsertIndexByIgnoringLocalPendingInserts).
@Test func arrayConcurrentInsertsAtSameAnchorOrderBySequence() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let a = connectedArray(factory, "A")
  let b = connectedArray(factory, "B")
  try a.array.insert(0, text("root"))
  try factory.processAllMessages()
  try a.array.insert(1, text("a"))
  try b.array.insert(1, text("b"))
  try factory.processAllMessages()
  #expect(strings(a.array) == strings(b.array))
  #expect(strings(a.array) == ["root", "b", "a"])
}

/// A remote delete of an entry the receiver has a pending delete on is remembered, and rolling back the local
/// delete must not resurrect it.
@Test func arrayRemoteDeleteSurvivesRollbackOfLocalDelete() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let a = connectedArray(factory, "A", flushMode: .turnBased)
  let b = connectedArray(factory, "B", flushMode: .turnBased)
  try a.array.insert(0, number(0))
  a.runtime.flush()
  try factory.processAllMessages()
  try a.array.delete(0)
  try b.array.delete(0)
  b.runtime.flush()
  try factory.processAllMessages()
  #expect(numbers(a.array).isEmpty)
  try a.runtime.rollback()
  #expect(numbers(a.array).isEmpty)
}

// MARK: - array.rollback.spec.ts

/// "should rollback insert operation": the entry disappears and a synthetic delete is emitted locally.
@Test func arrayRollbackInsert() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let client = connectedArray(factory, "A", flushMode: .turnBased)
  let changes = ValueChanges(client.array)
  try client.array.insert(0, number(0))
  #expect(numbers(client.array) == [0])
  #expect(changes.events.count == 1)
  try client.runtime.rollback()
  #expect(numbers(client.array).isEmpty)
  #expect(changes.events.count == 2)
  #expect(changes.events[1].op == .delete(IDeleteOperation(entryId: "A-1")))
  #expect(changes.events[1].isLocal)
}

/// "should rollback delete operation": the entry returns and a synthetic insert without anchor is emitted.
@Test func arrayRollbackDelete() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let client = connectedArray(factory, "A", flushMode: .turnBased)
  try client.array.insert(0, number(0))
  client.runtime.flush()
  try factory.processAllMessages()
  let changes = ValueChanges(client.array)
  try client.array.delete(0)
  #expect(numbers(client.array).isEmpty)
  try client.runtime.rollback()
  #expect(numbers(client.array) == [0])
  #expect(changes.events.count == 2)
  #expect(
    changes.events[1].op
      == .insert(IInsertOperation(entryId: "A-1", value: number(0), insertAfterEntryId: nil)))
}

/// "should rollback insert and delete operations".
@Test func arrayRollbackInsertAndDelete() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let client = connectedArray(factory, "A", flushMode: .turnBased)
  try fillEntries(client.array, [0, 1, 2])
  try client.array.delete(0)
  client.runtime.flush()
  try factory.processAllMessages()
  let changes = ValueChanges(client.array)
  try client.array.insert(1, number(5))
  try client.array.delete(0)
  #expect(numbers(client.array) == [5, 2])
  #expect(changes.events.count == 2)
  try client.runtime.rollback()
  #expect(numbers(client.array) == [1, 2])
  #expect(changes.events.count == 4)
}

/// "should rollback insert and delete ops in presence of remote changes".
@Test func arrayRollbackInsertAndDeleteWithRemoteChanges() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let a = connectedArray(factory, "A", flushMode: .turnBased)
  let b = connectedArray(factory, "B", flushMode: .turnBased)
  try a.array.insert(0, number(0))
  try a.array.insert(1, number(1))
  a.runtime.flush()
  try factory.processAllMessages()
  try a.array.insert(2, number(2))
  try a.array.delete(0)
  try b.array.insert(2, number(3))
  try b.array.delete(0)
  try b.array.insert(1, number(12))
  try b.array.insert(0, number(10))
  b.runtime.flush()
  try factory.processAllMessages()
  #expect(numbers(a.array) == [10, 1, 2, 12, 3])
  try a.runtime.rollback()
  #expect(numbers(a.array) == [10, 1, 12, 3])
  #expect(numbers(b.array) == [10, 1, 12, 3])
}

/// "should rollback move operation": two move events, the second the inverse of the first.
@Test func arrayRollbackMove() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let a = connectedArray(factory, "A", flushMode: .turnBased)
  let b = connectedArray(factory, "B", flushMode: .turnBased)
  try fillEntries(a.array, [0, 1, 2])
  a.runtime.flush()
  try factory.processAllMessages()
  let changes = ValueChanges(a.array)
  try a.array.move(0, 2)
  #expect(numbers(a.array) == [1, 0, 2])
  try a.runtime.rollback()
  #expect(changes.events.count == 2)
  guard case .move(let first) = changes.events[0].op, case .move(let second) = changes.events[1].op else {
    Issue.record("both events should be moves")
    return
  }
  #expect(first.entryId == second.changedToEntryId)
  #expect(first.changedToEntryId == second.entryId)
  #expect(second.insertAfterEntryId == nil)
  #expect(numbers(a.array) == [0, 1, 2])
  #expect(numbers(b.array) == [0, 1, 2])
}

/// "should rollback move ops in presence of remote changes".
@Test func arrayRollbackMoveWithRemoteChanges() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let a = connectedArray(factory, "A", flushMode: .turnBased)
  let b = connectedArray(factory, "B", flushMode: .turnBased)
  try a.array.insert(0, number(0))
  try a.array.insert(1, number(1))
  a.runtime.flush()
  try factory.processAllMessages()
  try a.array.insert(2, number(2))
  try a.array.insert(3, number(3))
  try a.array.move(0, 3)
  try b.array.insert(2, number(3))
  try b.array.delete(0)
  try b.array.insert(1, number(12))
  try b.array.insert(0, number(10))
  b.runtime.flush()
  try factory.processAllMessages()
  #expect(numbers(a.array) == [10, 1, 2, 3, 12, 3])
  try a.runtime.rollback()
  #expect(numbers(a.array) == [10, 1, 12, 3])
  #expect(numbers(b.array) == [10, 1, 12, 3])
}

/// "should rollback toggle operation": revert() toggles the last insert, and rolling that back toggles it again.
@Test func arrayRollbackToggle() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let a = connectedArray(factory, "A", flushMode: .turnBased)
  let b = connectedArray(factory, "B", flushMode: .turnBased)
  var revertible: SharedArrayRevertible?
  a.array.revertible = { revertible = $0 }
  try fillEntries(a.array, [0, 1, 2])
  a.runtime.flush()
  try factory.processAllMessages()
  let changes = ValueChanges(a.array)
  try revertible?.revert()
  #expect(numbers(a.array) == [0, 1])
  try a.runtime.rollback()
  #expect(changes.events.count == 2)
  #expect(changes.events.allSatisfy { if case .toggle = $0.op { true } else { false } })
  #expect(numbers(a.array) == [0, 1, 2])
  #expect(numbers(b.array) == [0, 1, 2])
}

/// "should rollback toggle move operation".
@Test func arrayRollbackToggleMove() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let a = connectedArray(factory, "A", flushMode: .turnBased)
  let b = connectedArray(factory, "B", flushMode: .turnBased)
  var revertible: SharedArrayRevertible?
  a.array.revertible = { revertible = $0 }
  try fillEntries(a.array, [0, 1, 2])
  try a.array.move(0, 3)
  a.runtime.flush()
  try factory.processAllMessages()
  let changes = ValueChanges(a.array)
  try revertible?.revert()
  #expect(numbers(a.array) == [0, 1, 2])
  try a.runtime.rollback()
  #expect(changes.events.count == 2)
  #expect(changes.events.allSatisfy { if case .toggleMove = $0.op { true } else { false } })
  #expect(numbers(a.array) == [1, 2, 0])
  #expect(numbers(b.array) == [1, 2, 0])
}

/// A toggle whose live entry was rolled back is ignored (toggle: isRollback).
@Test func arrayToggleOfRolledBackEntryIsIgnored() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let client = connectedArray(factory, "A", flushMode: .turnBased)
  try client.array.insert(0, number(0))
  try client.runtime.rollback()
  let changes = ValueChanges(client.array)
  try client.array.toggle("A-1")
  #expect(changes.events.isEmpty)
  #expect(numbers(client.array).isEmpty)
}

// MARK: - sharedArrayReconnection.spec.ts

/// "can resend unacknowledged ops on reconnection".
@Test func arrayResendsUnacknowledgedOpsOnReconnect() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let a = connectedArray(factory, "A")
  let b = connectedArray(factory, "B")
  try a.array.insert(0, number(1))
  a.runtime.disconnect()
  try a.array.insert(1, number(2))
  try a.runtime.reconnect(clientId: "A2")
  try factory.processAllMessages()
  #expect(numbers(a.array) == [1, 2])
  #expect(numbers(b.array) == [1, 2])
}

/// "Moving an element at one client and deleting the same element on another client should converge after
/// reconnection".
@Test func arrayMoveAndDeleteConvergeAfterReconnect() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let a = connectedArray(factory, "A")
  let b = connectedArray(factory, "B")
  try fillEntries(a.array, [1, 2, 3])
  try factory.processAllMessages()
  a.runtime.disconnect()
  try a.array.move(0, 3)
  try b.array.delete(0)
  try factory.processAllMessages()
  try a.runtime.reconnect(clientId: "A2")
  try factory.processAllMessages()
  #expect(numbers(a.array) == numbers(b.array))
}

// MARK: - Stashed ops

/// applyStashedOp applies an insert, keeps its identity, emits no event and submits the original op.
@Test func arrayStashedInsertKeepsIdentityAndSubmits() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let client = connectedArray(factory, "A")
  let changes = ValueChanges(client.array)
  var revertibles = 0
  client.array.revertible = { _ in revertibles += 1 }
  let op = try JSON.parse(#"{"type":0,"entryId":"stashed","value":"S"}"#)
  try client.array.applyStashedOp(op)
  #expect(strings(client.array) == ["S"])
  #expect(changes.events.isEmpty)
  #expect(revertibles == 0)
  #expect(sentContents(client.runtime) == [#"{"type":0,"entryId":"stashed","value":"S"}"#])
}

/// A stashed delete marks the entry deleted and counts a pending delete, so the ack settles it.
@Test func arrayStashedDeleteThenAck() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let a = connectedArray(factory, "A")
  let b = connectedArray(factory, "B")
  try a.array.insert(0, text("x"))
  try factory.processAllMessages()
  try a.array.applyStashedOp(try JSON.parse(#"{"type":1,"entryId":"A-1"}"#))
  #expect(strings(a.array).isEmpty)
  try factory.processAllMessages()
  #expect(strings(a.array).isEmpty)
  #expect(strings(b.array).isEmpty)
}

// MARK: - Errors

/// An unknown op type throws `Unknown operation`.
@Test func arrayUnknownOperationThrows() throws {
  let factory = MockContainerRuntimeFactory<SharedArrayClass>()
  let client = connectedArray(factory, "A")
  let message = try SequencedMessage(
    json: try JSON.parse(
      #"{"clientId":"B","clientSequenceNumber":1,"referenceSequenceNumber":0,"sequenceNumber":1,"minimumSequenceNumber":0,"type":"op","contents":{"type":9,"entryId":"x"}}"#
    ))
  #expect(throws: (any Error).self) { try client.runtime.process(message) }
}
