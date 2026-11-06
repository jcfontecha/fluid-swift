import FluidJS
import FluidIdCompressor

/// Ports containerRuntime.ts pending/op-lifecycle integration. Datastore payloads remain opaque.
/// The owning container serial executor must serialize all calls into this synchronous layer.
public final class ContainerRuntime {
  public let pendingStateManager: PendingStateManager
  public let idCompressor: IdCompressor
  public private(set) var clientId: String
  public var connected = true
  public var referenceSequenceNumber = 0
  public private(set) var clientSequenceNumber = 0
  public var onSubmit: ([JSONValue], String, Int) throws -> Void = { _, _, _ in }
  public var reSubmit: (JSONValue) throws -> JSONValue = { $0 }
  public var applyStashedOp: (String) throws -> JSONValue? = { _ in nil }
  private let remoteMessageProcessor = RemoteMessageProcessor()
  private let duplicateBatchDetector: DuplicateBatchDetector
  public lazy var outbox: Outbox = {
    let value = Outbox(splitter: OpSplitter(), submitBatch: { [unowned self] messages in
      try self.onSubmit(messages, self.clientId, self.clientSequenceNumber)
      self.clientSequenceNumber += messages.count
      return self.clientSequenceNumber
    }, onFlush: { [unowned self] messages, csn, staged in
      try self.pendingStateManager.onFlushBatch(messages, clientSequenceNumber: csn, clientId: self.clientId, staged: staged)
    })
    value.generateIdAllocation = { [unowned self] in
      let range = try self.idCompressor.takeNextCreationRange()
      guard range.ids != nil else { return nil }
      return LocalBatchMessage(runtimeOp: object([("type", string("idAllocation")), ("contents", range.json)]), referenceSequenceNumber: self.referenceSequenceNumber)
    }
    return value
  }()
  public init(sessionId: String, clientId: String, stash: JSONValue? = nil) throws {
    self.clientId = clientId
    duplicateBatchDetector = try DuplicateBatchDetector()
    if let stash {
      pendingStateManager = try PendingStateManager(stashedLocalState: stash.member("pending"))
      idCompressor = try IdCompressor.deserialize(stash.member("pendingIdCompressorState").asString().description)
    } else {
      pendingStateManager = PendingStateManager()
      idCompressor = try IdCompressor(sessionId)
    }
  }
  public func submit(_ runtimeOp: JSONValue, localOpMetadata: JSONValue? = nil) throws {
    try require(!pendingStateManager.isApplyingStashedOps, "cannot submit while applying stash")
    try outbox.submit(.init(runtimeOp: runtimeOp, referenceSequenceNumber: referenceSequenceNumber, localOpMetadata: localOpMetadata))
  }
  public func flush(batchId: String? = nil, staged: Bool = false) throws {
    outbox.shouldSend = connected
    try outbox.flush(batchId: batchId, referenceSequenceNumber: referenceSequenceNumber, staged: staged)
  }
  public func reconnect(clientId: String) throws {
    self.clientId = clientId
    connected = true
    clientSequenceNumber = 0
    try idCompressor.resetUnfinalizedCreationRange()
    try pendingStateManager.replayPendingStates(clientId: clientId) { [unowned self] messages, id, staged in
      for message in messages {
        // Allocations describe a cursor interval, not a DDS edit. Regenerate at flush (0x174).
        if try message.runtimeOp.member("type") == string("idAllocation") { continue }
        try self.submit(self.reSubmit(message.runtimeOp), localOpMetadata: message.localOpMetadata)
      }
      try self.flush(batchId: id.description, staged: staged)
    }
  }
  public func getLocalState(snapshotSequenceNumber: Int? = nil) throws -> JSONValue {
    try flush()
    var state = try pendingStateManager.getLocalState(snapshotSequenceNumber: snapshotSequenceNumber).asObject()
    state["pendingIdCompressorState"] = string(try idCompressor.serialize(true))
    return .object(state)
  }
  public func applyStashedOpsAt(_ sequenceNumber: Int? = nil) throws {
    try pendingStateManager.applyStashedOpsAt(sequenceNumber) { [unowned self] content in
      let op = try JSON.parse(content)
      if try op.member("type") == string("idAllocation") { return nil }
      return try self.applyStashedOp(content)
    }
  }
  public func process(_ message: JSONValue) throws -> JSONValue? {
    referenceSequenceNumber = max(referenceSequenceNumber, try message.member("sequenceNumber").asInt())
    guard let inbound = try remoteMessageProcessor.process(message) else { return nil }
    if let start = try field(inbound, "batchStart"),
      try duplicateBatchDetector.processInboundBatch(start).member("duplicate") == .bool(true) {
      return object([("classification", string("duplicate"))])
    }
    let local = try message.member("clientId") == string(clientId)
    let processed = try pendingStateManager.processInboundMessages(inbound, local: local)
    for entry in processed {
      let runtimeOp = try entry.member("message")
      if try runtimeOp.member("type") == string("idAllocation") {
        try idCompressor.finalizeCreationRange(IdCreationRange(json: runtimeOp.member("contents")))
      }
    }
    return object([("classification", string(local ? "local" : "remote")), ("processed", .array(processed))])
  }
}
