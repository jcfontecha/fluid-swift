import FluidJS
import FluidMergeTree

/// Ports matrix/src/handlecache.ts. Consecutive reads avoid repeated tree walks.
public final class HandleCache {
  private var handles: [Int] = []
  public init() {}
  public func getHandle(_ position: Int, client: Client) throws -> Int {
    guard position >= 0, position < client.length else { throw JSONDecodingError("matrix position out of bounds") }
    if position >= handles.count {
      for current in handles.count...position {
        guard let found = client.getContainingSegment(current), let segment = found.segment as? PermutationSegment else { throw JSONDecodingError("expected permutation segment") }
        handles.append(segment.start + found.offset)
      }
    }
    return handles[position]
  }
  public func addHandle(_ position: Int, _ handle: Int) {
    if position < handles.count { handles[position] = handle }
  }
  public func itemsChanged(_ position: Int) {
    if position >= 0 && position < handles.count { handles.removeSubrange(position...) }
  }
}
