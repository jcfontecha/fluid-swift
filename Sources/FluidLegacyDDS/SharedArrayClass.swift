import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
// The public API exposes `FluidValue` and `FluidSerializer`, so clients need them too.
import FluidSharedObjectBase
import Foundation

/// The two counters a chain search can test. `isLocalPending` reads `isLocalPendingDelete` or
/// `isLocalPendingMove` by name in TS.
private enum PendingCounter {
  case delete
  case move

  func value(of entry: SharedArrayEntry) -> Int {
    switch self {
    case .delete: entry.isLocalPendingDelete
    case .move: entry.isLocalPendingMove
    }
  }
}

/// JS `===` for values. Primitives compare by value. A Swift `FluidValue` object, array or handle has no
/// identity, so it never equals anything, which is what `===` gives two distinct JS objects.
private func strictlyEquals(_ left: FluidValue, _ right: FluidValue) -> Bool {
  switch (left, right) {
  case (.undefined, .undefined):
    return true
  case (.json(let leftJSON), .json(let rightJSON)):
    switch (leftJSON, rightJSON) {
    case (.null, .null):
      return true
    case (.bool(let leftBool), .bool(let rightBool)):
      return leftBool == rightBool
    case (.number(let leftNumber), .number(let rightNumber)):
      return leftNumber == rightNumber
    case (.string(let leftString), .string(let rightString)):
      return leftString == rightString
    default:
      return false
    }
  default:
    return false
  }
}

/// An optimistic ordered list whose retained tombstones and move-identity chains support concurrent edits and
/// revertibles. Port of `packages/dds/legacy-dds/src/array/sharedArray.ts` SharedArrayClass; the TS factory
/// (`sharedArrayFactory.ts`) is carried by the `Channel` conformance: `type`, `init(id:)` and
/// `load(id:summary:)`.
///
/// Values are `FluidValue`s. TS types them `T`, which excludes `undefined`, so inserting `.undefined` throws.
public final class SharedArrayClass: SharedObject<Void>, ISharedArrayRevertible {
  public override class var type: JSString { "https://graph.microsoft.com/types/SharedArray" }

  private static let snapshotFileName: JSString = "header"

  private let serializer = FluidSerializer()

  /// `sharedArray`: the physical entries, tombstones included.
  private var sharedArray: [SharedArrayEntry] = []

  /// `idToEntryMap`: a search aid, never snapshotted. Entries are never removed from it.
  private var idToEntryMap: [JSString: SharedArrayEntry] = [:]

  /// `remoteDeleteWithLocalPendingDelete`: entries a remote client deleted while this client had a pending delete
  /// of them. Rolling back the local delete must not resurrect them.
  private var remoteDeleteWithLocalPendingDelete: Set<JSString> = []

  /// Source of entry IDs. TS calls `uuid()`. The harness replaces it, because it needs deterministic IDs.
  public var generateEntryId: () -> JSString = { JSString(UUID().uuidString.lowercased()) }

  /// "valueChanged" (op, isLocal, array). A remote op emits it after it is applied, even when it changed
  /// nothing visible; a local ack emits nothing.
  public var valueChanged: ((ISharedArrayOperation, Bool, SharedArrayClass) -> Void)?

  /// "revertible" (revertible). Emitted for local edits only, after `valueChanged`.
  public var revertible: ((SharedArrayRevertible) -> Void)?

  /// The values of the entries that are not deleted, in order. A snapshot, not a view.
  public func get() -> [FluidValue] {
    sharedArray.filter { !$0.isDeleted }.map(\.value)
  }

  // MARK: Summary and load

