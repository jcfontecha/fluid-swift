import FluidJS

/// Ports matrix/src/handletable.ts: slot zero is the free-list head.
public final class HandleTable {
  public private(set) var summary: [Int]
  public init(_ handles: [Int] = [1]) { summary = handles }
  public func allocate() -> Int {
    let free = summary[0]
    summary[0] = free < summary.count ? summary[free] : free + 1
    if free >= summary.count { summary.append(contentsOf: repeatElement(0, count: free + 1 - summary.count)) }
    summary[free] = 0
    return free
  }
  public func free(_ handle: Int) {
    summary[handle] = summary[0]
    summary[0] = handle
  }
}
