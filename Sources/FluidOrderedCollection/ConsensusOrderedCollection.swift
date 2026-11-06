import Foundation
import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase

/// The result of a successful acquire: its acquire ID and the item. Port of `IConsensusOrderedCollectionValue`
/// in `consensusOrderedCollection.ts`.
public struct ConsensusAcquisition: Equatable, Sendable {
  public let acquireId: JSString
  public let value: FluidValue

  public init(acquireId: JSString, value: FluidValue) {
    self.acquireId = acquireId
    self.value = value
  }
}

/// A job a client has acquired and not yet completed or released. Port of `JobTrackingInfo`'s value in
/// `consensusOrderedCollection.ts`.
struct ConsensusJob {
  let value: FluidValue

  /// nil for a job acquired while detached.
  let clientId: JSString?
}

/// `localOpMetadata` of a submitted op. TS keeps a resolve function here. For an add it also keeps the
/// caller's value, because TS's `deserializedValue` is that same object when the op is acknowledged locally.
public struct ConsensusLocalOpMetadata {
  /// The add's value as the caller passed it. nil for other ops and for stashed adds.
  let deserializedValue: FluidValue?

  /// Called with the acquisition on an acquire's ACK, and with nil otherwise (other ACKs and rollback).
  let resolve: (ConsensusAcquisition?) -> Void

  init(deserializedValue: FluidValue?, resolve: @escaping (ConsensusAcquisition?) -> Void) {
    self.deserializedValue = deserializedValue
    self.resolve = resolve
  }
}

/// Port of `packages/dds/ordered-collection/src/consensusOrderedCollection.ts` ConsensusOrderedCollection.
///
/// A sequenced work queue with exclusive acquisition. An attached add, acquire, complete or release changes
/// the collection only when it is sequenced. Acquired items are tracked by acquire ID until they are completed
/// or released, and a client that leaves the quorum returns its items to the collection.
///
/// TS Promises become `onSettled` callbacks. TS runs a Promise continuation as a microtask, after the current
/// operation. Here each continuation is queued and drained before the public call that caused it returns.
open class ConsensusOrderedCollection<Storage: IOrderedCollection>: SharedObject<ConsensusLocalOpMetadata> {
  /// The `callback` of `acquire`: returns whether the item completed or goes back to the collection.
  public typealias Callback = (FluidValue) throws -> ConsensusResult

  /// The Promise of an add or a complete: runs once the op is acknowledged or rolled back.
  public typealias Settled = () throws -> Void

  /// The Promise<boolean> of an acquire: true when the callback ran.
  public typealias AcquireSettled = (Bool) throws -> Void

  private static var snapshotFileNameData: JSString { "header" }
  private static var snapshotFileNameTracking: JSString { "jobTracking" }

  private let serializer = FluidSerializer()

  /// `data`: the items, in the order the collection will hand them out.
  private var data = Storage()

  /// `jobTracking`: acquired items by acquire ID, in acquisition order (a JS `Map`).
  private var jobTracking = JSMap<JSString, ConsensusJob>()

  /// Continuations that TS would run as microtasks, in the order they were queued.
  private var continuations: [Settled] = []

  /// Set while `continuations` is being drained. A nested drain returns at once, so the outer loop runs
  /// the queued continuations in order.
  private var isDrainingContinuations = false

  /// One-shot listeners for the next add, as TS `this.once("add", resolve)`.
  private var addWaiters: [() -> Void] = []

  /// Source of acquire IDs. TS calls `uuid()`. The harness replaces it, because it needs deterministic IDs.
  public var generateAcquireId: () -> JSString = { JSString(UUID().uuidString.lowercased()) }

  /// "add" (value, newlyAdded).
  public var addEvent: ((FluidValue, Bool) -> Void)?

  /// "acquire" (value, clientId). clientId is nil for an item acquired while detached.
  public var acquireEvent: ((FluidValue, JSString?) -> Void)?

  /// "complete" (value).
  public var completeEvent: ((FluidValue) -> Void)?

