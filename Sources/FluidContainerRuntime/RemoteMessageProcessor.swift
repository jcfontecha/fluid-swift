import FluidJS

/// Ports opLifecycle/remoteMessageProcessor.ts: reverse virtualization and track logical batch boundaries.
public final class RemoteMessageProcessor {
  private let opSplitter: OpSplitter
  private let opDecompressor: OpDecompressor
  private let opGroupingManager: OpGroupingManager
  private var batchInProgress = false
  public init(
    opSplitter: OpSplitter = .init(), opDecompressor: OpDecompressor = .init(),
    opGroupingManager: OpGroupingManager = .init()
  ) {
    self.opSplitter = opSplitter
    self.opDecompressor = opDecompressor
    self.opGroupingManager = opGroupingManager
  }

  public func process(_ input: JSONValue) throws -> JSONValue? {
    var message = try input.asObject()
    _ = try input.member("clientId").asString()
    if case .string(let text) = message["contents"], !text.utf16.isEmpty {
      message["contents"] = try JSON.parse(text.description)
    }
    guard let reconstructed = try opSplitter.processChunk(message) else {
      return nil
    }
    message = reconstructed
    if try opDecompressor.isCompressedMessage(message) {
      try opDecompressor.decompressAndStore(message)
    }
    if opDecompressor.currentlyUnrolling {
      message = try opDecompressor.unroll(message)
      if !isGroupedBatch(message) {
        try unpack(&message)
      }
    }
    if let contents = message["contents"], case .object(let obj) = contents,
      obj["type"] == string("groupedBatch")
    {
      try require(!batchInProgress, "group interrupts batch")
      let messages = try opGroupingManager.ungroupOp(message).map { entry in
        var inner = try entry.asObject()
        try unpack(&inner)
        return JSONValue.object(inner)
      }
      return object([
        ("type", string("fullBatch")), ("messages", .array(messages)),
        ("batchStart", batchStart(message, key: messages.first ?? .object(message))),
        ("length", number(messages.count)), ("groupedBatch", .bool(true)),
      ])
    }
    if message["type"] == string("op") {
      try unpack(&message)
    }
    let marker = try asBatchMetadata(message["metadata"])?["batch"]
    let value = JSONValue.object(message)
    if !batchInProgress {
      try require(marker != .bool(false), "unexpected batch end")
      if marker == .bool(true) {
        batchInProgress = true
        return object([
          ("type", string("batchStartingMessage")), ("batchStart", batchStart(message, key: value)),
          ("nextMessage", value),
        ])
      }
      return object([
        ("type", string("fullBatch")), ("messages", .array([value])),
        ("batchStart", batchStart(message, key: value)), ("length", number(1)),
        ("groupedBatch", .bool(false)),
      ])
    }
    try require(marker != .bool(true), "unexpected batch start")
    if marker == .bool(false) {
      batchInProgress = false
    }
    return object([
      ("type", string("nextBatchMessage")), ("nextMessage", value),
      ("batchEnd", .bool(marker == .bool(false))),
    ])
  }
  private func unpack(_ message: inout JSObject<JSONValue>) throws {
    guard let contents = message["contents"] else {
      throw JSONDecodingError("missing runtime envelope")
    }
    let envelope = try contents.asObject()
    if envelope["address"] != nil && envelope["type"] == nil {
      message["type"] = string("component")
      return
    }
    message["type"] = envelope["type"]
    message["contents"] = envelope["contents"]
  }
  private func batchStart(_ message: JSObject<JSONValue>, key: JSONValue) -> JSONValue {
    var id: JSONValue?
    if case .object(let metadata) = message["metadata"] {
      id = metadata["batchId"]
    }
    return object([
      ("batchStartCsn", message["clientSequenceNumber"]), ("clientId", message["clientId"]),
      ("batchId", id), ("keyMessage", key),
    ])
  }
}