  /// `summarizeCore`: a single `header` blob `{dataArray}` holding every entry, tombstones included, in
  /// physical order. The entries are copied first, then every entry's local flags are cleared, because the
  /// snapshot is taken as if everything pending were acknowledged.
  public override func summarize() -> SummaryTree {
    let dataArray = sharedArray.map(persistedEntry)
    for entry in sharedArray {
      entry.unsetLocalFlags()
    }
    var contents = JSObject<JSONValue>()
    contents["dataArray"] = .array(dataArray)
    return .singleBlob(Self.snapshotFileName, JSString(JSON.stringify(.object(contents))))
  }

  /// One entry as persisted: `entryId, value, isDeleted, prevEntryId, nextEntryId`. An absent link is omitted.
  private func persistedEntry(_ entry: SharedArrayEntry) -> JSONValue {
    var object = JSObject<JSONValue>()
    object["entryId"] = .string(entry.entryId)
    object["value"] = serializer.encode(entry.value)
    object["isDeleted"] = .bool(entry.isDeleted)
    object["prevEntryId"] = entry.prevEntryId.map(JSONValue.string)
    object["nextEntryId"] = entry.nextEntryId.map(JSONValue.string)
    return .object(object)
  }

  /// `loadCore`: assigns the persisted list, rebuilds the ID map and clears the local flags, with no events.
  public override func loadCore(_ summary: SummaryTree) throws {
    let header = try summary.readAndParse(Self.snapshotFileName)
    sharedArray = try header.member("dataArray").asArray().map(loadedEntry)
    for entry in sharedArray {
      idToEntryMap[entry.entryId] = entry
      entry.unsetLocalFlags()
    }
  }

  private func loadedEntry(_ json: JSONValue) throws -> SharedArrayEntry {
    let object = try json.asObject()
    guard case .bool(let isDeleted)? = object["isDeleted"] else {
      throw JSONDecodingError("expected boolean isDeleted in \(json)")
    }
    return SharedArrayEntry(
      entryId: try json.member("entryId").asString(),
      value: try serializer.decode(json.member("value")),
      isDeleted: isDeleted,
      prevEntryId: try object["prevEntryId"].map { try $0.asString() },
      nextEntryId: try object["nextEntryId"].map { try $0.asString() })
  }

  // MARK: Local operations

  /// `insertBulkAfter`: inserts `values` in order after the last live entry equal to `ref`, or at the start for
  /// an undefined `ref`. The scan runs from the last physical index while the index is above 0, so an entry at
  /// physical index 0 is never matched; with a defined `ref` one is added even when nothing matched.
  public func insertBulkAfter(_ ref: FluidValue?, _ values: [FluidValue]) throws {
    var itemIndex = 0
    if let ref, ref != .undefined {
      itemIndex = sharedArray.count - 1
      while itemIndex > 0 {
        let item = sharedArray[itemIndex]
        if !item.isDeleted && strictlyEquals(item.value, ref) {
          break
        }
        itemIndex -= 1
      }
      itemIndex += 1
    }
    for value in values {
      try insertCore(itemIndex, value)
      itemIndex += 1
    }
  }

  public func insert(_ index: Int, _ value: FluidValue) throws {
    guard index >= 0 else {
      throw SharedObjectError("Invalid input: Insertion index provided is less than 0.")
    }
    try insertCore(findInternalInsertionIndex(index), value)
  }

  private func insertCore(_ indexInternal: Int, _ value: FluidValue) throws {
    guard value != .undefined else {
      throw SharedObjectError("Invalid input: a SharedArray cannot hold undefined.")
    }
    let insertAfterEntryId = indexInternal >= 1 ? physicalEntry(at: indexInternal - 1)?.entryId : nil
    let newEntryId = createAddEntry(indexInternal, value)
    let op = ISharedArrayOperation.insert(
      IInsertOperation(entryId: newEntryId, value: value, insertAfterEntryId: insertAfterEntryId))
    try finishLocalOperation(op)
  }

