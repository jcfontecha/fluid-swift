import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidIdCompressor

/// Ports containerRuntime.ts pending/op-lifecycle integration. Datastore payloads remain opaque.
/// The owning container serial executor must serialize all calls into this synchronous layer.
public final class ContainerRuntime: IFluidParentContext {
  public let oldestSupportedClient: String
  public let createBlobPayloadPending: Bool
  public let channelCollection = ChannelCollection()
  public let garbageCollector = GarbageCollector()
  let summaryState = ContainerSummaryState()
  public var blobManager = BlobManager()
  public let signalTelemetryManager = SignalTelemetryManager()
  public internal(set) var metadata: JSONValue?
  public var electedSummarizerData: JSONValue?
  public internal(set) var gcSnapshot: SummaryTree?
  public internal(set) var aliases: JSONValue = .array([])
  public var closed = false
  public var extensions: Set<JSString> = []
  public var onEvent: (JSString, [JSONValue]) throws -> Void = { _, _ in }
  public var onRuntimeDispatch: (JSString, JSONValue) throws -> Void = { _, _ in }
  public var onSubmitSignal: (JSONValue, JSString?) throws -> Void = { _, _ in }
  public var onIdAllocation: (([JSONValue], Bool) throws -> Void)?
  public let pendingStateManager: PendingStateManager
  public internal(set) var idCompressor: IdCompressor
  public private(set) var clientId: String
  /// `ContainerRuntime.deltaManager`: the container context's delta manager.
  public let deltaManager: any IDeltaManager
  private let quorum: any IQuorumClients
  public var connected = true
  public var referenceSequenceNumber = 0
  public private(set) var clientSequenceNumber = 0
  public var onSubmitBatch: (([JSONValue]) throws -> Int)?
  public var onSubmit: ([JSONValue], String, Int) throws -> Void = { _, _, _ in }
  public var reSubmit: (JSONValue) throws -> JSONValue = { $0 }
  public var applyStashedOp: (String) throws -> JSONValue? = { _ in nil }
  private let remoteMessageProcessor = RemoteMessageProcessor()
  var duplicateBatchDetector: DuplicateBatchDetector
  public lazy var outbox: Outbox = {
    let value = Outbox(splitter: OpSplitter(), submitBatch: { [unowned self] messages in
      if let submit = self.onSubmitBatch {
        self.clientSequenceNumber = try submit(messages)
        return self.clientSequenceNumber
      }
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
  public init(sessionId: String, clientId: String, deltaManager: any IDeltaManager, quorum: any IQuorumClients, stash: JSONValue? = nil, oldestSupportedClient: String? = nil, minVersionForCollab: String? = nil, runtimeOptions: JSONValue? = nil) throws {
    try require(oldestSupportedClient == nil || minVersionForCollab == nil, "oldestSupportedClient and minVersionForCollab cannot both be supplied")
    let version = oldestSupportedClient ?? minVersionForCollab ?? "2.0.0"
    try validateMinimumVersionForCollab(version)
    if let runtimeOptions { try validateRuntimeOptions(version, options: runtimeOptions) }
    metadata = try initialSummaryMetadata(minVersionForCollab: version, runtimeOptions: runtimeOptions)
    self.oldestSupportedClient = version
    createBlobPayloadPending = try runtimeOptions.flatMap { try field($0, "createBlobPayloadPending") } == .bool(true)
    self.clientId = clientId
    // deltaManagerProxies.ts: DeltaManagerPendingOpsProxy forwards minimumSequenceNumber unchanged.
    self.deltaManager = deltaManager
    self.quorum = quorum
    duplicateBatchDetector = try DuplicateBatchDetector()
    if let stash {
      pendingStateManager = try PendingStateManager(stashedLocalState: stash.member("pending"))
      idCompressor = try IdCompressor.deserialize(stash.member("pendingIdCompressorState").asString().description, requestedWriteVersion: idCompressorWriteVersion(version))
      try blobManager.restorePendingBlobs(field(stash, "pendingAttachmentBlobs"))
    } else {
      pendingStateManager = PendingStateManager()
      idCompressor = try IdCompressor(sessionId, writeVersion: idCompressorWriteVersion(version))
    }
    channelCollection.onDatastoreChannelDirty = { [weak self] store, channel in
      guard let self else { return }
      self.summaryState.node(store).recordChange()
      self.summaryState.node(JSString(store.description + "/" + channel.description)).recordChange()
    }
    channelCollection.onSubmitDatastoreSignal = { [weak self] id, type, content, target in
      guard let self else { throw JSONDecodingError("container host released") }
      try self.submitSignal(type: type, content: content, address: id, targetClientId: target)
    }
    blobManager.sendBlobAttachMessage = { [weak self] metadata in
      guard let self else { return }
      try self.submit(object([("type", string("blobAttach"))]), metadata: metadata)
    }
  }
  /// `ContainerRuntime.getQuorum`.
  public func getQuorum() -> any IQuorumClients { quorum }
  public func uploadBlob(_ bytes: [UInt8], completion: @escaping (BlobHandle) throws -> Void) throws {
    try require(!closed, "runtime closed")
    try blobManager.createBlob(bytes, payloadPending: createBlobPayloadPending, completion: completion)
  }
  public func submit(_ runtimeOp: JSONValue, localOpMetadata: JSONValue? = nil, metadata: JSONValue? = nil) throws {
    try require(!closed, "runtime closed")
    try require(!pendingStateManager.isApplyingStashedOps, "cannot submit while applying stash")
    try recordSummaryChange(runtimeOp)
    try outbox.submit(.init(runtimeOp: runtimeOp, referenceSequenceNumber: referenceSequenceNumber, metadata: metadata, localOpMetadata: localOpMetadata), blobAttach: runtimeOp.member("type") == string("blobAttach"))
  }
  public func flush(batchId: String? = nil, staged: Bool = false) throws {
    try channelCollection.drainDatastoreMessages { op, metadata in
      try self.submit(op, localOpMetadata: metadata)
    }
    outbox.shouldSend = connected
    try outbox.flush(batchId: batchId, referenceSequenceNumber: referenceSequenceNumber, staged: staged)
  }
  public func reconnect(clientId: String) throws {
    self.clientId = clientId
    connected = true
    clientSequenceNumber = 0
    try channelCollection.setDatastoreConnectionState(true, clientId: JSString(clientId))
    try idCompressor.resetUnfinalizedCreationRange()
    try pendingStateManager.replayPendingStates(clientId: clientId) { [unowned self] messages, id, staged in
      for message in messages {
        // Allocations describe a cursor interval, not a DDS edit. Regenerate at flush (0x174).
        if try message.runtimeOp.member("type") == string("idAllocation") { continue }
        if try message.runtimeOp.member("type") == string("blobAttach") {
          guard let metadata = message.metadata else { throw JSONDecodingError("0xc01") }
          try self.blobManager.reSubmit(metadata)
          continue
        }
        if try self.channelCollection.reSubmitDatastore(message.runtimeOp, metadata: message.localOpMetadata) {
          continue
        }
        try self.submit(self.reSubmit(message.runtimeOp), localOpMetadata: message.localOpMetadata)
      }
      try self.flush(batchId: id.description, staged: staged)
    }
  }
  public func getLocalState(snapshotSequenceNumber: Int? = nil) throws -> JSONValue {
    try flush()
    var state = try pendingStateManager.getLocalState(snapshotSequenceNumber: snapshotSequenceNumber).asObject()
    state["pendingIdCompressorState"] = string(try idCompressor.serialize(true))
    state["pendingAttachmentBlobs"] = try blobManager.getPendingBlobs()
    return .object(state)
  }
  public func applyStashedOpsAt(_ sequenceNumber: Int? = nil) throws {
    try pendingStateManager.applyStashedOpsAt(sequenceNumber) { [unowned self] content in
      let op = try JSON.parse(content)
      switch ContainerMessageType(rawValue: try op.member("type").asString().description) {
      case .fluidDataStoreOp, .attach, .alias:
        if try self.channelCollection.ownsDatastoreOp(op) { return try self.channelCollection.applyDatastoreStash(op) }
        return try self.applyStashedOp(content)
      case .idAllocation, .blobAttach, .documentSchemaChange: return nil
      case .rejoin: throw JSONDecodingError("rejoin not expected here")
      case .gc: throw JSONDecodingError("GC op not expected to be stashed in summarizer")
      case .chunkedOp, nil:
        self.closed = true
        try self.onRuntimeDispatch("close", .null)
        throw JSONDecodingError("Unknown stashed message type")
      }
    }
  }
  public func process(_ message: JSONValue) throws -> JSONValue? {
    try recordSummaryMessage(message)
    referenceSequenceNumber = max(referenceSequenceNumber, try message.member("sequenceNumber").asInt())
    guard let inbound = try remoteMessageProcessor.process(message) else { return nil }
    if let start = try field(inbound, "batchStart"),
      try duplicateBatchDetector.processInboundBatch(start).member("duplicate") == .bool(true) {
      return object([("classification", string("duplicate"))])
    }
    let local = try message.member("clientId") == string(clientId)
    let processed = try pendingStateManager.processInboundMessages(inbound, local: local)
    if !processed.isEmpty {
      let kind = try inbound.member("type").asString()
      try processInboundMessages(processed, batchStart: kind != "nextBatchMessage", batchEnd: kind == "fullBatch" || field(inbound, "batchEnd") == .bool(true), local: local, groupedBatch: field(inbound, "groupedBatch") == .bool(true))
    }
    return object([("classification", string(local ? "local" : "remote")), ("processed", .array(processed))])
  }
}

extension ContainerRuntime {
  /// Ports processInboundMessages batching and event ordering after pending-state correlation.
  public func processInboundMessages(_ processed: [JSONValue], batchStart: Bool, batchEnd: Bool, local: Bool, groupedBatch: Bool) throws {
    guard let first = processed.first, let last = processed.last else { return }
    if batchStart { try onEvent("batchBegin", [first.member("message")]) }
    var caught: (any Error)?
    do {
      func content(_ entry: JSONValue) throws -> JSONValue {
        let message = try entry.member("message")
        return try object([
          ("contents", field(message, "contents")),
          ("localOpMetadata", field(entry, "localOpMetadata")),
          ("clientSequenceNumber", message.member("clientSequenceNumber")),
        ])
      }
      if groupedBatch {
        var previous: JSONValue?
        var bunch: [JSONValue] = []
        for entry in processed {
          let message = try entry.member("message")
          if let previous, try previous.member("type") != message.member("type") {
            try validateAndProcessRuntimeMessages(previous, messagesContent: bunch, local: local)
            bunch.removeAll(keepingCapacity: true)
          }
          previous = message
          bunch.append(try content(entry))
        }
        if let previous { try validateAndProcessRuntimeMessages(previous, messagesContent: bunch, local: local) }
        for entry in processed { try onEvent("op", [entry.member("message"), .bool(true)]) }
      } else {
        for entry in processed {
          let message = try entry.member("message")
          try validateAndProcessRuntimeMessages(message, messagesContent: [content(entry)], local: local)
          try onEvent("op", [message, .bool(true)])
        }
      }
    } catch {
      caught = error
    }
    if batchEnd || caught != nil { try onEvent("batchEnd", [.null, last.member("message")]) }
    if let caught { throw caught }
  }
  /// Ports validateAndProcessRuntimeMessages: called only after transport unpacking and pending correlation.
  public func validateAndProcessRuntimeMessages(
    _ envelope: JSONValue, messagesContent: [JSONValue], local: Bool, savedOp: Bool = false
  ) throws {
    let type = try envelope.member("type").asString().description
    let contents = try messagesContent.map { try field($0, "contents") ?? .null }
    switch ContainerMessageType(rawValue: type) {
    case .fluidDataStoreOp, .attach, .alias:
      for content in contents { try recordSummaryChange(object([("type", string(type)), ("contents", content)])) }
      try channelCollection.processMessages(envelope: envelope, messagesContent: messagesContent, local: local)
    case .blobAttach:
      try blobManager.processBlobAttachMessage(envelope.member("metadata"))
    case .idAllocation:
      if let onIdAllocation { try onIdAllocation(contents, savedOp) }
      else if !savedOp {
        for range in contents { try idCompressor.finalizeCreationRange(IdCreationRange(json: range)) }
      }
    case .gc:
      try onRuntimeDispatch("GC", .array([.array(contents), envelope.member("timestamp"), .bool(local)]))
    case .documentSchemaChange:
      try onRuntimeDispatch("schema", .array([.array(contents), .bool(local), envelope.member("sequenceNumber")]))
    case .rejoin: break
    case .chunkedOp: throw JSONDecodingError("0x93d")
    case nil:
      closed = true
      try onRuntimeDispatch("close", .null)
      throw JSONDecodingError("Unknown message type: \(type)")
    }
  }
  public func submitSignal(type: JSString, content: JSONValue, address: JSString? = nil, targetClientId: JSString? = nil) throws {
    try require(!closed, "runtime closed")
    if let address { try require(!address.description.hasPrefix("/"), "General path based addressing is not implemented") }
    let envelope = object([("address", address.map(JSONValue.string)), ("contents", object([("type", .string(type)), ("content", content)]))])
    try sendSignal(envelope, targetClientId: targetClientId)
  }
  public func submitExtensionSignal(id: JSString, addressChain: [JSString], message: JSONValue) throws {
    try require(!closed, "runtime closed")
    var units = JSString("/ext/").utf16
    units.append(contentsOf: id.utf16)
    units.append(47)
    for (index, part) in addressChain.enumerated() {
      if index > 0 { units.append(47) }
      units.append(contentsOf: part.utf16)
    }
    let address = JSString(utf16: units)
    try sendSignal(object([("address", .string(address)), ("contents", message)]), targetClientId: field(message, "targetClientId")?.asString())
  }
  private func sendSignal(_ envelope: JSONValue, targetClientId: JSString?) throws {
    let tracked = try targetClientId == nil ? signalTelemetryManager.applyTrackingToBroadcastSignalEnvelope(envelope) : envelope
    try onSubmitSignal(tracked, targetClientId)
  }
  public func processSignal(_ message: JSONValue, local: Bool) throws {
    let envelope = try message.member("content")
    let contents = try envelope.member("contents")
    let transformed = try object([("clientId", message.member("clientId")), ("content", field(contents, "content")), ("type", contents.member("type")), ("targetClientId", field(message, "targetClientId"))])
    guard let addressValue = try field(envelope, "address") else {
      try onRuntimeDispatch("signal", .array([transformed, .bool(local)]))
      return
    }
    let address = try addressValue.asString()
    if !address.description.hasPrefix("/") {
      try channelCollection.processSignal(address: address, signal: transformed, local: local)
      return
    }
    let parts = splitRuntimePath(address)
    if parts.count > 2, parts[1] == "ext", extensions.contains(parts[2]) {
      try onRuntimeDispatch("extension", .array([.array(parts.dropFirst(3).map(JSONValue.string)), transformed, .bool(local)]))
      return
    }
    try require(!local, "0xba0")
  }
}