  /// "localRelease" (value, intentional).
  public var localReleaseEvent: ((FluidValue, Bool) -> Void)?

  public required init(id: JSString) {
    super.init(id: id)
  }

  /// `add`: a detached add is cloned through JSON, as it would be on the wire. An attached add is applied when
  /// it is sequenced.
  public func add(_ value: FluidValue, onSettled: @escaping Settled = {}) throws {
    try verifyOpen()
    guard isAttached else {
      try addCore(serializer.parse(serializer.stringify(value)))
      settle(onSettled)
      try drainContinuations()
      return
    }
    let metadata = ConsensusLocalOpMetadata(deserializedValue: value) { [weak self] _ in
      guard let self else { return }
      self.settle(onSettled)
    }
    try submitLocalMessage(addOp(value), metadata)
    try drainContinuations()
  }

  /// `acquire`: takes the next item, if there is one, and runs `callback` with it. The result says whether
  /// the item is completed or released. `onSettled` receives false when the collection was empty.
  public func acquire(_ callback: @escaping Callback, onSettled: @escaping AcquireSettled = { _ in }) throws {
    try verifyOpen()
    try startAcquire(callback, onSettled)
    try drainContinuations()
  }

  /// `waitAndAcquire`: `acquire`, waiting for an add first while the collection is empty. Repeats until an
  /// acquire succeeds.
  public func waitAndAcquire(_ callback: @escaping Callback, onSettled: @escaping Settled = {}) throws {
    try verifyOpen()
    try startWaitAndAcquire(callback, onSettled)
    try drainContinuations()
  }

  /// `summarizeCore`: `header` holds the items and `jobTracking` the acquired ones. Items held by detached
  /// acquisitions are returned first, so the summary carries no undefined-owner records.
  public override func summarize() -> SummaryTree {
    removeClient(nil)
    drainContinuationsOrFail()
    var tree = JSObject<SummaryObject>()
    let header = serializer.stringify(.array(data.asArray()))
    tree[Self.snapshotFileNameData] = .blob(ISummaryBlob(content: .text(JSString(header))))
    let tracking = serializer.stringify(jobTrackingValue())
    tree[Self.snapshotFileNameTracking] = .blob(ISummaryBlob(content: .text(JSString(tracking))))
    return SummaryTree(tree: tree)
  }

  /// `loadCore`: jobTracking is read before header, as TS reads it. A loaded instance is always empty, so
  /// TS's asserts 0x068 and 0x069 cannot fail here.
  public override func loadCore(_ summary: SummaryTree) throws {
    for entry in try summary.readAndParse(Self.snapshotFileNameTracking).asArray() {
      try loadJob(entry)
    }
    let values = try summary.readAndParse(Self.snapshotFileNameData).asArray().map { try serializer.decode($0) }
    try data.loadFrom(values)
  }

  /// `onDisconnect`: each item this client acquired is reported as released, not intentional. The jobs stay
  /// tracked until the quorum removes this client.
  public override func onDisconnect() {
    let ownClientId = runtime?.clientId
    for entry in jobTracking.entries where entry.value.clientId == ownClientId {
      localReleaseEvent?(entry.value.value, false)
    }
  }

  /// The quorum's `removeMember` requeues every job the removed client holds. TS subscribes in the constructor,
  /// which here is the first attach, since the runtime is only known from `connect`.
  public override func didAttach() {
    guard let runtime else {
      preconditionFailure("ConsensusOrderedCollection attached without a runtime")
    }
    runtime.getQuorum().onRemoveMember { [weak self] clientId in
      guard let self else { return }
      precondition(clientId.length > 0, "Missing clientId for removal!")
      self.removeClient(clientId)
      self.drainContinuationsOrFail()
    }
  }

  /// `processMessagesCore`: applies every message in the batch, then runs the continuations those ACKs
  /// queued. TS does the same, because its continuations are microtasks that run after the batch.
  public override func processMessagesCore(_ contents: [Content], local: Bool) throws {
    for content in contents {
      try processMessage(content.message, local: local, localOpMetadata: content.metadata)
    }
    try drainContinuations()
  }