  public func delete(_ index: Int) throws {
    guard index >= 0 else {
      throw SharedObjectError("Invalid input: Deletion index provided is less than 0.")
    }
    let indexInternal = try findInternalDeletionIndex(index)
    guard let entry = physicalEntry(at: indexInternal) else {
      throw SharedObjectError("0xb90: Invalid index")
    }
    let entryId = entry.entryId
    try deleteCore(indexInternal)
    try finishLocalOperation(.delete(IDeleteOperation(entryId: entryId)))
  }

  /// `rearrangeToFront`: moves each value, in order, to the front by physical index. The search for a value
  /// stops at the first strictly equal entry even if it is deleted, so a deleted match shadows a live one.
  public func rearrangeToFront(_ values: [FluidValue]) throws {
    for toIndex in 0..<values.count {
      let value = values[toIndex]
      // The first `toIndex` indices hold values already moved, so the search starts after them.
      var fromIndex = toIndex
      while fromIndex < sharedArray.count {
        let item = sharedArray[fromIndex]
        guard strictlyEquals(item.value, value) else {
          fromIndex += 1
          continue
        }
        // Moving to the same index, or to the boundary right after itself, makes no sense, so it is a no-op.
        if !item.isDeleted && fromIndex != toIndex && toIndex != fromIndex + 1 {
          try moveCore(fromIndex, toIndex)
        }
        break
      }
    }
  }

  /// `move`: both indexes are user (live) indexes. `toIndex` is a boundary in the sequence before the move.
  public func move(_ fromIndex: Int, _ toIndex: Int) throws {
    guard fromIndex >= 0 else {
      throw SharedObjectError("Invalid input: fromIndex value provided is less than 0")
    }
    guard toIndex >= 0 else {
      throw SharedObjectError("Invalid input: toIndex value provided is less than 0")
    }
    // Moving to and from the same index makes no sense, and neither does moving an entry to its immediate next.
    if fromIndex == toIndex || toIndex == fromIndex + 1 {
      return
    }
    let fromIndexInternal = try findInternalDeletionIndex(fromIndex)
    let toIndexInternal = try findInternalInsertionIndex(toIndex)
    try moveCore(fromIndexInternal, toIndexInternal)
  }

  private func moveCore(_ fromIndexInternal: Int, _ toIndexInternal: Int) throws {
    let insertAfterEntryId =
      toIndexInternal >= 1 ? physicalEntry(at: toIndexInternal - 1)?.entryId : nil
    guard let entryId = physicalEntry(at: fromIndexInternal)?.entryId else {
      throw SharedObjectError("0xb92: Invalid index")
    }
    let changedToEntryId = try createMoveEntry(fromIndexInternal, toIndexInternal)
    let op = ISharedArrayOperation.move(
      IMoveOperation(
        entryId: entryId, insertAfterEntryId: insertAfterEntryId, changedToEntryId: changedToEntryId))
    try finishLocalOperation(op)
  }

  /// `toggle`: undo or redo of an insert or delete. The pending-delete counter goes up on the addressed entry,
  /// but `isDeleted` flips on the live end of its chain. A live entry that a rollback marked is left alone.
  public func toggle(_ entryId: JSString) throws {
    let liveEntry = try getLiveEntry(entryId)
    if liveEntry.isRollback == true {
      return
    }
    let isDeleted = !liveEntry.isDeleted
    try getEntryForId(entryId).isLocalPendingDelete += 1
    liveEntry.isDeleted = isDeleted
    try finishLocalOperation(.toggle(IToggleOperation(entryId: entryId, isDeleted: isDeleted)))
  }

  /// `toggleMove`: undo or redo of a move. `oldEntryId` becomes the live position and `newEntryId` the dead one.
  public func toggleMove(_ oldEntryId: JSString, _ newEntryId: JSString) throws {
    let liveEntry = try getLiveEntry(newEntryId)
    if liveEntry.isRollback == true {
      return
    }
    if try getEntryForId(newEntryId).isDeleted {
      return
    }
    try getEntryForId(oldEntryId).isLocalPendingMove += 1
    try updateLiveEntry(newEntryId, oldEntryId)
    let op = IToggleMoveOperation(entryId: oldEntryId, changedToEntryId: newEntryId)
    try finishLocalOperation(.toggleMove(op))
  }

