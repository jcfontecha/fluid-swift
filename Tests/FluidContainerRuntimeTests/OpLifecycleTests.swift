import Testing
import FluidJS
@testable import FluidContainerRuntime

private func op(_ text: String = "x", ref: Int = 0, staged: Bool = false) -> LocalBatchMessage {
    LocalBatchMessage(runtimeOp: object([("type", string("component")), ("contents", string(text))]), referenceSequenceNumber: ref, staged: staged)
}
private func sequenced(_ wire: JSONValue, csn: Int = 9, client: String = "c") throws -> JSONValue {
    var m = try wire.asObject()
    m["type"] = string("op"); m["clientId"] = string(client); m["clientSequenceNumber"] = number(csn)
    m["sequenceNumber"] = number(100 + csn); m["minimumSequenceNumber"] = number(0); m["timestamp"] = number(0)
    return .object(m)
}
private let plain = OpLifecycleOptions(compressionThreshold: Int.max)

@Test func singletonIsNotGrouped() throws {
    let wire = try OpLifecycle.encode([op()], options: plain)
    #expect(wire.count == 1 && wire[0].count == 1)
    #expect(try field(wire[0][0], "metadata") == nil)
    #expect(try wire[0][0].member("contents").asString() == #"{"type":"component","contents":"x"}"#)
}
@Test func batchMarkersAndGroupedCSNs() throws {
    let wire = try OpLifecycle.encode([op("a"), op("b")], options: plain, batchId: "old_[7]")
    let result = try #require(try RemoteMessageProcessor().process(sequenced(wire[0][0])))
    #expect(try result.member("length").asInt() == 2)
    #expect(try result.member("batchStart").member("batchStartCsn").asInt() == 9)
    #expect(try result.member("batchStart").member("batchId").asString() == "old_[7]")
    let messages = try result.member("messages").asArray()
    #expect(try messages[0].member("clientSequenceNumber").asInt() == 1)
    #expect(try messages[1].member("clientSequenceNumber").asInt() == 2)
    #expect(try messages[0].member("metadata").member("batch") == .bool(true))
    #expect(try messages[1].member("metadata").member("batch") == .bool(false))
}
@Test func chunkUTF16AndExtraEmptySlice() throws {
    let wire = object([("contents", .string(JSString(utf16: [0xd83d,0xde00,0x61]))), ("compression", string("lz4")), ("referenceSequenceNumber", number(0))])
    let chunks = try OpLifecycle.split(wire, chunkSize: 1, extraOp: true)
    #expect(chunks.count == 4)
    let first = try JSON.parse(chunks[0].member("contents").asString().description).member("contents")
    #expect(try first.member("contents").asString().utf16 == [0xd83d])
    let last = try JSON.parse(chunks[3].member("contents").asString().description).member("contents")
    #expect(try last.member("contents").asString() == "")
    #expect(try last.member("originalType").asString() == "component")
}
@Test func partialChunksAndCorruption() throws {
    let wire = try OpLifecycle.encode([op(String(repeating: "abcdefgh", count: 500))], options: .init(compressionThreshold: 1, chunkSize: 32))
    #expect(wire.count > 1)
    let processor = RemoteMessageProcessor()
    #expect(try processor.process(sequenced(wire[0][0])) == nil)
    #expect(processor.partialMessages.count == 1)
    #expect(throws: JSONDecodingError.self) { try processor.process(sequenced(wire[0][0])) }
    processor.clearPartialMessages(for: "c")
    #expect(processor.partialMessages.isEmpty)
}
@Test func pendingRegistrationReceivesMarkedAllocationFirst() throws {
    var pending: [LocalBatchMessage] = []; var sent = 0
    let outbox = Outbox(options: plain, submitBatch: { batch in sent += batch.count; return sent }, onFlush: { batch, csn, staged in
        pending = batch; #expect(csn == 1); #expect(!staged)
    })
    outbox.generateIdAllocation = { LocalBatchMessage(runtimeOp: object([("type", string("idAllocation"))]), referenceSequenceNumber: 0) }
    try outbox.submit(op()); try outbox.flush(batchId: "old_[7]")
    #expect(pending.count == 2)
    #expect(try pending[0].runtimeOp.member("type").asString() == "idAllocation")
    #expect(try pending[0].metadata?.member("batch") == .bool(true))
    #expect(try pending[1].metadata?.member("batch") == .bool(false))
}
@Test func stagingDoesNotAllocateOrSend() throws {
    var tracked = false
    let outbox = Outbox(options: plain, submitBatch: { _ in Issue.record("staged send"); return 0 }, onFlush: { _, csn, staged in tracked = true; #expect(csn == nil && staged) })
    outbox.generateIdAllocation = { Issue.record("staged allocation"); return nil }
    try outbox.submit(op(staged: true)); try outbox.flush()
    #expect(tracked)
}
@Test func rollbackIsLIFOAndRejectsGeneratedOps() throws {
    let manager = BatchManager(); manager.push(op("a")); manager.push(op("b")); manager.push(op("c"))
    var rolled: [JSONValue] = []
    try manager.rollback(to: 1) { rolled.append($0.runtimeOp) }
    #expect(rolled == [op("c").runtimeOp, op("b").runtimeOp])
    manager.push(op())
    #expect(throws: JSONDecodingError.self) { try manager.rollback(to: 1) { _ in manager.push(op()) } }
}
@Test func invalidBatchMarkers() throws {
    var options = plain; options.grouped = false
    let batch = try OpLifecycle.encode([op(),op()], options: options)[0]
    #expect(throws: JSONDecodingError.self) { try RemoteMessageProcessor().process(sequenced(batch[1])) }
    let processor = RemoteMessageProcessor()
    _ = try processor.process(sequenced(batch[0]))
    #expect(throws: JSONDecodingError.self) { try processor.process(sequenced(batch[0])) }
}
@Test func thresholdUsesUngroupedSize() throws {
    let size = JSON.stringify(op().runtimeOp).utf16.count * 2
    let below = try OpLifecycle.encode([op(),op()], options: .init(compressionThreshold: size + 1))
    let at = try OpLifecycle.encode([op(),op()], options: .init(compressionThreshold: size))
    #expect(try field(below[0][0], "compression") == nil)
    #expect(try field(at[0][0], "compression") == string("lz4"))
}
@Test func emptyReplayPreservesIdentity() throws {
    let batch = try OpLifecycle.encode([], options: plain, batchId: "c_[1]")
    let result = try #require(try RemoteMessageProcessor().process(sequenced(batch[0][0])))
    #expect(try result.member("length").asInt() == 0)
    #expect(try result.member("batchStart").member("batchId").asString() == "c_[1]")
}
@Test func reentrantBatchRebasesBeforeAllocating() throws {
    var processing = true; var sent: [JSONValue] = []
    let outbox = Outbox(options: plain, submitBatch: { batch in sent += batch; return sent.count })
    outbox.opReentrancy = { processing }
    outbox.reSubmit = { message in var rebased = message; rebased.referenceSequenceNumber = 9; try outbox.submit(rebased) }
    try outbox.submit(op("a", ref: 1)); try outbox.submit(op("b", ref: 2))
    #expect(throws: JSONDecodingError.self) { try outbox.flush() }
    processing = false; try outbox.flush()
    #expect(sent.count == 1)
    #expect(try sent[0].member("referenceSequenceNumber").asInt() == 9)
}
@Test func disconnectedEmptyReplayIsTracked() throws {
    var pending: [LocalBatchMessage] = []
    let outbox = Outbox(options: plain, submitBatch: { _ in Issue.record("disconnected send"); return 0 }, onFlush: { batch, csn, _ in pending = batch; #expect(csn == nil) })
    outbox.shouldSend = false; try outbox.flush(batchId: "c_[2]")
    #expect(pending.count == 1)
    #expect(pending.first?.localOpMetadata == object([("emptyBatch", .bool(true))]))
}
