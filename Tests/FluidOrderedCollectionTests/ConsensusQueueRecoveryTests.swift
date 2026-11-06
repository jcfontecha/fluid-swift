import FluidDriverDefinitions
import FluidJS
import FluidOrderedCollection
import FluidSharedObjectBase
import FluidTestRuntimeUtils
import Testing

/// Port of the Reconnection, applyStashedOp and Rollback suites in
/// `packages/dds/ordered-collection/src/test/consensusOrderedCollection.spec.ts`, plus client-leave release
/// (`removeMember`, consensusOrderedCollection.ts) and the summary blobs (`summarizeCore`, `loadCore`).
@Suite("ConsensusQueue recovery")
struct ConsensusQueueRecoveryTests {
  /// Two attached collections on one sequencer, as TS `createCollectionForReconnection` builds them.
  struct Pair {
    let factory: MockContainerRuntimeFactory<ConsensusQueue>
    let queue1: ConsensusQueue
    let runtime1: MockContainerRuntime<ConsensusQueue>
    let queue2: ConsensusQueue
    let runtime2: MockContainerRuntime<ConsensusQueue>
  }

  func makePair(flushMode: FlushMode = .immediate) -> Pair {
    let factory = MockContainerRuntimeFactory<ConsensusQueue>()
    let queue1 = ConsensusQueue(id: "collection1")
    let runtime1 = factory.createContainerRuntime(clientId: "A", channel: queue1, flushMode: flushMode)
    let queue2 = ConsensusQueue(id: "collection2")
    let runtime2 = factory.createContainerRuntime(clientId: "B", channel: queue2, flushMode: flushMode)
    return Pair(
      factory: factory, queue1: queue1, runtime1: runtime1, queue2: queue2, runtime2: runtime2)
  }

  /// TS `processAcquireMessages`: flush and process twice, as the second pass runs after the first's continuations.
  func processAcquireMessages(_ pair: Pair) throws {
    pair.runtime1.flush()
    pair.runtime2.flush()
    try pair.factory.processAllMessages()
    pair.runtime1.flush()
    pair.runtime2.flush()
    try pair.factory.processAllMessages()
  }

  // MARK: Reconnection

  @Test("can resend unacked ops on reconnection")
  func canResendUnackedOpsOnReconnection() throws {
    let pair = makePair()
    var added: [(FluidValue, Bool)] = []
    pair.queue2.addEvent = { value, fresh in added.append((value, fresh)) }

    try pair.queue1.add(str("testValue"))
    pair.runtime1.disconnect()
    try pair.runtime1.reconnect(clientId: "A")
    try pair.factory.processAllMessages()

    #expect(added.count == 1)
    #expect(added.first?.0 == str("testValue"))
    #expect(added.first?.1 == true)

    var acquiredValue: FluidValue?
    var acquireClient: JSString??
    pair.queue2.acquireEvent = { _, clientId in acquireClient = .some(clientId) }
    try pair.queue1.acquire({ value in
      acquiredValue = value
      return .complete
    })
    pair.runtime1.disconnect()
    try pair.runtime1.reconnect(clientId: "A")
    try pair.factory.processAllMessages()

    #expect(acquiredValue == str("testValue"))
    #expect(acquireClient == .some(JSString("A")))
  }

  @Test("can store ops in disconnected state and resend them on reconnection")
  func canStoreOpsWhileDisconnected() throws {
    let pair = makePair()
    var added: [(FluidValue, Bool)] = []
    pair.queue2.addEvent = { value, fresh in added.append((value, fresh)) }

    pair.runtime1.disconnect()
    try pair.queue1.add(str("testValue"))
    try pair.runtime1.reconnect(clientId: "A")
    try pair.factory.processAllMessages()

    #expect(added.count == 1)
    #expect(added.first?.0 == str("testValue"))
    #expect(added.first?.1 == true)
  }

  // MARK: applyStashedOp