  /// The tail of every local operation: `valueChanged`, then `revertible`, then the submission if attached.
  /// A detached array applies, and emits, but submits nothing.
  private func finishLocalOperation(_ op: ISharedArrayOperation) throws {
    emitValueChangedEvent(op, isLocal: true)
    emitRevertibleEvent(op)
    guard isAttached else {
      return
    }
    try submitLocalMessage(op.json(serializer), ())
  }

  // MARK: Rollback

  /// `rollback`: undoes one unsent local op and emits a synthetic local `valueChanged`, never a revertible
  /// and never a submission. It is not a general inversion: the counters and flags are restored asymmetrically.
  public override func rollback(_ content: JSONValue, localOpMetadata: Void) throws {
    switch try ISharedArrayOperation(json: content, serializer: serializer) {
    case .insert(let op):
      let liveEntry = try getLiveEntry(op.entryId)
      liveEntry.isDeleted = true
      liveEntry.isRollback = true
      emitValueChangedEvent(.delete(IDeleteOperation(entryId: op.entryId)), isLocal: true)
    case .delete(let op):
      try rollbackDelete(op)
    case .move(let op):
      try rollbackMove(op)
    case .toggle(let op):
      let liveEntry = try getLiveEntry(op.entryId)
      let isDeleted = liveEntry.isDeleted
      liveEntry.isDeleted = !isDeleted
      liveEntry.isLocalPendingDelete -= 1
      liveEntry.isRollback = true
      emitValueChangedEvent(
        .toggle(IToggleOperation(entryId: op.entryId, isDeleted: liveEntry.isDeleted)), isLocal: true)
    case .toggleMove(let op):
      try getEntryForId(op.entryId).isLocalPendingMove -= 1
      try getEntryForId(op.changedToEntryId).isRollback = true
      try updateLiveEntry(op.entryId, op.changedToEntryId)
      emitValueChangedEvent(
        .toggleMove(IToggleMoveOperation(entryId: op.changedToEntryId, changedToEntryId: op.entryId)),
        isLocal: true)
    }
  }

  /// Rolling back a delete a remote client also made only forgets the local pending delete, and does not
  /// decrement the counter. Otherwise the entry returns, and the counter drops if it is above 0.
  private func rollbackDelete(_ op: IDeleteOperation) throws {
    if remoteDeleteWithLocalPendingDelete.contains(op.entryId) {
      remoteDeleteWithLocalPendingDelete.remove(op.entryId)
      return
    }
    let liveEntry = try getLiveEntry(op.entryId)
    liveEntry.isDeleted = false
    liveEntry.isRollback = true
    emitValueChangedEvent(
      .insert(IInsertOperation(entryId: op.entryId, value: liveEntry.value, insertAfterEntryId: nil)),
      isLocal: true)
    let entry = try getEntryForId(op.entryId)
    if entry.isLocalPendingDelete > 0 {
      entry.isLocalPendingDelete -= 1
    }
  }

  /// Rolling back a move makes the old position live again and forgets its chain links. A new position a
  /// remote client already deleted is left alone.
  private func rollbackMove(_ op: IMoveOperation) throws {
    if try getEntryForId(op.changedToEntryId).isDeleted {
      return
    }
    try getEntryForId(op.entryId).isRollback = true
    try updateLiveEntry(op.changedToEntryId, op.entryId)
    let inputEntry = try getEntryForId(op.entryId)
    inputEntry.prevEntryId = nil
    inputEntry.nextEntryId = nil
    inputEntry.isLocalPendingMove = 0
    emitValueChangedEvent(
      .move(
        IMoveOperation(
          entryId: op.changedToEntryId, insertAfterEntryId: nil, changedToEntryId: op.entryId)),
      isLocal: true)
  }

