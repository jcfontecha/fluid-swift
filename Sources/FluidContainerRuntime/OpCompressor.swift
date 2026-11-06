import FluidJS
import FluidLZ4
import Foundation

/// Ports opLifecycle/opCompressor.ts: compress a serialized singleton in the legacy array wrapper.
public struct OpCompressor {
  public init() {}

  public func compressBatch(_ batch: OutboundBatch) throws -> OutboundBatch {
    try require(
      batch.messages.count == 1 && batch.contentSizeInBytes > 0, "expected nonempty singleton batch"
    )
    var message = try batch.messages[0].asObject()
    let text = try batch.messages[0].member("contents").asString().description
    let packed = Data(try FluidLZ4.compress(Array("[\(text)]".utf8))).base64EncodedString()
    message["contents"] = string(JSON.stringify(object([("packedContents", string(packed))])))
    message["compression"] = string("lz4")
    return OutboundBatch(
      messages: [.object(message)], contentSizeInBytes: packed.count,
      referenceSequenceNumber: batch.referenceSequenceNumber)
  }
}
