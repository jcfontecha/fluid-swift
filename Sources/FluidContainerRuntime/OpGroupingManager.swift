import FluidJS

/// Ports opLifecycle/opGroupingManager.ts: the upstream grouping configuration.
public struct OpGroupingManagerConfig {
  public var groupedBatchingEnabled: Bool
  public init(groupedBatchingEnabled: Bool = true) {
    self.groupedBatchingEnabled = groupedBatchingEnabled
  }
}

/// Ports opLifecycle/opGroupingManager.ts: grouping, empty replay placeholders and synthetic CSNs.
public struct OpGroupingManager {
  private let config: OpGroupingManagerConfig
  public init(config: OpGroupingManagerConfig = .init()) { self.config = config }
  public func groupedBatchingEnabled() -> Bool { config.groupedBatchingEnabled }

  public func createEmptyGroupedBatch(
    resubmittingBatchId: String, referenceSequenceNumber: Int,
    staged: Bool = false
  ) throws -> (outboundBatch: OutboundBatch, placeholderMessage: LocalBatchMessage) {
    try require(config.groupedBatchingEnabled, "empty replay requires grouping")
    let runtimeOp = object([("type", string("groupedBatch")), ("contents", .array([]))])
    let metadata = object([("batchId", string(resubmittingBatchId)), ("groupedOpCount", number(0))])
    let placeholder = LocalBatchMessage(
      runtimeOp: runtimeOp, referenceSequenceNumber: referenceSequenceNumber,
      metadata: metadata, localOpMetadata: object([("emptyBatch", .bool(true))]), staged: staged)
    let wire = object([
      ("contents", string(JSON.stringify(runtimeOp))), ("metadata", metadata),
      ("referenceSequenceNumber", number(referenceSequenceNumber)),
    ])
    return (
      OutboundBatch(
        messages: [wire], contentSizeInBytes: 0, referenceSequenceNumber: referenceSequenceNumber),
      placeholder
    )
  }

  public func groupBatch(_ batch: OutboundBatch) throws -> OutboundBatch {
    try require(
      config.groupedBatchingEnabled && !batch.messages.isEmpty, "grouping disabled or empty batch")
    if batch.messages.count == 1 {
      return batch
    }
    var groupedBatchId: JSONValue?
    let inner = try batch.messages.map { message -> JSONValue in
      let metadata = try field(message, "metadata")
      if let metadata {
        let properties = try metadata.asObject()
        try require(
          properties.keys.allSatisfy { $0 == "batch" || $0 == "batchId" },
          "cannot group custom metadata")
        if let id = properties["batchId"] {
          groupedBatchId = id
        }
      }
      let contents = try JSON.parse(message.member("contents").asString().description)
      return object([
        ("contents", contents), ("metadata", metadata),
        ("compression", try field(message, "compression")),
      ])
    }
    let contents = object([("type", string("groupedBatch")), ("contents", .array(inner))])
    let wire = object([
      ("contents", string(JSON.stringify(contents))),
      (
        "metadata",
        object([("batchId", groupedBatchId), ("groupedOpCount", number(batch.messages.count))])
      ),
      ("referenceSequenceNumber", number(batch.referenceSequenceNumber)),
    ])
    return OutboundBatch(
      messages: [wire], contentSizeInBytes: batch.contentSizeInBytes,
      referenceSequenceNumber: batch.referenceSequenceNumber)
  }

  public func ungroupOp(_ message: JSObject<JSONValue>) throws -> [JSONValue] {
    guard let contents = message["contents"] else {
      throw JSONDecodingError("missing grouped contents")
    }
    let inner = try contents.member("contents").asArray()
    return try inner.enumerated().map { index, entry -> JSONValue in
      var m = message
      m["clientSequenceNumber"] = number(index + 1)
      m["contents"] = try field(entry, "contents")
      m["metadata"] = try field(entry, "metadata")
      m["compression"] = try field(entry, "compression")
      return .object(m)
    }
  }
}

func isGroupedBatch(_ message: JSObject<JSONValue>) -> Bool {
  guard case .object(let contents) = message["contents"] else {
    return false
  }
  return contents["type"] == string("groupedBatch")
}
