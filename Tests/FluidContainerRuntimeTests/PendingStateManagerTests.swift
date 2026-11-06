import Testing
import FluidJS
@testable import FluidContainerRuntime

struct PendingStateManagerTests {
  @Test func serializedStateAndExactAck() throws {
    let manager = PendingStateManager()
    let op = try JSON.parse(#"{"type":"component","contents":{"address":"dds","contents":"hello"}}"#)
    try manager.onFlushBatch([LocalBatchMessage(runtimeOp: op, referenceSequenceNumber: 0)], clientSequenceNumber: 1, clientId: "a")
    #expect(JSON.stringify(try manager.getLocalState()) == #"{"pending":{"pendingStates":[{"type":"message","referenceSequenceNumber":0,"content":"{\"type\":\"component\",\"contents\":{\"address\":\"dds\",\"contents\":\"hello\"}}","batchInfo":{"clientId":"a","batchStartCsn":1,"length":1,"staged":false}}]}}"#)
    #expect(try manager.hasPendingUserChanges())
    let incoming = try JSON.parse(#"{"type":"fullBatch","length":1,"messages":[{"type":"component","contents":{"contents":"hello","address":"dds"},"sequenceNumber":1}]}"#)
    #expect(throws: JSONDecodingError.self) { try manager.processInboundMessages(incoming, local: true) }
    #expect(manager.pendingMessagesCount == 0)
  }
  @Test func replayAndStash() throws {
    let manager = PendingStateManager()
    let op = try JSON.parse(#"{"type":"component","contents":{"address":"dds","contents":1}}"#)
    try manager.onFlushBatch([.init(runtimeOp: op, referenceSequenceNumber: 0)], clientSequenceNumber: 1, clientId: "a")
    let loaded = try PendingStateManager(stashedLocalState: manager.getLocalState().member("pending"))
    #expect(loaded.isApplyingStashedOps)
    try loaded.applyStashedOpsAt { _ in number(42) }
    #expect(!loaded.isApplyingStashedOps)
    try loaded.replayPendingStates(clientId: "b") { messages, id, staged in
      #expect(id == "a_[1]")
      #expect(messages.count == 1)
      #expect(messages.first?.localOpMetadata == number(42))
      try loaded.onFlushBatch(messages, clientSequenceNumber: 1, clientId: "b", staged: staged)
    }
    #expect(loaded.pendingMessagesCount == 1)
    #expect(throws: JSONDecodingError.self) {
      try loaded.replayPendingStates(clientId: "b") { _, _, _ in }
    }
  }
  @Test func allocationRegeneratesOnReconnect() throws {
    let runtime = try ContainerRuntime(sessionId: "00000000-0000-4000-8000-000000000001", clientId: "a")
    var wire: [[JSONValue]] = []
    runtime.onSubmit = { batch, _, _ in wire.append(batch) }
    _ = try runtime.idCompressor.generateCompressedId()
    try runtime.submit(try JSON.parse(#"{"type":"component","contents":{"address":"dds","contents":1}}"#))
    try runtime.flush()
    _ = try runtime.idCompressor.generateCompressedId()
    try runtime.reconnect(clientId: "b")
    #expect(wire.count == 2)
    let last = try #require(wire.last?.first)
    let grouped = try JSON.parse(last.member("contents").asString().description)
    let range = try #require(grouped.member("contents").asArray().first)
    #expect(try range.member("contents").member("contents").member("ids").member("count") == number(2))
  }
  @Test func stashedAckAndSnapshotFiltering() throws {
    let manager = PendingStateManager()
    let op = try JSON.parse(#"{"type":"rejoin"}"#)
    try manager.onFlushBatch([.init(runtimeOp: op, referenceSequenceNumber: 2)], clientSequenceNumber: 7, clientId: "old")
    #expect(throws: JSONDecodingError.self) { try manager.getLocalState(snapshotSequenceNumber: 3) }
    let loaded = try PendingStateManager(stashedLocalState: manager.getLocalState().member("pending"))
    #expect(loaded.pendingMessagesCount == 1)
    #expect(try loaded.hasPendingUserChanges())
    var applications = 0
    var closed = 0
    loaded.onAfterStashedOpsApplied = { closed += 1 }
    try loaded.applyStashedOpsAt(1) { _ in
      applications += 1
      return nil
    }
    #expect(applications == 0)
    try loaded.applyStashedOpsAt(2) { _ in
      applications += 1
      return string("rehydrated")
    }
    try loaded.applyStashedOpsAt(2) { _ in
      applications += 1
      return nil
    }
    #expect(applications == 1)
    #expect(closed == 1)
    let inbound = try JSON.parse(#"{"type":"fullBatch","length":1,"batchStart":{"clientId":"old","batchStartCsn":7,"keyMessage":{"sequenceNumber":3}},"messages":[{"type":"rejoin","sequenceNumber":3}]}"#)
    #expect(throws: JSONDecodingError.self) { try loaded.processInboundMessages(inbound, local: false) }
    let result = try loaded.processInboundMessages(inbound, local: true)
    #expect(try result.first?.member("localOpMetadata") == string("rehydrated"))
    #expect(loaded.pendingMessagesCount == 0)
    #expect(try !loaded.hasPendingUserChanges())
    #expect(try loaded.getLocalState(snapshotSequenceNumber: 3).member("pending").member("pendingStates").asArray().isEmpty)
    #expect(try loaded.getLocalState(snapshotSequenceNumber: 2).member("pending").member("pendingStates").asArray().count == 1)
  }
}
