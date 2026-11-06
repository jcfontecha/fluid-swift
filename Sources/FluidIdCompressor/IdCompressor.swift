import FluidJS

/// Ports id-compressor/src/idCompressor.ts. Synchronous ID allocation and consensus finalization.
public final class IdCompressor {
  public static let maxClusterSize: Double = 1_048_576
  public let localSessionId: String
  public let writeVersion: Int
  let sessions: Sessions
  let localSession: Session
  let finalSpace = FinalSpace()
  let normalizer = SessionSpaceNormalizer()
  var localGenCount: Double = 0
  var nextRangeBaseGenCount: Double = 1
  public var nextRequestedClusterSize: Double = 512
  var shardingState: ShardingState?
  var ghostSession: String?
  var ghostCluster: IdCluster?
  var disposed = false
  public var rangeFinalized: ((IdCreationRange) -> Void)?

  public convenience init(_ sessionId: String, writeVersion: Int = 2) throws {
    let sessions = Sessions()
    _ = try sessions.getOrCreate(sessionId)
    try self.init(sessions: sessions, writeVersion: writeVersion, localId: sessionId)
  }
  init(sessions: Sessions, writeVersion: Int, localId: String? = nil) throws {
    guard let local = sessions.ordered.first else { throw JSONDecodingError("0x754") }
    self.sessions = sessions
    self.localSession = local
    self.localSessionId = localId ?? local.sessionUuid.stableId
    self.writeVersion = writeVersion
    try require(writeVersion == 2 || writeVersion == 3, "Unknown IdCompressor serialized version.")
  }
  func active(_ normal: Bool = false) throws {
    try require(
      !disposed, "This compressor has been disposed via disposeShard() and can no longer be used.")
    if normal {
      try require(
        ghostSession == nil, "IdCompressor should not be operated normally when in a ghost session")
    }
  }
  public func generateCompressedId() throws -> Double {
    try active()
    if let ghost = ghostSession {
      if let cluster = ghostCluster {
        cluster.capacity += 1
        cluster.count += 1
        return cluster.baseFinalId + cluster.count - 1
      }
      let cluster = try addEmptyCluster(sessions.getOrCreate(ghost), 1)
      ghostCluster = cluster
      cluster.count = 1
      return cluster.baseFinalId
    }
    if let state = shardingState {
      try normalizer.addLocalRange(localGenCount + 1, state.currentStride)
      localGenCount += state.currentStride
      return -localGenCount
    }
    localGenCount += 1
    if let last = localSession.clusterChain.last {
      let offset = localGenCount - (-last.baseLocalId)
      if last.capacity > offset { return last.baseFinalId + offset }
    }
    try normalizer.addLocalRange(localGenCount, 1)
    return -localGenCount
  }
  public func generateDocumentUniqueId() throws -> JSONValue {
    let id = try generateCompressedId()
    return id >= 0 ? .number(id) : .string(JSString(try decompress(id)))
  }
  public func beginGhostSession(_ sessionId: String, _ callback: () throws -> Void) throws {
    try active(true)
    try require(shardingState == nil, "Cannot start a ghost session while sharded.")
    ghostSession = sessionId
    defer {
      ghostSession = nil
      ghostCluster = nil
    }
    try callback()
  }
  public func takeNextCreationRange() throws -> IdCreationRange {
    try active(true)
    try require(
      shardingState?.shardId == nil, "Cannot take a creation range from a non-root shard.")
    let count = localGenCount - (nextRangeBaseGenCount - 1)
    if count == 0 { return IdCreationRange(sessionId: localSessionId) }
    let range = IdCreationRange(
      sessionId: localSessionId,
      ids: .init(
        firstGenCount: nextRangeBaseGenCount, count: count,
        requestedClusterSize: nextRequestedClusterSize,
        localIdRanges: normalizer.getRangesBetween(nextRangeBaseGenCount, localGenCount)))
    nextRangeBaseGenCount = localGenCount + 1
    try validate(range)
    return range
  }
  public func resetUnfinalizedCreationRange() throws {
    try active(true)
    nextRangeBaseGenCount = localSession.clusterChain.last.map { -($0.baseLocalId - $0.count) } ?? 1
  }
  public func takeUnfinalizedCreationRange() throws -> IdCreationRange {
    try resetUnfinalizedCreationRange()
    return try takeNextCreationRange()
  }
  private func validate(_ range: IdCreationRange) throws {
    guard let ids = range.ids else { return }
    try require(ids.count > 0, "0x755")
    try require(ids.requestedClusterSize > 0, "0x876")
    try require(ids.requestedClusterSize <= Self.maxClusterSize, "0x877")
  }
  public func finalizeCreationRange(_ range: IdCreationRange) throws {
    try active(true)
    guard let ids = range.ids else { return }
    try validate(range)
    let session = try sessions.getOrCreate(range.sessionId)
    let baseLocal = -ids.firstGenCount
    let last: IdCluster
    if let existing = session.clusterChain.last {
      last = existing
    } else {
      try require(baseLocal == -1, "Ranges finalized out of order")
      last = try addEmptyCluster(session, ids.requestedClusterSize + ids.count)
    }
    let remaining = last.capacity - last.count
    try require(last.baseLocalId - last.count == baseLocal, "Ranges finalized out of order")
    if remaining >= ids.count {
      last.count += ids.count
    } else {
      let overflow = ids.count - remaining
      let claimed = overflow + ids.requestedClusterSize
      if last === finalSpace.clusters.last {
        last.capacity += claimed
        last.count += ids.count
        try require(!sessions.clusterCollides(last), "0x756")
      } else {
        last.count = last.capacity
        let next = try addEmptyCluster(session, claimed)
        next.count += overflow
      }
    }
    rangeFinalized?(range)
  }
  private func addEmptyCluster(_ session: Session, _ capacity: Double) throws -> IdCluster {
    try require(ghostCluster == nil, "0x8a8")
    let c = session.addNewCluster(finalSpace.allocatedIdLimit, capacity, 0)
    try require(!sessions.clusterCollides(c), "0x758")
    try finalSpace.addCluster(c)
    return c
  }
  public func normalizeToOpSpace(_ id: Double) throws -> Double {
    try active()
    if id >= 0 { return id }
    try require(normalizer.contains(id), "Invalid ID to normalize.")
    return localSession.tryConvertToFinal(id, includeAllocated: true) ?? id
  }
  public func tryNormalizeToSessionSpaceWithoutSession(_ id: Double) throws -> Double? {
    try active()
    if id < 0 { return nil }
    if let c = Session.containing(id, localSession.clusterChain) {
      let local = c.alignedLocal(id)
      if normalizer.contains(local) { return local }
      try require(-local <= localGenCount, "Unknown op space ID.")
      return id
    }
    try require(id < finalSpace.finalizedIdLimit, "Unknown op space ID.")
    return id
  }
  public func normalizeToSessionSpace(_ id: Double, originSessionId: String) throws -> Double {
    if let result = try tryNormalizeToSessionSpaceWithoutSession(id) { return result }
    if originSessionId == localSessionId {
      try require(normalizer.contains(id), "Unknown op space ID.")
      return id
    }
    guard let remote = sessions.get(originSessionId) else {
      throw JSONDecodingError("No IDs have ever been finalized by the supplied session.")
    }
    guard let final = remote.tryConvertToFinal(id, includeAllocated: false) else {
      throw JSONDecodingError("Unknown op space ID.")
    }
    return final
  }
  public func decompress(_ id: Double) throws -> String {
    try active()
    if id >= 0 {
      guard let c = Session.containing(id, finalSpace.clusters) else {
        throw JSONDecodingError("Unknown ID")
      }
      let local = c.alignedLocal(id)
      if -local > -c.lastFinalizedLocal {
        if c.session === localSession {
          try require(!normalizer.contains(local), "0x759")
        } else {
          throw JSONDecodingError("Unknown ID")
        }
      }
      return try c.session.sessionUuid.offset(-local - 1).stableId
    }
    try require(normalizer.contains(id), "Unknown ID")
    return try localSession.sessionUuid.offset(-id - 1).stableId
  }
  public func tryRecompress(_ stable: String) throws -> Double? {
    try active()
    let numeric = try NumericUuid(stable)
    if let (c, local) = sessions.getContainingCluster(numeric) {
      if c.session === localSession {
        if normalizer.contains(local) { return local }
        try require(-local <= localGenCount, "0x75a")
        return c.alignedFinal(local)
      }
      // Upstream compares a positive generation count with a negative local ID here.
      return -local >= c.lastFinalizedLocal ? c.alignedFinal(local) : nil
    }
    if numeric >= localSession.sessionUuid {
      let offset = numeric.value - localSession.sessionUuid.value
      if offset < 9_007_199_254_740_991 {
        let local = -(Double(offset) + 1)
        if normalizer.contains(local) { return local }
      }
    }
    return nil
  }
  public func recompress(_ stable: String) throws -> Double {
    guard let value = try tryRecompress(stable) else {
      throw JSONDecodingError("Could not recompress.")
    }
    return value
  }
  public func equals(_ other: IdCompressor, includeLocalState: Bool) throws -> Bool {
    try active()
    try other.active()
    if includeLocalState {
      if localSessionId != other.localSessionId || localGenCount != other.localGenCount
        || nextRangeBaseGenCount != other.nextRangeBaseGenCount
      {
        return false
      }
      let a = normalizer.idRanges.entries
      let b = other.normalizer.idRanges.entries
      if a.count != b.count || !zip(a, b).allSatisfy({ $0.0 == $1.0 && $0.1 == $1.1 }) {
        return false
      }
      if let a = shardingState, let b = other.shardingState {
        if a.currentStride != b.currentStride || a.originalStride != b.originalStride
          || a.shardId != b.shardId || Set(a.activeChildIds) != Set(b.activeChildIds)
        {
          return false
        }
      } else if (shardingState == nil) != (other.shardingState == nil) {
        return false
      }
    }
    func clustersEqual(_ a: IdCluster, _ b: IdCluster) -> Bool {
      a.session.sessionUuid == b.session.sessionUuid && a.baseFinalId == b.baseFinalId
        && a.baseLocalId == b.baseLocalId && a.capacity == b.capacity && a.count == b.count
    }
    let a = finalSpace.clusters
    let b = other.finalSpace.clusters
    return a.count == b.count && zip(a, b).allSatisfy(clustersEqual)
  }
}
