import FluidJS
import Foundation

/// Ports the sharding state and token contracts in idCompressor.ts / types/idCompressor.ts.
struct ShardingState {
  var currentStride: Double
  var originalStride: Double
  var activeChildIds: [String]
  var shardId: String?
}
public struct ShardToken {
  public let localGenCount: Double
  public let shardId: String
  public let disposed: Bool
  public init(localGenCount: Double, shardId: String, disposed: Bool) {
    self.localGenCount = localGenCount
    self.shardId = shardId
    self.disposed = disposed
  }
}
public struct ParentShardSynchronizationToken {
  public let type: String
  public let shardId: String
  public let localGenCount: Double
  public init(type: String = "parentIdSpaceShardSyncToken", shardId: String, localGenCount: Double)
  {
    self.type = type
    self.shardId = shardId
    self.localGenCount = localGenCount
  }
}
public struct SerializedIdCompressorShard {
  public let serialized: String
  public let syncToken: ShardToken
}
extension IdCompressor {
  public func shard(_ newShardCount: Double) throws -> [SerializedIdCompressorShard] {
    try active(true)
    try require(
      newShardCount > 0 && newShardCount.rounded(.towardZero) == newShardCount
        && newShardCount <= 9_007_199_254_740_991, "Shard count must be a positive safe integer")
    try require(
      writeVersion >= 3,
      "Sharding requires document version 3 or higher, but this document is version \(writeVersion)"
    )
    let current = shardingState?.currentStride ?? 1
    let stride = current * (newShardCount + 1)
    try require(stride <= 1_000_000, "Sharding limit reached.")
    if shardingState == nil {
      shardingState = ShardingState(currentStride: stride, originalStride: 1, activeChildIds: [])
    } else {
      shardingState?.currentStride = stride
    }
    let serialized = try serialize(true)
    var result: [SerializedIdCompressorShard] = []
    for i in 1...Int(newShardCount) {
      let childId = UUID().uuidString.lowercased()
      shardingState?.activeChildIds.append(childId)
      let child = try Self.deserialize(serialized, requestedWriteVersion: writeVersion)
      let jump = Double(i) * current
      try child.normalizer.addLocalRange(localGenCount + 1, jump)
      child.localGenCount = localGenCount + jump
      child.shardingState = ShardingState(
        currentStride: stride, originalStride: stride, activeChildIds: [], shardId: childId)
      result.append(
        SerializedIdCompressorShard(
          serialized: try child.serialize(true),
          syncToken: ShardToken(
            localGenCount: child.localGenCount, shardId: childId, disposed: false)))
    }
    return result
  }
  private func backfill(_ target: Double, _ stride: Double) throws {
    try require(
      target >= 0 && target <= 9_007_199_254_740_991 && target.rounded(.towardZero) == target,
      "Invalid shard synchronization token generation count.")
    if target <= localGenCount { return }
    let count = ((target - localGenCount + 1) / stride).rounded(.up) * stride
    try require(
      localGenCount + count <= 9_007_199_254_740_991,
      "Shard progress exceeds the supported ID space.")
    try normalizer.addLocalRange(localGenCount + 1, count)
    localGenCount += count
  }
  public func synchronizeWithShard(_ token: ShardToken) throws {
    try active()
    try require(
      writeVersion >= 3,
      "Sharding requires document version 3 or higher, but this document is version \(writeVersion)"
    )
    guard var state = shardingState else { throw JSONDecodingError("Must be in sharding mode.") }
    try require(
      state.activeChildIds.contains(token.shardId),
      "Cannot synchronize with child with ID \(token.shardId): not in active children set")
    let leaf = token.disposed && state.activeChildIds.count == 1
    try backfill(token.localGenCount, leaf ? state.originalStride : state.currentStride)
    if token.disposed {
      state.activeChildIds.removeAll { $0 == token.shardId }
      if leaf { state.currentStride = state.originalStride }
    }
    shardingState = token.disposed && leaf && state.originalStride == 1 ? nil : state
  }
  public func getChildShardSyncToken(_ child: ShardToken) throws -> ParentShardSynchronizationToken
  {
    try active()
    try require(
      shardingState?.activeChildIds.contains(child.shardId) == true,
      "Cannot get a synchronization token for an inactive child shard.")
    return ParentShardSynchronizationToken(shardId: child.shardId, localGenCount: localGenCount)
  }
  public func synchronizeWithParent(_ token: ParentShardSynchronizationToken) throws {
    try active()
    guard let state = shardingState, let id = state.shardId,
      token.type == "parentIdSpaceShardSyncToken", token.shardId == id
    else {
      throw JSONDecodingError("Invalid parent synchronization token for this child shard.")
    }
    try backfill(token.localGenCount, state.currentStride)
  }
  public func getShardSyncToken() throws -> ShardToken? {
    try active()
    guard let state = shardingState else { return nil }
    guard let id = state.shardId else {
      throw JSONDecodingError(
        "Cannot get a token for a root compressor - only shards can be disposed")
    }
    return ShardToken(localGenCount: localGenCount, shardId: id, disposed: false)
  }
  public func disposeShard() throws -> ShardToken? {
    try active()
    guard let state = shardingState else { return nil }
    try require(state.activeChildIds.isEmpty, "Cannot dispose a shard with active children.")
    guard let id = state.shardId else {
      throw JSONDecodingError(
        "Cannot get a token for a root compressor - only shards can be disposed")
    }
    let token = ShardToken(localGenCount: localGenCount, shardId: id, disposed: true)
    disposed = true
    return token
  }
}
