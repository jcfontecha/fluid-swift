import Testing
import FluidJS
@testable import FluidContainerRuntime
import FluidTestRuntimeUtils

private func runtime() throws -> ContainerRuntime {
  try ContainerRuntime(sessionId: "10000000-0000-4000-8000-000000000001", clientId: "self", deltaManager: MockDeltaManager(), quorum: MockQuorumClients())
}

private let localOp = object([("type", string("component")), ("contents", object([("address", string("store")), ("contents", object([("type", string("op")), ("content", object([]))]))]))])

@Suite struct ScheduleFlushTests {
  /// containerRuntime.ts scheduleFlush, TurnBased: the first op of a turn schedules one flush,
  /// nothing is sent until it runs, and the flush rearms it.
  @Test func turnBasedSubmitsScheduleOneFlushPerTurn() throws {
    let runtime = try runtime()
    var scheduled = 0
    runtime.onScheduleFlush = { scheduled += 1 }
    var wire: [[JSONValue]] = []
    runtime.onSubmit = { batch, _, _ in wire.append(batch) }
    try runtime.submit(localOp)
    try runtime.submit(localOp)
    #expect(scheduled == 1)
    #expect(wire.isEmpty)
    try runtime.flush()
    #expect(wire.count == 1)
    try runtime.submit(localOp)
    #expect(scheduled == 2)
  }

  /// containerRuntime.ts process: an inbound message flushes the open local batch before it is
  /// processed, so the batch keeps the reference sequence number its ops were made at.
  @Test func inboundMessageFlushesTheOpenBatchFirst() throws {
    let runtime = try runtime()
    var trace: [String] = []
    runtime.onSubmit = { batch, _, _ in
      trace.append("submit at \(try batch[0].member("referenceSequenceNumber").asInt())")
    }
    runtime.onEvent = { name, _ in trace.append(name.description) }
    try runtime.submit(localOp)
    _ = try runtime.process(JSON.parse(#"{"type":"op","clientId":"other","clientSequenceNumber":1,"sequenceNumber":1,"minimumSequenceNumber":0,"referenceSequenceNumber":0,"timestamp":0,"contents":{"type":"component","contents":{"address":"store","contents":{"type":"op","content":{}}}}}"#))
    #expect(trace == ["submit at 0", "batchBegin", "op", "batchEnd"])
    #expect(runtime.referenceSequenceNumber == 1)
  }

  /// FlushMode.Immediate is deprecated in TS and not ported; TurnBased (1) is the default.
  @Test func onlyTurnBasedFlushModeIsAccepted() throws {
    #expect(throws: JSONDecodingError.self) {
      try ContainerRuntime(sessionId: "10000000-0000-4000-8000-000000000001", clientId: "a", deltaManager: MockDeltaManager(), quorum: MockQuorumClients(), runtimeOptions: object([("flushMode", number(0))]))
    }
    _ = try ContainerRuntime(sessionId: "10000000-0000-4000-8000-000000000001", clientId: "a", deltaManager: MockDeltaManager(), quorum: MockQuorumClients(), runtimeOptions: object([("flushMode", number(1))]))
  }
}

/// Busy-waits past `duration`, as a long batch would.
private func spin(past duration: Duration) {
  let clock = ContinuousClock()
  let start = clock.now
  while clock.now - start <= duration {}
}

@Suite struct DeltaSchedulerTests {
  /// deltaScheduler.ts batchEnd: it pauses only once the slice is spent and more ops are queued.
  @Test func pausesAtABatchEndOnlyOnceTheSliceIsSpentWithMoreQueued() {
    var queued = 1
    let scheduler = DeltaScheduler(inboundLength: { queued })
    scheduler.batchBegin()
    scheduler.batchEnd()
    #expect(!scheduler.paused)
    spin(past: DeltaScheduler.processingTime)
    queued = 0
    scheduler.batchEnd()
    #expect(!scheduler.paused)
    queued = 1
    scheduler.batchEnd()
    #expect(scheduler.paused)
    scheduler.resume()
    #expect(!scheduler.paused)
    // A pause ends the slice; the next batch starts a new one.
    scheduler.batchBegin()
    scheduler.batchEnd()
    #expect(!scheduler.paused)
  }

  /// deltaScheduler.ts inboundQueueIdle: an emptied queue ends the run, so the next run gets a
  /// whole slice.
  @Test func idleQueueStartsANewSlice() {
    let scheduler = DeltaScheduler(inboundLength: { 1 })
    scheduler.batchBegin()
    spin(past: DeltaScheduler.processingTime)
    scheduler.inboundQueueIdle()
    scheduler.batchBegin()
    scheduler.batchEnd()
    #expect(!scheduler.paused)
  }
}
