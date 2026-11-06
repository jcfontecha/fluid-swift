import FluidJS

/// Ports opLifecycle/opSplitter.ts: UTF-16 chunk framing and per-client reassembly.
public final class OpSplitter {
  public let chunkSizeInBytes: Int
  private let maxBatchSizeInBytes: Int
  private let submitBatchFn: (([JSONValue]) throws -> Int)?
  /// Native append storage for opLifecycle/opSplitter.ts chunk arrays, avoiding per-append COW.
  private final class ChunkBuffer {
    var parts: [JSString] = []
  }
  private var chunks = JSObject<ChunkBuffer>()
  public var partialMessages: JSObject<[JSString]> {
    var snapshot = JSObject<[JSString]>()
    for (key, buffer) in chunks.entries {
      snapshot[key] = buffer.parts
    }
    return snapshot
  }

  public init(
    chunkSizeInBytes: Int = 204800, maxBatchSizeInBytes: Int = 1_048_576,
    submitBatchFn: (([JSONValue]) throws -> Int)? = nil
  ) {
    self.chunkSizeInBytes = chunkSizeInBytes
    self.maxBatchSizeInBytes = maxBatchSizeInBytes
    self.submitBatchFn = submitBatchFn
  }

  public func splitSingletonBatchMessage(_ batch: OutboundBatch) throws -> OutboundBatch {
    try require(
      chunkSizeInBytes > 0 && chunkSizeInBytes < maxBatchSizeInBytes, "invalid chunk size")
    try require(batch.messages.count == 1, "expected singleton batch")
    guard let submitBatchFn else {
      throw JSONDecodingError("chunking requires batch submission")
    }
    let chunks = try splitOp(
      batch.messages[0], chunkSize: chunkSizeInBytes,
      extraOp: batch.contentSizeInBytes + 200 >= maxBatchSizeInBytes)
    for chunk in chunks.dropLast() {
      _ = try submitBatchFn([chunk])
    }
    guard let last = chunks.last else {
      throw JSONDecodingError("missing final chunk")
    }
    return OutboundBatch(
      messages: [last], contentSizeInBytes: batch.contentSizeInBytes,
      referenceSequenceNumber: batch.referenceSequenceNumber)
  }

  public func clearPartialMessages(for client: JSString) { chunks[client] = nil }

  public func processChunk(_ input: JSObject<JSONValue>) throws -> JSObject<JSONValue>? {
    var message = input
    guard let clientValue = message["clientId"] else {
      throw JSONDecodingError("missing clientId")
    }
    let client = try clientValue.asString()
    if let contents = message["contents"], case .object(let envelope) = contents,
      envelope["type"] == string("chunkedOp")
    {
      let chunk = try contents.member("contents")
      let id = try chunk.member("chunkId").asInt()
      let total = try chunk.member("totalChunks").asInt()
      let buffer = chunks[client] ?? ChunkBuffer()
      chunks[client] = buffer
      try require(id == buffer.parts.count + 1, "Chunk Id mismatch")
      buffer.parts.append(try chunk.member("contents").asString())
      if id < total {
        return nil
      }
      let joined = JSString(utf16: ContiguousArray(buffer.parts.flatMap(\.utf16)))
      chunks[client] = nil
      message["contents"] = joined.length == 0 ? nil : try JSON.parse(joined.description)
      message["type"] = try field(chunk, "originalType")
      message["metadata"] = try field(chunk, "originalMetadata")
      message["compression"] = try field(chunk, "originalCompression")
    }
    return message
  }
}

/// Ports opLifecycle/opSplitter.ts: splitOp preserves JS string offsets, including lone surrogates.
public func splitOp(_ message: JSONValue, chunkSize: Int, extraOp: Bool = false) throws
  -> [JSONValue]
{
  try require(chunkSize > 0, "invalid chunk size")
  let text = try message.member("contents").asString().utf16
  let count = (text.count + chunkSize - 1) / chunkSize + (extraOp ? 1 : 0)
  let meta = try field(message, "metadata")
  var result: [JSONValue] = []
  result.reserveCapacity(count)
  for i in 0..<count {
    let start = min(i * chunkSize, text.count)
    let end = min((i + 1) * chunkSize, text.count)
    let final = i == count - 1
    let chunk = object([
      ("chunkId", number(i + 1)),
      ("contents", .string(JSString(utf16: ContiguousArray(text[start..<end])))),
      ("totalChunks", number(count)), ("originalMetadata", final ? meta : nil),
      ("originalCompression", final ? try field(message, "compression") : nil),
      ("originalType", final ? string("component") : nil),
    ])
    result.append(
      object([
        (
          "contents",
          string(JSON.stringify(object([("type", string("chunkedOp")), ("contents", chunk)])))
        ),
        (
          "metadata",
          final
            ? object([
              ("batch", try meta.flatMap { try field($0, "batch") }),
              ("groupedOpCount", try meta.flatMap { try field($0, "groupedOpCount") }),
            ]) : nil
        ),
        ("referenceSequenceNumber", try message.member("referenceSequenceNumber")),
      ]))
  }
  return result
}
