import FluidJS
import FluidLZ4
import Foundation

/// Ports opLifecycle/opDecompressor.ts: legacy detection, LZ4 decoding and batch unrolling.
public final class OpDecompressor {
  private var decompressed: [JSONValue] = []
  private var decompressedIndex = 0
  // The initial message may omit a batch marker (legacy singleton compression).
  private var compressedStart = false
  public var currentlyUnrolling: Bool { !decompressed.isEmpty }
  public init() {}

  private func packedContents(_ message: JSObject<JSONValue>) throws -> String? {
    var packed: String?
    if let contents = message["contents"], case .object(let obj) = contents,
      case .string(let text) = obj["packedContents"]
    {
      let s = text.description
      if message["compression"] == string("lz4")
        || (obj.count == 1 && !s.isEmpty && Data(base64Encoded: s)?.base64EncodedString() == s)
      {
        packed = s
      }
    }
    try require(message["compression"] != string("lz4") || packed != nil, "missing packedContents")
    return packed
  }

  public func isCompressedMessage(_ message: JSObject<JSONValue>) throws -> Bool {
    try packedContents(message) != nil
  }

  public func decompressAndStore(_ message: JSObject<JSONValue>) throws {
    let marker = try asBatchMetadata(message["metadata"])?["batch"]
    let packed = try packedContents(message)
    if let packed {
      try require(decompressed.isEmpty, "multiple compressed batches")
      try require(
        message["compression"] == nil || message["compression"] == string("lz4"),
        "unsupported compression")
      guard let bytes = Data(base64Encoded: packed) else {
        throw JSONDecodingError("invalid base64")
      }
      decompressed = try JSON.parse(
        String(decoding: FluidLZ4.decompress(Array(bytes)), as: UTF8.self)
      ).asArray()
      decompressedIndex = 0
      try require(marker == nil || marker == .bool(true), "invalid compressed marker")
    }
    compressedStart = packed != nil
  }

  public func unroll(_ input: JSObject<JSONValue>) throws -> JSObject<JSONValue> {
    var message = input
    let marker = try asBatchMetadata(message["metadata"])?["batch"]
    if !decompressed.isEmpty {
      try require(decompressedIndex < decompressed.count, "compressed array overrun")
      if !compressedStart && marker == nil {
        try require(message["contents"] == nil, "expected empty continuation")
      }
      message["contents"] = decompressed[decompressedIndex]
      message["compression"] = nil
      decompressedIndex += 1
      if marker == .bool(false) || (compressedStart && marker == nil) {
        decompressed.removeAll(keepingCapacity: true)
        decompressedIndex = 0
      }
    }
    compressedStart = false
    return message
  }
}