  /// `applyStashedOp`: submits the stashed op as it was created, so its ACK can match. Nothing awaits a stashed
  /// op, so its resolve does nothing.
  public override func applyStashedOp(_ content: JSONValue) throws {
    try submitLocalMessage(content, ConsensusLocalOpMetadata(deserializedValue: nil) { _ in })
  }

  /// `rollback`: the op was never applied locally, so only its Promise settles, with no result.
  public override func rollback(_ content: JSONValue, localOpMetadata: ConsensusLocalOpMetadata) throws {
    localOpMetadata.resolve(nil)
    try drainContinuations()
  }

  // MARK: Acquire and wait

  /// TS `acquire` without the public drain. A continuation calls this, and the drain is already running.
  private func startAcquire(_ callback: @escaping Callback, _ onSettled: @escaping AcquireSettled) throws {
    try acquireInternal { [weak self] acquisition in
      guard let self else { return }
      try self.finishAcquire(acquisition, callback, onSettled)
    }
  }

  /// TS `acquire` after `acquireInternal` resolves.
  private func finishAcquire(
    _ acquisition: ConsensusAcquisition?, _ callback: @escaping Callback,
    _ onSettled: @escaping AcquireSettled
  ) throws {
    guard let acquisition else {
      try onSettled(false)
      return
    }
    switch try callback(acquisition.value) {
    case .complete:
      try complete(acquisition.acquireId) {
        try onSettled(true)
      }
    case .release:
      try release(acquisition.acquireId)
      localReleaseEvent?(acquisition.value, true)
      try onSettled(true)
    }
  }

  /// `acquireInternal`: an attached acquire resolves when its op is sequenced, and a detached one acquires now.
  /// Either way the result reaches `onAcquired` through the continuation queue.
  private func acquireInternal(_ onAcquired: @escaping (ConsensusAcquisition?) throws -> Void) throws {
    guard isAttached else {
      let acquisition = try acquireCore(acquireId: generateAcquireId(), clientId: nil)
      settle {
        try onAcquired(acquisition)
      }
      return
    }
    let metadata = ConsensusLocalOpMetadata(deserializedValue: nil) { [weak self] acquisition in
      guard let self else { return }
      self.settle {
        try onAcquired(acquisition)
      }
    }
    try submitLocalMessage(acquireOp(generateAcquireId()), metadata)
  }

  /// TS `waitAndAcquire` without the public drain.
  private func startWaitAndAcquire(_ callback: @escaping Callback, _ onSettled: @escaping Settled) throws {
    guard data.size() == 0 else {
      try acquireThenRetry(callback, onSettled)
      return
    }
    // Wait for the next add before trying again.
    addWaiters.append { [weak self] in
      guard let self else { return }
      self.settle {
        try self.acquireThenRetry(callback, onSettled)
      }
    }
  }

  /// One pass of TS's `while (!(await this.acquire(callback)))`: done on success, otherwise wait again.
  private func acquireThenRetry(_ callback: @escaping Callback, _ onSettled: @escaping Settled) throws {
    try startAcquire(callback) { [weak self] acquired in
      if acquired {
        try onSettled()
      } else {
        try self?.startWaitAndAcquire(callback, onSettled)
      }
    }
  }

  /// `isActive`: `this.runtime.connected && this.deltaManager.active`.
  private func isActive() throws -> Bool {
    guard connected else {
      return false
    }
    guard let runtime else {
      throw SharedObjectError("ConsensusOrderedCollection is connected but has no runtime")
    }
    return runtime.deltaManager.active
  }

  /// `complete`: an attached complete is applied when sequenced. If the client is not connected, the job was
  /// already released to the queue, as other clients observed, so nothing is sent.
  private func complete(_ acquireId: JSString, onSettled: @escaping Settled) throws {
    guard isAttached else {
      completeCore(acquireId)
      settle(onSettled)
      return
    }
    guard try isActive() else {
      settle(onSettled)
      return
    }
    let metadata = ConsensusLocalOpMetadata(deserializedValue: nil) { [weak self] _ in
      guard let self else { return }
      self.settle(onSettled)
    }
    try submitLocalMessage(completeOp(acquireId), metadata)
  }

