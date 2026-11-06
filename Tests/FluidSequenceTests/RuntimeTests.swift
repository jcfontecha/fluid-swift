import Testing
import FluidJS
import FluidDriverDefinitions
import FluidDatastoreDefinitions
@testable import FluidSequence
import FluidTestRuntimeUtils

struct SequenceRuntimeTests {
  private func message(_ op: JSONValue, sender: JSString = "A", sequence: Int = 1, reference: Int = 0) throws -> SequencedMessage {
    try SequencedMessage(json: sequenceObject([
      ("clientId", .string(sender)),
      ("clientSequenceNumber", .number(1)),
      ("referenceSequenceNumber", .number(Double(reference))),
      ("sequenceNumber", .number(Double(sequence))),
      ("minimumSequenceNumber", .number(0)),
      ("type", .string("op")),
      ("contents", op),
    ]))
  }

  @Test func detachedEditsAreNotPending() throws {
    let text = SharedString(id: "channel")
    try text.insertText(0, "seed")
    #expect(text.client.pendingOperationCount == 0)
    let runtime = MockFluidDataStoreRuntime(clientId: "A")
    var submitted: [(JSONValue, SequenceLocalOpMetadata)] = []
    text.connect(runtime) { submitted.append(($0, $1)) }
    try text.insertText(4, "!")
    #expect(submitted.count == 1)
    let op = try #require(submitted.first)
    try text.process(message(op.0), local: true, localOpMetadata: op.1)
    #expect(text.getText() == "seed!")
    #expect(text.client.pendingOperationCount == 0)
    #expect(text.client.id == "A")
  }

  @Test func rollbackAndStashUseRuntimePath() throws {
    let text = SharedString(id: "channel")
    let runtime = MockFluidDataStoreRuntime(clientId: "A")
    var submitted: [(JSONValue, SequenceLocalOpMetadata)] = []
    text.connect(runtime) { submitted.append(($0, $1)) }
    try text.insertText(0, "hello")
    let op = try #require(submitted.first)
    try text.rollback(op.0, localOpMetadata: op.1)
    #expect(text.getText() == "")
    try text.applyStashedOp(op.0)
    #expect(text.getText() == "hello")
    #expect(submitted.count == 2)
    let stashed = try #require(submitted.last)
    try text.process(message(stashed.0), local: true, localOpMetadata: stashed.1)
    #expect(text.client.pendingOperationCount == 0)
  }

  @Test func reconnectRegeneratesAfterRemoteInsert() throws {
    let text = SharedString(id: "channel")
    try text.insertText(0, "ab")
    let runtime = MockFluidDataStoreRuntime(clientId: "A")
    var submitted: [(JSONValue, SequenceLocalOpMetadata)] = []
    text.connect(runtime) { submitted.append(($0, $1)) }
    try text.insertText(2, "x")
    let local = try #require(submitted.first)
    let remote = sequenceObject([
      ("pos1", .number(0)), ("seg", .string("z")), ("type", .number(0)),
    ])
    try text.process(message(remote, sender: "B"), local: false, localOpMetadata: nil)
    try text.reSubmitCore(local.0, localOpMetadata: local.1)
    let regenerated = try #require(submitted.last)
    #expect(try regenerated.0.member("pos1").asInt() == 3)
    try text.process(message(regenerated.0, sequence: 2, reference: 1), local: true, localOpMetadata: regenerated.1)
    #expect(text.getText() == "zabx")
    #expect(text.client.pendingOperationCount == 0)
  }
}

extension SequenceRuntimeTests {
  @Test func staleReferenceCatchupReloads() throws {
    let text = SharedString(id: "summary")
    let runtime = MockFluidDataStoreRuntime(clientId: "A")
    text.connect(runtime) { _, _ in }
    let first = sequenceObject([("pos1", .number(0)), ("seg", .string("a")), ("type", .number(0))])
    let second = sequenceObject([("pos1", .number(0)), ("seg", .string("b")), ("type", .number(0))])
    try text.process(message(first, sender: "B"), local: false, localOpMetadata: nil)
    try text.process(message(second, sender: "C", sequence: 2), local: false, localOpMetadata: nil)
    runtime.mockDeltaManager.lastSequenceNumber = 2
    let loaded = try SharedString.load(id: "loaded", summary: text.summarize())
    #expect(loaded.getText() == text.getText())
    #expect(loaded.client.currentSequence == 2)
  }

  @Test func submitPrecedesDeltaAndNoopAnnotationStillSubmits() throws {
    let text = SharedString(id: "channel")
    try text.insertText(0, "abc")
    let runtime = MockFluidDataStoreRuntime(clientId: "A")
    var order: [String] = []
    text.connect(runtime) { _, _ in order.append("submit") }
    text.sequenceDelta.on { _ in order.append("delta") }
    try text.annotateRange(0, 2, JSObject())
    #expect(order == ["submit", "delta"])
    #expect(text.client.pendingOperationCount == 1)
  }
}