  // MARK: Sequenced operations

  public override func processMessagesCore(_ contents: [Content], local: Bool) throws {
    for content in contents {
      try processMessage(content.message, local: local)
    }
  }

  /// `processMessage`: a remote op emits `valueChanged` with the original op after it is applied, even if the
  /// conflict rules suppressed every visible change. A local ack changes only the pending flags and counters.
  private func processMessage(_ message: SequencedMessage, local: Bool) throws {
    guard message.type == MessageType.operation else {
      return
    }
    let op = try ISharedArrayOperation(json: message.contents, serializer: serializer)
    switch op {
    case .insert(let insert):
      try handleInsertOp(insert.entryId, insert.insertAfterEntryId, local, insert.value)
    case .delete(let delete):
      try handleDeleteOp(delete, local)
    case .move(let move):
      try handleMoveOp(move, local)
    case .toggle(let toggle):
      try handleToggleOp(toggle, local)
    case .toggleMove(let toggleMove):
      try handleToggleMoveOp(toggleMove, local)
    }
    if !local {
      emitValueChangedEvent(op, isLocal: local)
    }
  }

  /// A local insert is acknowledged. A remote one goes after its anchor (or first, when the anchor is unknown),
  /// then past every consecutive entry still awaiting its ack, so a local pending insert stays ahead of it.
  private func handleInsertOp(
    _ entryId: JSString, _ insertAfterEntryId: JSString?, _ local: Bool, _ value: FluidValue
  ) throws {
    if local {
      try getEntryForId(entryId).isAckPending = false
      return
    }
    var index = 0
    if let insertAfterEntryId {
      index = findIndexOfEntryId(insertAfterEntryId) + 1
    }
    let newEntry = SharedArrayEntry(entryId: entryId, value: value)
    newEntry.isAckPending = false
    try addEntry(getInternalInsertIndexByIgnoringLocalPendingInserts(index), newEntry)
  }

  /// A local delete is acknowledged. A remote one is only remembered when the chain has a pending local delete;
  /// otherwise the live end of the chain is deleted.
  private func handleDeleteOp(_ op: IDeleteOperation, _ local: Bool) throws {
    let opEntry = try getEntryForId(op.entryId)
    if local {
      opEntry.isLocalPendingDelete -= 1
      remoteDeleteWithLocalPendingDelete.remove(op.entryId)
    } else if try isLocalPending(op.entryId, .delete) {
      remoteDeleteWithLocalPendingDelete.insert(op.entryId)
    } else {
      try getLiveEntry(op.entryId).isDeleted = true
    }
  }

  /// The new position is inserted like any insert. A local move is then acknowledged. A remote move on a chain
  /// with a local pending delete or move leaves the new position dead after the addressed entry (the local op
  /// wins); otherwise it becomes the live end of the chain, deleted if that end was.
  private func handleMoveOp(_ op: IMoveOperation, _ local: Bool) throws {
    let opEntry = try getEntryForId(op.entryId)
    try handleInsertOp(op.changedToEntryId, op.insertAfterEntryId, local, opEntry.value)
    if local {
      opEntry.isLocalPendingMove -= 1
      return
    }
    let newElement = try getEntryForId(op.changedToEntryId)
    if try isLocalPending(op.entryId, .delete) || isLocalPending(op.entryId, .move) {
      try updateDeadEntry(op.entryId, op.changedToEntryId)
    } else {
      let liveEntry = try getLiveEntry(op.entryId)
      let isDeleted = liveEntry.isDeleted
      try updateLiveEntry(liveEntry.entryId, op.changedToEntryId)
      if isDeleted {
        newElement.isDeleted = isDeleted
      }
    }
  }