  /// `release`: sent without waiting. Nothing settles on it, so its resolve does nothing.
  private func release(_ acquireId: JSString) throws {
    guard isAttached else {
      releaseCore(acquireId)
      return
    }
    // Not connected: the job was already released to the queue, as other clients observed.
    guard try isActive() else {
      return
    }
    try submitLocalMessage(releaseOp(acquireId), ConsensusLocalOpMetadata(deserializedValue: nil) { _ in })
  }

  // MARK: Sequenced effects

  /// `processMessage`: applies one sequenced op. A local op's ACK also resolves its pending Promise.
  private func processMessage(
    _ message: SequencedMessage, local: Bool, localOpMetadata: ConsensusLocalOpMetadata?
  ) throws {
    guard message.type == MessageType.operation else {
      return
    }
    let acquisition = try applyOp(
      message.contents, sender: message.clientId, pending: local ? localOpMetadata : nil)
    guard local else {
      return
    }
    guard let localOpMetadata else {
      throw SharedObjectError("local ordered-collection op has no pending resolve")
    }
    localOpMetadata.resolve(acquisition)
  }

  /// Applies one op. Returns the acquisition for an acquire that succeeded, and nil otherwise.
  private func applyOp(
    _ op: JSONValue, sender: JSString, pending: ConsensusLocalOpMetadata?
  ) throws -> ConsensusAcquisition? {
    switch try op.member("opName").asString() {
    case "add":
      try addCore(addedValue(op, pending: pending))
      return nil
    case "acquire":
      return try acquireCore(acquireId: op.member("acquireId").asString(), clientId: sender)
    case "complete":
      completeCore(try op.member("acquireId").asString())
      return nil
    case "release":
      releaseCore(try op.member("acquireId").asString())
      return nil
    default:
      throw SharedObjectError("unreachable: unknown ordered-collection operation")
    }
  }

  /// TS `op.deserializedValue === undefined ? parse(op.value) : op.deserializedValue`. A local add's value is
  /// the caller's own, so handles stay handles. A remote value is used as the op carries it, and is not
  /// decoded.
  private func addedValue(_ op: JSONValue, pending: ConsensusLocalOpMetadata?) throws -> FluidValue {
    if let value = pending?.deserializedValue {
      return value
    }
    guard let raw = try op.asObject()["deserializedValue"] else {
      return try serializer.parse(try op.member("value").asString().description)
    }
    return .json(raw)
  }

  /// `addCore`: appends the item and emits "add" with newlyAdded set.
  private func addCore(_ value: FluidValue) {
    data.add(value)
    emitAdd(value, fresh: true)
  }

  /// `acquireCore`: takes the next item and tracks it under its acquire ID. Returns nil when the collection is
  /// empty, in which case nothing is tracked and nothing is emitted.
  private func acquireCore(acquireId: JSString, clientId: JSString?) throws -> ConsensusAcquisition? {
    guard data.size() > 0 else {
      return nil
    }
    let value = try data.remove()
    jobTracking.set(acquireId, ConsensusJob(value: value, clientId: clientId))
    acquireEvent?(value, clientId)
    return ConsensusAcquisition(acquireId: acquireId, value: value)
  }

  /// `completeCore`: stops tracking the job. The job may already have been returned to the queue.
  private func completeCore(_ acquireId: JSString) {
    guard let record = jobTracking.get(acquireId) else {
      return
    }
    jobTracking.delete(acquireId)
    completeEvent?(record.value)
  }

  /// `releaseCore`: returns the job's item to the end of the collection, and emits "add" with newlyAdded unset.
  private func releaseCore(_ acquireId: JSString) {
    guard let record = jobTracking.get(acquireId) else {
      return
    }
    jobTracking.delete(acquireId)
    data.add(record.value)
    emitAdd(record.value, fresh: false)
  }