extension SequenceRuntimeTests {
  @Test func rollbackEmitsInverseDeltaWithoutSubmitting() throws {
    let text = SharedString(id: "channel")
    let runtime = MockFluidDataStoreRuntime(clientId: "A")
    var submitted: [(JSONValue, SequenceLocalOpMetadata)] = []
    var operations: [Int] = []
    text.connect(runtime) { submitted.append(($0, $1)) }
    text.sequenceDelta.on { operations.append($0.deltaOperation) }
    try text.insertText(0, "abc")
    let insertion = try #require(submitted.last)
    try text.rollback(insertion.0, localOpMetadata: insertion.1)
    #expect(operations == [0, 1])
    #expect(submitted.count == 1)
  }

  @Test func defaultReentrancyGuardPreservesPendingOrder() throws {
    let text = SharedString(id: "channel")
    let runtime = MockFluidDataStoreRuntime(clientId: "A")
    text.connect(runtime) { _, _ in }
    var rejected = false
    text.sequenceDelta.on { _ in
      do { try text.insertText(0, "nested") }
      catch { rejected = true }
    }
    try text.insertText(0, "outer")
    #expect(rejected)
    #expect(text.getText() == "outer")
    #expect(text.client.pendingOperationCount == 1)
  }
}

extension SequenceRuntimeTests {
  @Test func pendingIntervalsRebaseBeforeSegmentNormalization() throws {
    let text = SharedString(id: "channel")
    try text.insertText(0, "abcdef")
    let runtime = MockFluidDataStoreRuntime(clientId: "A")
    text.connect(runtime) { _, _ in }
    let collection = text.getIntervalCollection("c")
    let interval = try collection.add(id: "i", start: 1, end: 3)
    try text.process(message(sequenceObject([("pos1", .number(1)), ("pos2", .number(4)), ("type", .number(1))]), sender: "B"),
      local: false, localOpMetadata: nil)
    #expect(interval.start.segment?.text == "bcd")
    _ = try text.client.regeneratePendingOps()
    #expect(interval.start.segment?.removals.isEmpty == true)
    #expect(text.client.localReferencePositionToPosition(interval.start) == 1)
  }
}

extension SequenceRuntimeTests {
  @Test func legacyCatchupLoadsMultipleMessagesAtOneBatchSequence() throws {
    let text = SharedString(id: "text")
    let runtime = MockFluidDataStoreRuntime(clientId: "A")
    text.connect(runtime) { _, _ in }
    let first = sequenceObject([("pos1", .number(0)), ("seg", .string("a")), ("type", .number(0))])
    let second = sequenceObject([("pos1", .number(1)), ("seg", .string("b")), ("type", .number(0))])
    try text.process(message(first, sender: "B"), local: false, localOpMetadata: nil)
    try text.process(message(second, sender: "B"), local: false, localOpMetadata: nil)
    runtime.mockDeltaManager.lastSequenceNumber = 1
    let loaded = try SharedString.load(id: "loaded", summary: text.summarizeSequence())
    #expect(loaded.getText() == "ab")
  }
}

extension SequenceRuntimeTests {
  @Test func summaryReadsGlobalMinimumAdvancedByAnotherDDS() throws {
    let text = SharedString(id: "text")
    let runtime = MockFluidDataStoreRuntime(clientId: "A")
    var sent: [(JSONValue, SequenceLocalOpMetadata)] = []
    text.connect(runtime) { sent.append(($0, $1)) }
    try text.insertText(0, "abc")
    let operation = try #require(sent.first)
    runtime.mockDeltaManager.lastSequenceNumber = 1
    try text.process(message(operation.0), local: true, localOpMetadata: operation.1)
    // The container processed other DDS messages; this channel received no further operations.
    runtime.mockDeltaManager.lastSequenceNumber = 5
    runtime.mockDeltaManager.minimumSequenceNumber = 3
    let summary = try text.summarizeSequence().json.member("tree").member("content").member("tree")
    let header = try JSON.parse(summary.member("header").member("content").asString().description)
    #expect(try header.member("chunkSequenceNumber").asInt() == 3)
    #expect(try header.member("segmentTexts") == .array([.string("abc")]))
    #expect(try summary.asObject()["catchupOps"] == nil)
  }
}

extension SequenceRuntimeTests {
  @Test func repeatedResubmitCyclesDoNotRequireConnectionCallback() throws {
    let text = SharedString(id: "text")
    let runtime = MockFluidDataStoreRuntime(clientId: "A")
    var sent: [(JSONValue, SequenceLocalOpMetadata)] = []
    text.connect(runtime) { sent.append(($0, $1)) }
    try text.insertText(0, "abc")
    let original = try #require(sent.first)
    try text.reSubmitCore(original.0, localOpMetadata: original.1)
    try text.reSubmitCore(original.0, localOpMetadata: original.1)
    #expect(sent.count == 3)
    #expect(sent.last?.0 == original.0)
  }
}
