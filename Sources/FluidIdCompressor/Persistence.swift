import FluidJS
import Foundation

/// Ports persistanceUtilities.ts. Explicit little-endian slots, never Foundation JSON.
struct PersistenceWriter {
  var bytes = Data()
  mutating func word(_ value: UInt64) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
  }
  mutating func number(_ value: Double) { word(value.bitPattern) }
  mutating func uuid(_ value: NumericUuid) {
    word(UInt64(truncatingIfNeeded: value.value))
    word(UInt64(truncatingIfNeeded: value.value >> 64))
  }
}
struct PersistenceReader {
  let bytes: [UInt8]
  var index = 0
  init(_ encoded: String) throws {
    guard let data = Data(base64Encoded: encoded), data.count % 8 == 0 else {
      throw JSONDecodingError("Malformed serialized compressor")
    }
    bytes = Array(data)
  }
  mutating func word() throws -> UInt64 {
    try require(index <= bytes.count - 8, "Truncated serialized compressor")
    var result: UInt64 = 0
    for offset in 0..<8 { result |= UInt64(bytes[index + offset]) << (offset * 8) }
    index += 8
    return result
  }
  mutating func number() throws -> Double { Double(bitPattern: try word()) }
  mutating func count() throws -> Int {
    let value = try number()
    guard let integer = Int(exactly: value), integer >= 0, value <= 9_007_199_254_740_991 else {
      throw JSONDecodingError("Invalid serialized count")
    }
    return integer
  }
  mutating func uuid() throws -> NumericUuid {
    let low = try word()
    let high = try word()
    return NumericUuid(value: UInt128(high) << 64 | UInt128(low))
  }
  mutating func flag() throws -> Bool { try number() == 1 }
}
extension IdCompressor {
  public func serialize(_ hasLocalState: Bool) throws -> String {
    try active(true)
    let stored = sessions.ordered.filter { hasLocalState || !$0.clusterChain.isEmpty }
    var indices: [ObjectIdentifier: Int] = [:]
    for (i, session) in stored.enumerated() { indices[ObjectIdentifier(session)] = i }
    var w = PersistenceWriter()
    w.number(Double(writeVersion))
    w.number(hasLocalState ? 1 : 0)
    w.number(Double(stored.count))
    w.number(Double(finalSpace.clusters.count))
    for s in stored { w.uuid(s.sessionUuid) }
    for c in finalSpace.clusters {
      guard let index = indices[ObjectIdentifier(c.session)] else {
        throw JSONDecodingError("Missing session")
      }
      w.number(Double(index))
      w.number(c.capacity)
      w.number(c.count)
    }
    if hasLocalState {
      w.number(localGenCount)
      w.number(nextRangeBaseGenCount)
      w.number(Double(normalizer.idRanges.entries.count))
      for (base, count) in normalizer.idRanges.entries {
        w.number(base)
        w.number(count)
      }
      if writeVersion >= 3 {
        w.number(shardingState == nil ? 0 : 1)
        if let state = shardingState {
          w.number(state.currentStride)
          w.number(state.originalStride)
          w.number(Double(state.activeChildIds.count))
          for child in state.activeChildIds { try w.uuid(NumericUuid(child)) }
          w.number(state.shardId == nil ? 0 : 1)
          if let id = state.shardId { try w.uuid(NumericUuid(id)) }
        }
      }
    }
    return w.bytes.base64EncodedString()
  }
  public static func deserialize(
    _ serialized: String, newSessionId: String? = nil, requestedWriteVersion: Int = 2
  ) throws -> IdCompressor {
    var r = try PersistenceReader(serialized)
    let version = try r.number()
    if version == 1 { throw JSONDecodingError("IdCompressor version 1.0 is no longer supported.") }
    try require(version == 2 || version == 3, "Unknown IdCompressor serialized version.")
    let local = try r.flag()
    let sessionCount = try r.count()
    let clusterCount = try r.count()
    try require(
      sessionCount <= r.bytes.count / 16 && clusterCount <= r.bytes.count / 24,
      "Invalid serialized counts")
    let sessions = Sessions()
    if local {
      try require(newSessionId == nil, "0x75e")
    } else {
      guard let newSessionId else { throw JSONDecodingError("0x75d") }
      _ = try sessions.getOrCreate(newSessionId)
    }
    for _ in 0..<sessionCount { try sessions.insert(r.uuid()) }
    let compressor = try IdCompressor(
      sessions: sessions, writeVersion: max(requestedWriteVersion, Int(version)))
    var base: Double = 0
    for _ in 0..<clusterCount {
      let index = try r.count() + (local ? 0 : 1)
      try require(index < sessions.ordered.count, "0x9d8")
      let capacity = try r.number()
      let count = try r.number()
      let c = sessions.ordered[index].addNewCluster(base, capacity, count)
      try compressor.finalSpace.addCluster(c)
      base += capacity
    }
    if local {
      compressor.localGenCount = try r.number()
      compressor.nextRangeBaseGenCount = try r.number()
      let pairs = try r.count()
      try require(pairs <= r.bytes.count / 16, "Invalid normalizer count")
      for _ in 0..<pairs { try compressor.normalizer.addLocalRange(r.number(), r.number()) }
      if version >= 3, try r.flag() {
        let current = try r.number()
        let original = try r.number()
        let childCount = try r.count()
        try require(childCount <= r.bytes.count / 16, "Invalid child count")
        var children: [String] = []
        for _ in 0..<childCount {
          let child = try r.uuid().stableId
          if !children.contains(child) { children.append(child) }
        }
        let shardId = try r.flag() ? r.uuid().stableId : nil
        compressor.shardingState = ShardingState(
          currentStride: current, originalStride: original, activeChildIds: children,
          shardId: shardId)
      }
    }
    try require(r.index == r.bytes.count, "0x75f")
    return compressor
  }
}