  /// `removeClient`: returns every item the given client holds, in acquisition order. nil selects jobs
  /// acquired while detached.
  private func removeClient(_ clientIdToRemove: JSString?) {
    var added: [FluidValue] = []
    for entry in jobTracking.entries where entry.value.clientId == clientIdToRemove {
      jobTracking.delete(entry.key)
      data.add(entry.value.value)
      added.append(entry.value.value)
    }
    // Raise the events only after all state changes, as TS does.
    for value in added {
      emitAdd(value, fresh: false)
    }
  }

  /// Emits "add", then wakes the one-shot waiters, in the order TS registers them.
  private func emitAdd(_ value: FluidValue, fresh: Bool) {
    addEvent?(value, fresh)
    let waiters = addWaiters
    addWaiters.removeAll()
    for waiter in waiters {
      waiter()
    }
  }

  // MARK: Continuations

  /// Queues a Promise continuation to run after the current operation.
  private func settle(_ work: @escaping Settled) {
    continuations.append(work)
  }

  /// Runs queued continuations in order, including those queued while running.
  private func drainContinuations() throws {
    guard !isDrainingContinuations else {
      return
    }
    isDrainingContinuations = true
    defer { isDrainingContinuations = false }
    while !continuations.isEmpty {
      let work = continuations.removeFirst()
      try work()
    }
  }

  /// `drainContinuations` for entry points that cannot throw: summary and quorum callbacks. A failing
  /// continuation there has no caller to report to, so it stops the peer.
  private func drainContinuationsOrFail() {
    do {
      try drainContinuations()
    } catch {
      preconditionFailure("ConsensusOrderedCollection continuation failed: \(error)")
    }
  }

  // MARK: Summary helpers

  /// The `jobTracking` blob value: `[[acquireId, {value, clientId}], …]`, with `clientId` omitted when undefined.
  private func jobTrackingValue() -> FluidValue {
    .array(
      jobTracking.entries.map { entry -> FluidValue in
        var record = JSObject<FluidValue>()
        record["value"] = entry.value.value
        if let clientId = entry.value.clientId {
          record["clientId"] = .json(.string(clientId))
        }
        return .array([.json(.string(entry.key)), .object(record)])
      })
  }

  /// One `jobTracking` entry from a summary.
  private func loadJob(_ entry: JSONValue) throws {
    let pair = try entry.asArray()
    guard pair.count == 2 else {
      throw SharedObjectError("malformed jobTracking entry")
    }
    let acquireId = try pair[0].asString()
    let record = try pair[1].asObject()
    let value = try record["value"].map { try serializer.decode($0) } ?? .undefined
    let clientId = try record["clientId"]?.asString()
    jobTracking.set(acquireId, ConsensusJob(value: value, clientId: clientId))
  }

  // MARK: Op encoding

  /// `{opName: "add", value: <serialized>, deserializedValue}`. The field is omitted for undefined, as TS omits it.
  private func addOp(_ value: FluidValue) -> JSONValue {
    var op = JSObject<JSONValue>()
    op["opName"] = .string("add")
    op["value"] = .string(JSString(serializer.stringify(value)))
    if value != .undefined {
      op["deserializedValue"] = serializer.encode(value)
    }
    return .object(op)
  }

  private func acquireOp(_ acquireId: JSString) -> JSONValue {
    acquireIdOp("acquire", acquireId)
  }

  private func completeOp(_ acquireId: JSString) -> JSONValue {
    acquireIdOp("complete", acquireId)
  }

  private func releaseOp(_ acquireId: JSString) -> JSONValue {
    acquireIdOp("release", acquireId)
  }

  private func acquireIdOp(_ opName: JSString, _ acquireId: JSString) -> JSONValue {
    var op = JSObject<JSONValue>()
    op["opName"] = .string(opName)
    op["acquireId"] = .string(acquireId)
    return .object(op)
  }
}
