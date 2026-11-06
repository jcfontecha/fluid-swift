/// Ports sessions.ts: allocation cluster; shared by the session chain and global final space.
public final class IdCluster {
  public unowned let session: Session
  public let baseFinalId: Double
  public let baseLocalId: Double
  public var capacity: Double
  public var count: Double
  init(session: Session, baseFinalId: Double, baseLocalId: Double, capacity: Double, count: Double)
  {
    self.session = session
    self.baseFinalId = baseFinalId
    self.baseLocalId = baseLocalId
    self.capacity = capacity
    self.count = count
  }
  var lastAllocatedLocal: Double { baseLocalId - (capacity - 1) }
  var lastFinalizedLocal: Double { baseLocalId - (count - 1) }
  func alignedFinal(_ local: Double) -> Double { baseFinalId + (baseLocalId - local) }
  func alignedLocal(_ final: Double) -> Double { baseLocalId - (final - baseFinalId) }
}

/// Ports sessions.ts Session. Ordered cluster chain for one session.
public final class Session {
  public let sessionUuid: NumericUuid
  public private(set) var clusterChain: [IdCluster] = []
  public init(_ numeric: NumericUuid) { sessionUuid = numeric }
  @discardableResult
  public func addNewCluster(_ base: Double, _ capacity: Double, _ count: Double) -> IdCluster {
    let local = clusterChain.last.map { $0.lastAllocatedLocal - 1 } ?? -1
    let c = IdCluster(
      session: self, baseFinalId: base, baseLocalId: local, capacity: capacity, count: count)
    clusterChain.append(c)
    return c
  }
  public func getClusterByLocal(_ local: Double, includeAllocated: Bool) -> IdCluster? {
    var low = 0
    var high = clusterChain.count
    while low < high {
      let mid = (low + high) / 2
      let c = clusterChain[mid]
      let last = includeAllocated ? c.lastAllocatedLocal : c.lastFinalizedLocal
      if local < last {
        low = mid + 1
      } else if local > c.baseLocalId {
        high = mid
      } else {
        return c
      }
    }
    return nil
  }
  public func tryConvertToFinal(_ local: Double, includeAllocated: Bool) -> Double? {
    getClusterByLocal(local, includeAllocated: includeAllocated)?.alignedFinal(local)
  }
  static func containing(_ final: Double, _ clusters: [IdCluster]) -> IdCluster? {
    var low = 0
    var high = clusters.count
    while low < high {
      let mid = (low + high) / 2
      let c = clusters[mid]
      if final < c.baseFinalId {
        high = mid
      } else if final > c.baseFinalId + (c.capacity - 1) {
        low = mid + 1
      } else {
        return c
      }
    }
    return nil
  }
}

/// Ports sessions.ts Sessions. Insertion order is persisted; sorted UUID order handles predecessors.
public final class Sessions {
  public private(set) var ordered: [Session] = []
  private var byId: [String: Session] = [:]
  private var sorted: [Session] = []
  public init() {}
  public func get(_ id: String) -> Session? { byId[id] }
  public func getOrCreate(_ id: String) throws -> Session {
    if let found = byId[id] { return found }
    return try insert(NumericUuid(id), key: id)
  }
  @discardableResult
  func insert(_ uuid: NumericUuid, key: String? = nil) throws -> Session {
    let id = key ?? uuid.stableId
    try require(
      byId[id] == nil && !sorted.contains(where: { $0.sessionUuid == uuid }),
      "Cannot resume existing session.")
    let session = Session(uuid)
    byId[id] = session
    ordered.append(session)
    let index = sorted.firstIndex(where: { $0.sessionUuid > uuid }) ?? sorted.count
    sorted.insert(session, at: index)
    return session
  }
  private func predecessor(_ uuid: NumericUuid, excluding: Session? = nil) -> Session? {
    var low = 0
    var high = sorted.count
    while low < high {
      let mid = (low + high) / 2
      if sorted[mid].sessionUuid <= uuid { low = mid + 1 } else { high = mid }
    }
    guard low > 0 else { return nil }
    let candidate = sorted[low - 1]
    if candidate === excluding { return low > 1 ? sorted[low - 2] : nil }
    return candidate
  }
  public func getContainingCluster(_ uuid: NumericUuid) -> (IdCluster, Double)? {
    guard let s = predecessor(uuid) else { return nil }
    let delta = uuid.value - s.sessionUuid.value
    guard delta <= 9_007_199_254_740_991 else { return nil }
    let local = -(Double(delta) + 1)
    guard let c = s.getClusterByLocal(local, includeAllocated: true) else { return nil }
    return (c, local)
  }
  func clusterCollides(_ c: IdCluster) throws -> Bool {
    let base = try c.session.sessionUuid.offset(-c.baseLocalId - 1)
    let end = try base.offset(c.capacity - 1)
    guard let s = predecessor(end, excluding: c.session), let last = s.clusterChain.last else {
      return false
    }
    return try s.sessionUuid.offset(-last.lastAllocatedLocal - 1) >= base
  }
}
