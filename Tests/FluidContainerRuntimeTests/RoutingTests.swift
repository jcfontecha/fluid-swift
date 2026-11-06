import Testing
import FluidJS
@testable import FluidContainerRuntime

@Suite struct RoutingTests {
  @Test func blobAttachMetadataAndIdentity() throws {
    let manager = BlobManager()
    try manager.processBlobAttachMessage(JSON.parse(#"{"localId":"local","blobId":"storage"}"#))
    #expect(JSON.stringify(manager.summarize()) == #"{"summary":{"type":1,"tree":{"0":{"id":"storage","type":4},".redirectTable":{"type":2,"content":"[[\"local\",\"storage\"]]"}}},"stats":{"treeNodeCount":1,"blobNodeCount":1,"handleNodeCount":0,"totalBlobSize":21,"unreferencedBlobSize":0}}"#)
    #expect(JSON.stringify(manager.getGCData()) == #"{"gcNodes":{"/_blobs/local":[]}}"#)
  }
  @Test func metadataIsNotContents() throws {
    let manager = BlobManager()
    #expect(throws: (any Error).self) { try manager.processBlobAttachMessage(JSON.parse(#"{"blobId":"storage"}"#)) }
  }
}

@Suite struct BlobManagerTests {
  @Test func handleSharingAndGraphAreIndependent() throws {
    var shares = 0
    var attaches = 0
    let handle = BlobHandle(path: "/_blobs/a", payloadPending: true, share: { shares += 1 }, attach: { attaches += 1 })
    try handle.sharePayload()
    try handle.sharePayload()
    #expect(shares == 1)
    #expect(!handle.isAttached)
    try handle.attachGraph()
    try handle.attachGraph()
    #expect(attaches == 1)
    #expect(shares == 1)
    #expect(handle.isAttached)
    #expect(handle.payloadState == "pending")
    try handle.notifyShared()
    #expect(handle.payloadState == "shared")
    let shared = BlobHandle(path: "/_blobs/b", payloadPending: false, share: { shares += 1 })
    try shared.sharePayload()
    #expect(shares == 1)
  }
  @Test func abortFromDirtyListenerDoesNotUpload() throws {
    let manager = BlobManager()
    var uploads = 0
    manager.upload = { _, _ in uploads += 1 }
    manager.outstandingBlobWorkChanged = {
      if manager.hasOutstandingBlobWork { try manager.abort("a") }
    }
    try manager.createBlob([0], localId: "a", payloadPending: true) { handle in try handle.sharePayload() }
    #expect(uploads == 0)
    #expect(!manager.hasOutstandingBlobWork)
    #expect(!manager.hasBlob("a"))
  }
  @Test func authoritativeAckDefeatsLateUpload() throws {
    let manager = BlobManager()
    var finish: ((Result<BlobManager.UploadResponse, any Error>) throws -> Void)?
    manager.upload = { _, completion in finish = completion }
    var ops: [JSONValue] = []
    manager.sendBlobAttachMessage = { ops.append($0) }
    try manager.createBlob([0, 255], localId: "a", payloadPending: true) { handle in try handle.attachGraph() }
    #expect(manager.hasOutstandingBlobWork)
    try manager.processBlobAttachMessage(JSON.parse(#"{"localId":"a","blobId":"winner"}"#))
    let complete = try #require(finish)
    try complete(.success(.init(id: "loser")))
    #expect(manager.lookupTemporaryBlobStorageId("a") == "winner")
    #expect(!manager.hasOutstandingBlobWork)
    #expect(ops.isEmpty)
    #expect(try manager.getPendingBlobs() == nil)
  }
  @Test func pendingReadWaitsForMatchingAck() throws {
    let manager = BlobManager()
    var reads = 0
    manager.read = { id, completion in
      #expect(id == "storage")
      reads += 1
      try completion(.success([255]))
    }
    var data: [UInt8]?
    try manager.getBlob("a", payloadPending: true) { data = try $0.get() }
    try manager.processBlobAttachMessage(JSON.parse(#"{"localId":"b","blobId":"other"}"#))
    #expect(data == nil)
    try manager.processBlobAttachMessage(JSON.parse(#"{"localId":"a","blobId":"storage"}"#))
    #expect(data == [255])
    #expect(reads == 1)
  }
  @Test func aggregateTransitionsAndRedirectOrdering() throws {
    let manager = BlobManager()
    var transitions: [Bool] = []
    manager.upload = { _, completion in try completion(.success(.init(id: "dedup"))) }
    manager.outstandingBlobWorkChanged = {
      transitions.append(manager.hasOutstandingBlobWork)
      if !manager.hasOutstandingBlobWork { #expect(manager.lookupTemporaryBlobStorageId("b") == "dedup") }
    }
    for id: JSString in ["a", "b"] {
      try manager.createBlob([0], localId: id, payloadPending: true) { handle in try handle.attachGraph() }
    }
    #expect(transitions == [true])
    try manager.processBlobAttachMessage(JSON.parse(#"{"localId":"a","blobId":"dedup"}"#))
    #expect(transitions == [true])
    try manager.processBlobAttachMessage(JSON.parse(#"{"localId":"b","blobId":"dedup"}"#))
    #expect(transitions == [true, false])
  }
  @Test func ttlBoundaryAndPendingCapture() throws {
    let manager = BlobManager()
    var now = 1000.0
    manager.now = { now }
    var uploads = 0
    manager.upload = { _, completion in
      uploads += 1
      try completion(.success(.init(id: "storage", minTTLInSeconds: 10)))
    }
    var wire: [JSONValue] = []
    manager.sendBlobAttachMessage = { wire.append($0) }
    try manager.createBlob([0, 255], localId: "a", payloadPending: true) { handle in try handle.attachGraph() }
    let metadata = try #require(wire.first)
    let captured = try #require(try manager.getPendingBlobs())
    #expect(JSON.stringify(captured) == #"{"a":{"state":"uploaded","blob":"AP8=","storageId":"storage","uploadTime":1000,"minTTLInSeconds":10}}"#)
    now = 6000
    try manager.reSubmit(metadata)
    #expect(uploads == 1)
    now = 6001
    try manager.reSubmit(metadata)
    #expect(uploads == 2)
  }
  @Test func detachedPatchDedupAndSweep() throws {
    let manager = BlobManager()
    manager.attachState = .detached
    manager.upload = { _, completion in try completion(.success(.init(id: "pseudo"))) }
    for id: JSString in ["a", "b"] {
      try manager.createBlob([1], localId: id, payloadPending: true) { handle in
        #expect(!handle.payloadPending)
        #expect(handle.path == JSString("/_blobs/\(id)"))
      }
    }
    #expect(manager.lookupTemporaryBlobStorageId("a") == nil)
    try manager.patchRedirectTable([("pseudo", "real")])
    manager.attachState = .attached
    #expect(manager.lookupTemporaryBlobStorageId("a") == "real")
    _ = try manager.deleteSweepReadyNodes(["/_blobs/a"])
    #expect(manager.lookupTemporaryBlobStorageId("real") == "real")
    _ = try manager.deleteSweepReadyNodes(["/_blobs/b"])
    #expect(manager.lookupTemporaryBlobStorageId("real") == nil)
  }
}

@Suite struct ContainerRoutingTests {
  @Test func unknownOpsCloseButChunkedOpsAssertBeforeDispatch() throws {
    let runtime = try ContainerRuntime(sessionId: "10000000-0000-4000-8000-000000000001", clientId: "self")
    #expect(throws: JSONDecodingError.self) { try runtime.validateAndProcessRuntimeMessages(JSON.parse(#"{"type":"future"}"#), messagesContent: [], local: false) }
    #expect(runtime.closed)
  }
  @Test func signalsPreserveAbsenceEmptyAddressAndTrailingExtensionSegment() throws {
    let runtime = try ContainerRuntime(sessionId: "10000000-0000-4000-8000-000000000001", clientId: "self")
    var output: [JSONValue] = []
    runtime.onRuntimeDispatch = { _, value in output.append(value) }
    runtime.channelCollection.contexts = []
    runtime.extensions = ["presence"]
    try runtime.processSignal(JSON.parse(#"{"clientId":null,"content":{"contents":{"type":"cursor","content":1}}}"#), local: false)
    #expect(output.count == 1)
    try runtime.processSignal(JSON.parse(#"{"clientId":"peer","content":{"address":"","contents":{"type":"cursor","content":1}}}"#), local: false)
    #expect(output.count == 1)
    try runtime.processSignal(JSON.parse(#"{"clientId":"peer","content":{"address":"/ext/presence/","contents":{"type":"cursor","content":1}}}"#), local: false)
    #expect(try output.last?.asArray().first == .array([.string("")]))
  }
  @Test func targetedSignalsDoNotAdvanceBroadcastCounter() throws {
    let runtime = try ContainerRuntime(sessionId: "10000000-0000-4000-8000-000000000001", clientId: "self")
    var envelopes: [JSONValue] = []
    runtime.onSubmitSignal = { envelope, _ in envelopes.append(envelope) }
    try runtime.submitSignal(type: "cursor", content: .null)
    try runtime.submitSignal(type: "cursor", content: .null, targetClientId: "peer")
    try runtime.submitSignal(type: "cursor", content: .null)
    #expect(try envelopes[0].member("clientBroadcastSignalSequenceNumber") == .number(1))
    #expect(try envelopes[1].asObject()["clientBroadcastSignalSequenceNumber"] == nil)
    #expect(try envelopes[2].member("clientBroadcastSignalSequenceNumber") == .number(2))
  }
  @Test func waitsForContainerAttachment() throws {
    let manager = BlobManager()
    manager.attachState = .attaching
    var uploaded = false
    manager.upload = { _, completion in
      uploaded = true
      try completion(.success(.init(id: "storage")))
    }
    try manager.createBlob([0], localId: "a", payloadPending: false) { _ in }
    #expect(!uploaded)
    try manager.setAttachState(.attached)
    #expect(uploaded)
  }
  @Test func loneSurrogatesRemainInHandlePaths() throws {
    let id = JSString(utf16: [0xd800])
    #expect(getGCNodePathFromLocalId(id).utf16.last == 0xd800)
    #expect(isBlobPath(getGCNodePathFromLocalId(id)))
  }
}

@Suite struct RuntimeBlobIntegrationTests {
  @Test func blobAttachTravelsThroughOutboxPendingAndInbound() throws {
    let runtime = try ContainerRuntime(sessionId: "10000000-0000-4000-8000-000000000001", clientId: "self")
    runtime.blobManager.upload = { _, complete in try complete(.success(.init(id: "storage"))) }
    var handle: BlobHandle?
    try runtime.blobManager.createBlob([1, 255], localId: "local", payloadPending: true) {
      handle = $0
      try $0.attachGraph()
    }
    var wire: [JSONValue] = []
    runtime.onSubmit = { batch, _, _ in wire.append(contentsOf: batch) }
    let stash = try runtime.getLocalState()
    #expect(try stash.member("pendingAttachmentBlobs").member("local").member("state") == .string("uploaded"))
    let first = try #require(wire.first)
    #expect(try first.member("contents") == .string(#"{"type":"blobAttach"}"#))
    let message = try object([
      ("type", string("op")), ("contents", JSON.parse(first.member("contents").asString().description)),
      ("metadata", first.member("metadata")), ("clientId", string("self")),
      ("clientSequenceNumber", number(1)), ("sequenceNumber", number(1)),
      ("minimumSequenceNumber", number(0)), ("referenceSequenceNumber", number(0)), ("timestamp", number(0)),
    ])
    _ = try runtime.process(message)
    #expect(handle?.payloadState == "shared")
    #expect(!runtime.blobManager.hasOutstandingBlobWork)
    #expect(runtime.pendingStateManager.pendingMessagesCount == 0)
    #expect(try runtime.blobManager.getPendingBlobs() == nil)
    let loaded = try ContainerRuntime(sessionId: runtime.idCompressor.localSessionId, clientId: "new", stash: stash)
    #expect(loaded.blobManager.hasOutstandingBlobWork)
    #expect(loaded.blobManager.hasBlob("local"))
    var datastoreStashCalls = 0
    loaded.applyStashedOp = { _ in
      datastoreStashCalls += 1
      return nil
    }
    try loaded.applyStashedOpsAt()
    #expect(datastoreStashCalls == 0)
  }
}

@Suite struct BlobFailureTests {
  @Test func terminalFailureStopsWorkAndDropsPendingCapture() throws {
    let manager = BlobManager()
    manager.upload = { _, completion in try completion(.failure(JSONDecodingError("storage failed"))) }
    var handle: BlobHandle?
    try manager.createBlob([1], localId: "a", payloadPending: true) { handle = $0 }
    try handle?.attachGraph()
    #expect(handle?.payloadState == "pending")
    #expect(handle?.payloadShareError != nil)
    #expect(!manager.hasOutstandingBlobWork)
    #expect(!manager.hasBlob("a"))
    #expect(try manager.getPendingBlobs() == nil)
  }
}

@Suite struct RuntimeCompatibilityTests {
  @Test func oldestClientAndPendingPayloadGate() throws {
    let session = "10000000-0000-4000-8000-000000000001"
    let options = try JSON.parse(#"{"createBlobPayloadPending":true}"#)
    #expect(throws: JSONDecodingError.self) { try ContainerRuntime(sessionId: session, clientId: "a", oldestSupportedClient: "2.0.0", runtimeOptions: options) }
    #expect(throws: JSONDecodingError.self) { try ContainerRuntime(sessionId: session, clientId: "a", oldestSupportedClient: "2.40.0", minVersionForCollab: "2.40.0") }
    let runtime = try ContainerRuntime(sessionId: session, clientId: "a", oldestSupportedClient: "2.40.0", runtimeOptions: options)
    #expect(runtime.createBlobPayloadPending)
    var uploaded = false
    runtime.blobManager.upload = { _, _ in uploaded = true }
    try runtime.uploadBlob([0]) { handle in #expect(handle.payloadPending) }
    #expect(!uploaded)
  }
  @Test func semverParserQuirksMatchNpm() throws {
    try validateMinimumVersionForCollab("v2.0.0")
    try validateMinimumVersionForCollab(" 2.0.0 ")
    #expect(throws: JSONDecodingError.self) { try validateMinimumVersionForCollab("2.0.0+build") }
    #expect(throws: JSONDecodingError.self) { try validateMinimumVersionForCollab("3.10.1") }
    #expect(throws: JSONDecodingError.self) { try validateMinimumVersionForCollab("02.0.0") }
  }
}
