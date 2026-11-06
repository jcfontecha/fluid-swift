import FluidJS

/// Ports appendOnlySortedMap.ts. Sorted contiguous entries with predecessor lookup.
public final class AppendOnlySortedMap<Key: Comparable, Value> {
  public private(set) var entries: [(Key, Value)] = []
  public init() {}
  public func append(_ key: Key, _ value: Value) throws {
    if let last = entries.last { try require(last.0 < key, "0x752") }
    entries.append((key, value))
  }
  public func replaceLast(_ key: Key, _ value: Value) throws {
    try require(!entries.isEmpty, "Empty map")
    entries[entries.count - 1] = (key, value)
  }
  public func predecessor(_ key: Key) -> (Key, Value)? {
    var low = 0
    var high = entries.count
    while low < high {
      let mid = (low + high) / 2
      if entries[mid].0 <= key { low = mid + 1 } else { high = mid }
    }
    return low > 0 ? entries[low - 1] : nil
  }
}