  /// A local toggle is acknowledged (the counter drops only if it is truthy). A remote one applies its explicit
  /// `isDeleted` to the live end of the chain unless the chain has a pending local delete.
  private func handleToggleOp(_ op: IToggleOperation, _ local: Bool) throws {
    let opEntry = try getEntryForId(op.entryId)
    if local {
      if opEntry.isLocalPendingDelete != 0 {
        opEntry.isLocalPendingDelete -= 1
      }
    } else if try !isLocalPending(op.entryId, .delete) {
      try getLiveEntry(op.entryId).isDeleted = op.isDeleted
    }
  }

  /// A local toggleMove is acknowledged (only if its counter is truthy). A remote one makes the addressed
  /// entry live again, only when the chain has no pending delete or move and its live end is not deleted;
  /// `changedToEntryId` is not used on that branch.
  private func handleToggleMoveOp(_ op: IToggleMoveOperation, _ local: Bool) throws {
    let opEntry = try getEntryForId(op.entryId)
    if local {
      if opEntry.isLocalPendingMove != 0 {
        opEntry.isLocalPendingMove -= 1
      }
    } else if try !isLocalPending(op.entryId, .delete), try !isLocalPending(op.entryId, .move),
      try getLiveEntry(op.entryId).isDeleted == false
    {
      try updateLiveEntry(getLiveEntry(op.entryId).entryId, op.entryId)
    }
  }

  // MARK: Stashed operations

  /// `applyStashedOp`: applies the op with its original identities, emits no event and no revertible, then
  /// submits the original op. An insert does not skip pending inserts, and a toggleMove has no remote-style guard.
  public override func applyStashedOp(_ content: JSONValue) throws {
    switch try ISharedArrayOperation(json: content, serializer: serializer) {
    case .insert(let op):
      handleStashedInsert(op.entryId, op.insertAfterEntryId, op.value)
    case .delete(let op):
      try getLiveEntry(op.entryId).isDeleted = true
      try getEntryForId(op.entryId).isLocalPendingDelete += 1
    case .move(let op):
      try applyStashedMove(op)
    case .toggle(let op):
      try getLiveEntry(op.entryId).isDeleted = op.isDeleted
      try getEntryForId(op.entryId).isLocalPendingDelete += 1
    case .toggleMove(let op):
      try updateLiveEntry(getLiveEntry(op.entryId).entryId, op.entryId)
      try getEntryForId(op.entryId).isLocalPendingMove += 1
    }
    try submitLocalMessage(content, ())
  }

  private func handleStashedInsert(
    _ entryId: JSString, _ insertAfterEntryId: JSString?, _ value: FluidValue
  ) {
    var index = 0
    if let insertAfterEntryId {
      index = findIndexOfEntryId(insertAfterEntryId) + 1
    }
    addEntry(index, SharedArrayEntry(entryId: entryId, value: value))
  }

  private func applyStashedMove(_ op: IMoveOperation) throws {
    let opEntry = try getEntryForId(op.entryId)
    handleStashedInsert(op.changedToEntryId, op.insertAfterEntryId, opEntry.value)
    let newElement = try getEntryForId(op.changedToEntryId)
    if try isLocalPending(op.entryId, .delete) || isLocalPending(op.entryId, .move) {
      try updateDeadEntry(op.entryId, op.changedToEntryId)
    } else {
      let liveEntry = try getLiveEntry(op.entryId)
      let isDeleted = liveEntry.isDeleted
      try updateLiveEntry(liveEntry.entryId, op.changedToEntryId)
      if isDeleted {
        newElement.isDeleted = isDeleted
      }
    }
    opEntry.isLocalPendingMove += 1
  }

  // MARK: Events

  private func emitValueChangedEvent(_ op: ISharedArrayOperation, isLocal: Bool) {
    valueChanged?(op, isLocal, self)
  }

  private func emitRevertibleEvent(_ op: ISharedArrayOperation) {
    revertible?(SharedArrayRevertible(self, op))
  }

  // MARK: Physical list

