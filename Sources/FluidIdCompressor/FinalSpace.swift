/// Ports finalSpace.ts: contiguous global allocation order.
public final class FinalSpace {
  public private(set) var clusters: [IdCluster] = []
  public init() {}
  public var allocatedIdLimit: Double {
    clusters.last.map { $0.baseFinalId + ($0.capacity - 1) + 1 } ?? 0
  }
  public var finalizedIdLimit: Double {
    clusters.last.map { $0.baseFinalId + ($0.count - 1) + 1 } ?? 0
  }
  public func addCluster(_ c: IdCluster) throws {
    try require(c.baseFinalId == allocatedIdLimit, "0x753")
    clusters.append(c)
  }
}
