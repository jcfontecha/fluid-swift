import Testing

@testable import FluidIdCompressor

// Ported invariants from src/test/idCompressor.spec.ts (generation, finalization,
// normalization, serialization), numericUuid.spec.ts and sessionSpaceNormalizer.spec.ts.
let sessionA = "00000000-0000-4000-8000-000000000001"
let sessionB = "10000000-0000-4000-8000-000000000001"
@Test func localAndEagerFinals() throws {
  let a = try IdCompressor(sessionA)
  a.nextRequestedClusterSize = 2
  #expect(try a.generateCompressedId() == -1)
  #expect(try a.normalizeToOpSpace(-1) == -1)
  let range = try a.takeNextCreationRange()
  #expect(range.ids?.localIdRanges == [[1, 1]])
  try a.finalizeCreationRange(range)
  #expect(try a.normalizeToOpSpace(-1) == 0)
  #expect(try a.normalizeToSessionSpace(0, originSessionId: sessionB) == -1)
  #expect(try a.generateCompressedId() == 1)
  #expect(try a.generateCompressedId() == 2)
  #expect(try a.generateCompressedId() == -4)
  #expect(try a.recompress(a.decompress(-4)) == -4)
  #expect(try a.takeNextCreationRange().ids?.localIdRanges == [[4, 1]])
}
@Test func interleavedClustersAndOverflow() throws {
  let a = try IdCompressor(sessionA)
  let b = try IdCompressor(sessionB)
  a.nextRequestedClusterSize = 1
  b.nextRequestedClusterSize = 1
  _ = try a.generateCompressedId()
  let first = try a.takeNextCreationRange()
  try a.finalizeCreationRange(first)
  try b.finalizeCreationRange(first)
  _ = try b.generateCompressedId()
  let second = try b.takeNextCreationRange()
  try a.finalizeCreationRange(second)
  try b.finalizeCreationRange(second)
  #expect(try a.generateCompressedId() == 1)
  #expect(try a.generateCompressedId() == -3)
  let third = try a.takeNextCreationRange()
  try a.finalizeCreationRange(third)
  try b.finalizeCreationRange(third)
  #expect(try a.normalizeToOpSpace(-3) == 4)
  #expect(try b.normalizeToSessionSpace(-3, originSessionId: sessionA) == 4)
  #expect(try b.decompress(4) == a.decompress(-3))
  #expect(throws: (any Error).self) { try a.finalizeCreationRange(third) }
}
@Test func pendingAndSummaryRoundTrip() throws {
  let a = try IdCompressor(sessionA, writeVersion: 3)
  _ = try a.generateCompressedId()
  let range = try a.takeNextCreationRange()
  _ = try a.generateCompressedId()
  let saved = try a.serialize(true)
  let resumed = try IdCompressor.deserialize(saved, requestedWriteVersion: 2)
  #expect(try resumed.serialize(true) == saved)
  try resumed.finalizeCreationRange(range)
  try resumed.resetUnfinalizedCreationRange()
  #expect(try resumed.takeNextCreationRange().ids?.firstGenCount == 2)
  let summary = try resumed.serialize(false)
  let loaded = try IdCompressor.deserialize(summary, newSessionId: sessionB)
  #expect(try loaded.serialize(false) == summary)
  #expect(try loaded.generateCompressedId() == -1)
}
@Test func rejectsUnknownAndOutOfOrder() throws {
  let a = try IdCompressor(sessionA)
  #expect(throws: (any Error).self) { try a.decompress(-1) }
  #expect(throws: (any Error).self) { try a.normalizeToOpSpace(-1) }
  #expect(throws: (any Error).self) { try a.normalizeToSessionSpace(0, originSessionId: sessionB) }
  _ = try a.generateCompressedId()
  let first = try a.takeNextCreationRange()
  _ = try a.generateCompressedId()
  let second = try a.takeNextCreationRange()
  #expect(throws: (any Error).self) { try a.finalizeCreationRange(second) }
  try a.finalizeCreationRange(first)
  #expect(throws: (any Error).self) { try a.finalizeCreationRange(first) }
}
@Test func emptyV2Golden() throws {
  let a = try IdCompressor(sessionA)
  #expect(try a.serialize(false) == "AAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
  #expect(try a.takeNextCreationRange().ids == nil)
}
@Test func uuidCarryAcrossVariantAndVersionBits() throws {
  let uuid = try NumericUuid("e507602d-b150-4fcc-bfff-ffffffffffff")
  #expect(try uuid.offset(1).stableId == "e507602d-b150-4fcd-8000-000000000000")
  let zero = try NumericUuid("00000000-0000-4000-8000-000000000000")
  #expect(zero.value == 0)
  #expect(try zero.offset(10_000_000_000_000_000).value == 10_000_000_000_000_000)
  #expect(throws: (any Error).self) { try NumericUuid("00000000-0000-4000-A000-000000000000") }
}
@Test func normalizerTrimsAndCoalescesRanges() throws {
  let n = SessionSpaceNormalizer()
  try n.addLocalRange(1, 2)
  try n.addLocalRange(3, 4)
  try n.addLocalRange(15, 1)
  try n.addLocalRange(16, 2)
  #expect(n.contains(-6))
  #expect(!n.contains(-7))
  #expect(n.contains(-17))
  #expect(n.getRangesBetween(2, 16) == [[2, 5], [15, 2]])
  #expect(n.getRangesBetween(7, 14).isEmpty)
}
@Test func expansionWithOutstandingLocalIDs() throws {
  let a = try IdCompressor(sessionA)
  a.nextRequestedClusterSize = 1
  _ = try a.generateCompressedId()
  let one = try a.takeNextCreationRange()
  _ = try a.generateCompressedId()
  let two = try a.takeNextCreationRange()
  _ = try a.generateCompressedId()
  try a.finalizeCreationRange(one)
  #expect(try a.generateCompressedId() == -4)
  try a.finalizeCreationRange(two)
  #expect(try a.generateCompressedId() == -5)
  try a.finalizeCreationRange(a.takeNextCreationRange())
  #expect(try a.generateCompressedId() == 5)
  #expect(try a.normalizeToSessionSpace(3, originSessionId: sessionB) == -4)
}
@Test func equalityIgnoresWriteVersionAndSessionInsertionOrder() throws {
  let a = try IdCompressor(sessionA)
  let b = try IdCompressor(sessionB, writeVersion: 3)
  #expect(try a.equals(b, includeLocalState: false))
  let c = try IdCompressor(sessionA, writeVersion: 3)
  #expect(try a.equals(c, includeLocalState: true))
}
@Test func shardingRoundTripAndReclaim() throws {
  let a = try IdCompressor(sessionA, writeVersion: 3)
  let shards = try a.shard(1)
  let entry = try #require(shards.first)
  let child = try IdCompressor.deserialize(entry.serialized)
  #expect(try a.generateCompressedId() == -2)
  #expect(try child.generateCompressedId() == -3)
  #expect(throws: (any Error).self) { try child.takeNextCreationRange() }
  let saved = try child.serialize(true)
  #expect(try IdCompressor.deserialize(saved).serialize(true) == saved)
  let progress = try #require(try child.getShardSyncToken())
  try a.synchronizeWithShard(progress)
  #expect(try a.generateCompressedId() == -6)
  let parentToken = try a.getChildShardSyncToken(progress)
  try child.synchronizeWithParent(parentToken)
  #expect(try child.generateCompressedId() == -9)
  let disposed = try #require(try child.disposeShard())
  try a.synchronizeWithShard(disposed)
  #expect(throws: (any Error).self) { try child.generateCompressedId() }
  #expect(try a.generateCompressedId() == -11)
}
@Test func ghostSessionAllocatesAtConsensusAndCleansUpOnThrow() throws {
  let a = try IdCompressor(sessionA)
  try a.beginGhostSession(sessionB) { () throws -> Void in
    #expect(try a.generateCompressedId() == 0)
    #expect(try a.generateCompressedId() == 1)
    #expect(throws: (any Error).self) { try a.takeNextCreationRange() }
  }
  #expect(try a.generateCompressedId() == -1)
  #expect(try a.decompress(0) == sessionB)
}
@Test func noOpGhostDoesNotPersistAnEmptySession() throws {
  let a = try IdCompressor(sessionA)
  let saved = try a.serialize(true)
  try a.beginGhostSession(sessionB) {}
  #expect(try a.serialize(true) == saved)
}
@Test(arguments: [2, 3]) func clusterCapacityEdges(version: Int) throws {
  for capacity: Double in [1, 2, 512, 1_048_576] {
    let a = try IdCompressor(sessionA, writeVersion: version)
    a.nextRequestedClusterSize = capacity
    _ = try a.generateCompressedId()
    let range = try a.takeNextCreationRange()
    try a.finalizeCreationRange(range)
    #expect(a.localSession.clusterChain.last?.capacity == capacity + 1)
    #expect(try a.generateCompressedId() == 1)
    #expect(try IdCompressor.deserialize(a.serialize(true)).serialize(true) == a.serialize(true))
  }
}
@Test(arguments: [0.0, -1, 1_048_577]) func invalidClusterSizes(size: Double) throws {
  let a = try IdCompressor(sessionA)
  a.nextRequestedClusterSize = size
  _ = try a.generateCompressedId()
  #expect(throws: (any Error).self) { try a.takeNextCreationRange() }
}
@Test func collisionIsDetected() throws {
  let a = try IdCompressor(sessionA)
  _ = try a.generateCompressedId()
  try a.finalizeCreationRange(a.takeNextCreationRange())
  let near = IdCreationRange(
    sessionId: "00000000-0000-4000-8000-000000000002",
    ids: .init(firstGenCount: 1, count: 1, requestedClusterSize: 1, localIdRanges: [[1, 1]]))
  #expect(throws: (any Error).self) { try a.finalizeCreationRange(near) }
}
@Test func reservedButUnfinalizedRemoteIDIsNotDecompressible() throws {
  let a = try IdCompressor(sessionA)
  let b = try IdCompressor(sessionB)
  _ = try a.generateCompressedId()
  let range = try a.takeNextCreationRange()
  try a.finalizeCreationRange(range)
  try b.finalizeCreationRange(range)
  #expect(try a.generateCompressedId() == 1)
  #expect(throws: (any Error).self) { try b.decompress(1) }
  #expect(throws: (any Error).self) { try b.normalizeToSessionSpace(-2, originSessionId: sessionA) }
  // TS intentionally permits recompression against reserved remote space.
  #expect(try b.recompress(a.decompress(1)) == 1)
}
@Test func malformedPersistenceDoesNotTrap() throws {
  for encoded in [
    "", "AA==", "AAAAAAAA8D8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    "AAAAAAAAEEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  ] {
    #expect(throws: (any Error).self) {
      try IdCompressor.deserialize(encoded, newSessionId: sessionB)
    }
  }
  let a = try IdCompressor(sessionA)
  #expect(throws: (any Error).self) {
    try IdCompressor.deserialize(a.serialize(true), newSessionId: sessionB)
  }
  #expect(throws: (any Error).self) { try IdCompressor.deserialize(a.serialize(false)) }
}