  /// `getEntryForId`. TS casts the lookup and then dereferences it, so a missing ID throws there.
  private func getEntryForId(_ entryId: JSString) throws -> SharedArrayEntry {
    guard let entry = idToEntryMap[entryId] else {
      throw SharedObjectError("TypeError: no SharedArray entry has the ID \(entryId)")
    }
    return entry
  }

  /// `this.sharedArray[index]`, which is `undefined` outside the list.
  private func physicalEntry(at index: Int) -> SharedArrayEntry? {
    sharedArray.indices.contains(index) ? sharedArray[index] : nil
  }

  /// `findInternalIndex`: the physical index of the live entry `countEntries` live entries from the start.
  private func findInternalIndex(_ countEntries: Int) throws -> Int {
    guard countEntries >= 0 else {
      throw SharedObjectError("Input count is zero")
    }
    var countDown = countEntries
    for (index, entry) in sharedArray.enumerated() where !entry.isDeleted {
      if countDown == 0 {
        return index
      }
      countDown -= 1
    }
    throw SharedObjectError("Count of live entries is less than required")
  }

  private func findInternalInsertionIndex(_ index: Int) throws -> Int {
    index == 0 ? index : try findInternalIndex(index - 1) + 1
  }

  private func findInternalDeletionIndex(_ index: Int) throws -> Int {
    try findInternalIndex(index)
  }

  private func createAddEntry(_ index: Int, _ value: FluidValue) -> JSString {
    let newEntry = SharedArrayEntry(entryId: generateEntryId(), value: value)
    addEntry(index, newEntry)
    return newEntry.entryId
  }

  /// `addEntry`: splices at `insertIndex`. JS `splice` clamps an index past the end, so this appends.
  private func addEntry(_ insertIndex: Int, _ newEntry: SharedArrayEntry) {
    if insertIndex >= sharedArray.count {
      sharedArray.append(newEntry)
    } else {
      sharedArray.insert(newEntry, at: insertIndex)
    }
    idToEntryMap[newEntry.entryId] = newEntry
  }

  /// `deleteCore`.
  private func deleteCore(_ index: Int) throws {
    guard let entry = physicalEntry(at: index) else {
      throw SharedObjectError("0xb94: Invalid index")
    }
    if entry.isDeleted {
      throw SharedObjectError("Entry already deleted.")
    }
    entry.isDeleted = true
    entry.isLocalPendingDelete += 1
  }

  /// `createMoveEntry`: the old position is marked deleted and linked to the new one, which holds the same value.
  private func createMoveEntry(_ oldIndex: Int, _ newIndex: Int) throws -> JSString {
    guard let oldEntry = physicalEntry(at: oldIndex) else {
      throw SharedObjectError("0xb95: Invalid index")
    }
    let newEntry = SharedArrayEntry(
      entryId: generateEntryId(), value: oldEntry.value, prevEntryId: oldEntry.entryId)
    oldEntry.isDeleted = true
    oldEntry.nextEntryId = newEntry.entryId
    oldEntry.isLocalPendingMove += 1
    addEntry(newIndex, newEntry)
    return newEntry.entryId
  }

  /// `getInternalInsertIndexByIgnoringLocalPendingInserts`: the first index from `startIndex` whose entry is
  /// not awaiting its ack.
  private func getInternalInsertIndexByIgnoringLocalPendingInserts(_ startIndex: Int) throws -> Int {
    var index = startIndex
    while index < sharedArray.count {
      guard let entry = physicalEntry(at: index) else {
        throw SharedObjectError("0xb96: Invalid index")
      }
      if !entry.isAckPending {
        break
      }
      index += 1
    }
    return index
  }

  /// `findIndexOfEntryId`: a scan of the physical list, -1 when absent.
  private func findIndexOfEntryId(_ entryId: JSString?) -> Int {
    guard let entryId else {
      return -1
    }
    return sharedArray.firstIndex { $0.entryId == entryId } ?? -1
  }