  @Test("can apply stashed add op and have it reach remote client")
  func stashedAddReachesRemoteClient() throws {
    let pair = makePair()
    var stashed = JSObject<JSONValue>()
    stashed["opName"] = .string("add")
    stashed["value"] = .string(JSString(#""testValue""#))

    try pair.queue1.applyStashedOp(.object(stashed))
    try pair.factory.processAllMessages()

    var result: FluidValue?
    try pair.queue2.acquire({ value in
      result = value
      return .complete
    })
    try pair.factory.processAllMessages()
    #expect(result == str("testValue"))
  }

  @Test("can apply stashed acquire op")
  func stashedAcquireFiresRemoteAcquire() throws {
    let pair = makePair()
    try pair.queue1.add(str("testValue"))
    try pair.factory.processAllMessages()

    var acquireFired = false
    pair.queue2.acquireEvent = { _, _ in acquireFired = true }
    var stashed = JSObject<JSONValue>()
    stashed["opName"] = .string("acquire")
    stashed["acquireId"] = .string("test-acquire-id")
    try pair.queue1.applyStashedOp(.object(stashed))
    try pair.factory.processAllMessages()

    #expect(acquireFired)
  }

  @Test("can apply stashed complete op after acquire")
  func stashedCompleteFiresRemoteComplete() throws {
    let pair = makePair()
    try pair.queue1.add(str("testValue"))
    try pair.factory.processAllMessages()
    let acquireId = JSString("test-acquire-id")
    var acquireOp = JSObject<JSONValue>()
    acquireOp["opName"] = .string("acquire")
    acquireOp["acquireId"] = .string(acquireId)
    try pair.queue1.applyStashedOp(.object(acquireOp))
    try pair.factory.processAllMessages()

    var completeFired = false
    pair.queue2.completeEvent = { _ in completeFired = true }
    var completeOp = JSObject<JSONValue>()
    completeOp["opName"] = .string("complete")
    completeOp["acquireId"] = .string(acquireId)
    try pair.queue1.applyStashedOp(.object(completeOp))
    try pair.factory.processAllMessages()

    #expect(completeFired)
  }

  @Test("can apply stashed release op after acquire")
  func stashedReleaseReturnsValueToQueue() throws {
    let pair = makePair()
    try pair.queue1.add(str("testValue"))
    try pair.factory.processAllMessages()
    let acquireId = JSString("test-acquire-id")
    var acquireOp = JSObject<JSONValue>()
    acquireOp["opName"] = .string("acquire")
    acquireOp["acquireId"] = .string(acquireId)
    try pair.queue1.applyStashedOp(.object(acquireOp))
    try pair.factory.processAllMessages()

    var addFired = false
    pair.queue2.addEvent = { _, fresh in
      if !fresh {
        addFired = true
      }
    }
    var releaseOp = JSObject<JSONValue>()
    releaseOp["opName"] = .string("release")
    releaseOp["acquireId"] = .string(acquireId)
    try pair.queue1.applyStashedOp(.object(releaseOp))
    try pair.factory.processAllMessages()

    #expect(addFired)
    var result: FluidValue?
    try pair.queue2.acquire({ value in
      result = value
      return .complete
    })
    try pair.factory.processAllMessages()
    #expect(result == str("testValue"))
  }

  // MARK: Rollback

  @Test("can rollback add op")
  func canRollbackAddOp() throws {
    let pair = makePair(flushMode: .turnBased)
    var addFired = false
    pair.queue1.addEvent = { _, _ in addFired = true }
    var settled = false
    try pair.queue1.add(str("value"), onSettled: { settled = true })
    try pair.runtime1.rollback()
    pair.runtime1.flush()
    try pair.factory.processAllMessages()

    #expect(settled)
    #expect(!addFired)
    try processAcquireMessages(pair)
    var acquired: FluidValue?
    try pair.queue1.acquire({ value in
      acquired = value
      return .complete
    })
    try processAcquireMessages(pair)
    #expect(acquired == nil)
  }

  @Test("can rollback acquire/complete ops")
  func canRollbackAcquireComplete() throws {
    let pair = makePair(flushMode: .turnBased)
    var acquireFired = false
    var completeFired = false
    pair.queue1.acquireEvent = { _, _ in acquireFired = true }
    pair.queue1.completeEvent = { _ in completeFired = true }
    try pair.queue1.add(str("value"))
    pair.runtime1.flush()
    try pair.factory.processAllMessages()

    var first: FluidValue?
    var firstResult: Bool?
    try pair.queue1.acquire(
      { value in
        first = value
        return .complete
      },
      onSettled: { firstResult = $0 })
    try pair.runtime1.rollback()
    try processAcquireMessages(pair)
    #expect(first == nil)
    #expect(firstResult == false)
    #expect(!acquireFired)
    #expect(!completeFired)

    var second: FluidValue?
    try pair.queue1.acquire({ value in
      second = value
      return .complete
    })
    try processAcquireMessages(pair)
    #expect(second == str("value"))
    #expect(acquireFired)
    #expect(completeFired)
  }

  @Test("can rollback only the complete op")
  func canRollbackOnlyTheCompleteOp() throws {
    let pair = makePair(flushMode: .turnBased)
    var acquireFired = false
    var completeFired = false
    pair.queue1.acquireEvent = { _, _ in acquireFired = true }
    pair.queue1.completeEvent = { _ in completeFired = true }
    try pair.queue1.add(str("value"))
    pair.runtime1.flush()
    try pair.factory.processAllMessages()

    var acquired: FluidValue?
    var acquireResult: Bool?
    try pair.queue1.acquire(
      { value in
        acquired = value
        return .complete
      },
      onSettled: { acquireResult = $0 })
    pair.runtime1.flushSomeMessages(1)
    try pair.factory.processAllMessages()
    try pair.runtime1.rollback()
    pair.runtime1.flush()
    try pair.factory.processAllMessages()

    #expect(acquired == str("value"))
    #expect(acquireResult == true)
    #expect(acquireFired)
    #expect(!completeFired)
  }

  @Test("can rollback add across remote ops")
  func canRollbackAddAcrossRemoteOps() throws {
    let pair = makePair(flushMode: .turnBased)
    var addCount1 = 0
    var addCount2 = 0
    pair.queue1.addEvent = { _, _ in addCount1 += 1 }
    pair.queue2.addEvent = { _, _ in addCount2 += 1 }
    try pair.queue1.add(str("value1"))
    try pair.queue2.add(str("value2"))
    try pair.runtime1.rollback()
    pair.runtime1.flush()
    pair.runtime2.flush()
    try pair.factory.processAllMessages()

    #expect(addCount1 == 1)
    #expect(addCount2 == 1)
    var first: FluidValue?
    try pair.queue1.acquire({ value in
      first = value
      return .complete
    })
    try processAcquireMessages(pair)
    #expect(first == str("value2"))
    var second: FluidValue?
    try pair.queue1.acquire({ value in
      second = value
      return .complete
    })
    try processAcquireMessages(pair)
    #expect(second == nil)
  }

  // MARK: Client leave

  @Test("a leaving client's acquired jobs return to the queue, in acquisition order")
  func clientLeaveRequeuesJobs() throws {
    let pair = makePair()
    var added: [(FluidValue, Bool)] = []
    pair.queue1.addEvent = { value, fresh in added.append((value, fresh)) }
    try pair.queue1.add(num(1))
    try pair.queue1.add(num(2))
    try pair.factory.processAllMessages()

    // B acquires but does not complete: its acquire ACK runs, the complete op is still queued.
    try pair.queue2.acquire({ _ in .complete })
    try pair.factory.processOneMessage()
    added.removeAll()

    pair.runtime2.disconnect()
    #expect(added.count == 1)
    #expect(added.first?.0 == num(1))
    #expect(added.first?.1 == false)

    var next: FluidValue?
    try pair.queue1.acquire({ value in
      next = value
      return .complete
    })
    try pair.factory.processAllMessages()
    // The requeued job goes to the tail, behind the item that was still queued (TS `data.add`).
    #expect(next == num(2))
  }

  // MARK: Summary and load

  @Test("summary blobs are byte-exact for a job held by a client")
  func summaryBlobsAreByteExact() throws {
    let factory = MockContainerRuntimeFactory<ConsensusQueue>()
    let queue = ConsensusQueue(id: "q")
    queue.generateAcquireId = { "2c37cf9a-d973-4c6f-9d42-83d37de05e11" }
    _ = factory.createContainerRuntime(clientId: "c", channel: queue)
    try queue.add(num(1))
    try queue.add(num(2))
    try factory.processAllMessages()
    try queue.acquire({ _ in .complete })
    try factory.processOneMessage()

    let summary = queue.summarize()
    #expect(try blobContent(summary, "header") == "[2]")
    #expect(
      try blobContent(summary, "jobTracking")
        == #"[["2c37cf9a-d973-4c6f-9d42-83d37de05e11",{"value":1,"clientId":"c"}]]"#)
  }

  @Test("an empty collection summarizes as two empty arrays")
  func emptySummary() throws {
    let queue = ConsensusQueue(id: "q")
    let summary = queue.summarize()
    #expect(try blobContent(summary, "header") == "[]")
    #expect(try blobContent(summary, "jobTracking") == "[]")
  }

  @Test("a summary loads into an equivalent collection")
  func summaryRoundTrip() throws {
    let queue = ConsensusQueue(id: "q")
    let factory = MockContainerRuntimeFactory<ConsensusQueue>()
    _ = factory.createContainerRuntime(clientId: "A", channel: queue)
    try queue.add(str("x"))
    try queue.add(str("y"))
    try factory.processAllMessages()
    let summary = queue.summarize()

    let loaded = try ConsensusQueue.load(id: "q", summary: summary)
    let loadedFactory = MockContainerRuntimeFactory<ConsensusQueue>()
    _ = loadedFactory.createContainerRuntime(clientId: "B", channel: loaded)
    var acquired: FluidValue?
    try loaded.acquire({ value in
      acquired = value
      return .complete
    })
    try loadedFactory.processAllMessages()
    #expect(acquired == str("x"))
    #expect(try blobContent(loaded.summarize(), "header") == #"["y"]"#)
  }
}
