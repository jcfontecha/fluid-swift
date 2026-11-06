/// Ports sessionSpaceNormalizer.ts: run-length encoded generation counts produced as locals.
public final class SessionSpaceNormalizer {
  public let idRanges = AppendOnlySortedMap<Double, Double>()
  public init() {}
  public func addLocalRange(_ base: Double, _ count: Double) throws {
    if let last = idRanges.entries.last, last.0 + last.1 == base {
      try idRanges.replaceLast(last.0, last.1 + count)
    } else {
      try idRanges.append(base, count)
    }
  }
  public func contains(_ local: Double) -> Bool {
    guard let pair = idRanges.predecessor(-local) else { return false }
    return -local <= pair.0 + (pair.1 - 1)
  }
  public func getRangesBetween(_ first: Double, _ last: Double) -> [[Double]] {
    idRanges.entries.compactMap { base, count in
      let start = max(base, first)
      let end = min(base + count - 1, last)
      return start <= end ? [start, end - start + 1] : nil
    }
  }
}