  // MARK: Chains

  /// `getLiveEntry`: follows truthy `nextEntryId` links to the end of the chain, which may be deleted.
  private func getLiveEntry(_ entryId: JSString) throws -> SharedArrayEntry {
    var liveEntry = try getEntryForId(entryId)
    while let next = liveEntry.nextEntryId, next.length != 0 {
      liveEntry = try getEntryForId(next)
    }
    return liveEntry
  }

  /// `isLocalPending`: the addressed entry's counter is tested with `> 0`, every other entry along the chain,
  /// backward then forward, with truthiness, so a negative counter counts.
  private func isLocalPending(_ entryId: JSString, _ counter: PendingCounter) throws -> Bool {
    let inputEntry = try getEntryForId(entryId)
    var prevEntryId = inputEntry.prevEntryId
    var nextEntryId = inputEntry.nextEntryId
    if counter.value(of: inputEntry) > 0 {
      return true
    }
    while let id = prevEntryId, id.length != 0 {
      let prevEntry = try getEntryForId(id)
      if counter.value(of: prevEntry) != 0 {
        return true
      }
      prevEntryId = prevEntry.prevEntryId
    }
    while let id = nextEntryId, id.length != 0 {
      let nextEntry = try getEntryForId(id)
      if counter.value(of: nextEntry) != 0 {
        return true
      }
      nextEntryId = nextEntry.nextEntryId
    }
    return false
  }

  /// `prepareToMakeEntryIdLive`: unlinks the entry from its chain neighbors (found by scanning the physical
  /// list) and clears its own links.
  private func prepareToMakeEntryIdLive(_ entry: SharedArrayEntry) throws {
    let prevIndex = findIndexOfEntryId(entry.prevEntryId)
    let nextIndex = findIndexOfEntryId(entry.nextEntryId)
    if prevIndex != -1 {
      guard let prevEntry = physicalEntry(at: prevIndex) else {
        throw SharedObjectError("0xb97: Invalid index")
      }
      prevEntry.nextEntryId = entry.nextEntryId
    }
    if nextIndex != -1 {
      guard let nextEntry = physicalEntry(at: nextIndex) else {
        throw SharedObjectError("0xb98: Invalid index")
      }
      nextEntry.prevEntryId = entry.prevEntryId
    }
    entry.prevEntryId = nil
    entry.nextEntryId = nil
  }

  /// `updateLiveEntry`: the new position becomes the end of the old one's chain, live, and the old one dead. The
  /// same ID only revives the entry.
  private func updateLiveEntry(_ oldLiveEntryEntryId: JSString, _ newLiveEntryEntryId: JSString) throws {
    let oldLiveEntry = try getEntryForId(oldLiveEntryEntryId)
    let newLiveEntry = try getEntryForId(newLiveEntryEntryId)
    if oldLiveEntryEntryId == newLiveEntryEntryId {
      oldLiveEntry.isDeleted = false
      return
    }
    try prepareToMakeEntryIdLive(newLiveEntry)
    oldLiveEntry.nextEntryId = newLiveEntryEntryId
    newLiveEntry.prevEntryId = oldLiveEntryEntryId
    newLiveEntry.isDeleted = false
    oldLiveEntry.isDeleted = true
  }

  /// `updateDeadEntry`: the dead entry is spliced into the chain right after the existing one.
  private func updateDeadEntry(_ existingEntryId: JSString, _ deadEntryId: JSString) throws {
    let existingEntry = try getEntryForId(existingEntryId)
    let deadEntry = try getEntryForId(deadEntryId)
    if let next = existingEntry.nextEntryId {
      deadEntry.nextEntryId = next
      try getEntryForId(next).prevEntryId = deadEntryId
    }
    existingEntry.nextEntryId = deadEntryId
    deadEntry.prevEntryId = existingEntryId
    deadEntry.isDeleted = true
  }
}