@Test func reconnectRetakesAllOutstandingRangesAndNewIDs() throws {
  let a = try IdCompressor(sessionA)
  _ = try a.generateCompressedId()
  let first = try a.takeNextCreationRange()
  _ = try a.generateCompressedId()
  _ = try a.takeNextCreationRange()
  _ = try a.generateCompressedId()
  _ = try a.takeNextCreationRange()
  try a.resetUnfinalizedCreationRange()
  try a.resetUnfinalizedCreationRange()
  _ = try a.generateCompressedId()
  let replay = try a.takeNextCreationRange()
  #expect(replay.ids?.firstGenCount == 1)
  #expect(replay.ids?.count == 4)
  #expect(replay.ids?.localIdRanges == [[1, 4]])
  try a.finalizeCreationRange(first)
  let remainder = try a.takeUnfinalizedCreationRange()
  #expect(remainder.ids?.firstGenCount == 2)
  #expect(remainder.ids?.count == 3)
  try a.finalizeCreationRange(remainder)
  #expect(try a.takeUnfinalizedCreationRange().ids == nil)
}

@Test func ghostCallbackThrowRestoresNormalMode() throws {
  let a = try IdCompressor(sessionA)
  #expect(throws: (any Error).self) {
    try a.beginGhostSession(sessionB) { () throws -> Void in
      _ = try a.generateCompressedId()
      throw TestGhostError.callback
    }
  }
  #expect(try a.generateCompressedId() == -1)
  #expect(try a.decompress(0) == sessionB)
  _ = try a.serialize(true)
}
private enum TestGhostError: Error { case callback }
