import FluidJS

/// Ports referencePositions.ts compareReferencePositions without resolving visible offsets.
public func compareReferencePositions(_ lhs: LocalReference, _ rhs: LocalReference) -> Int {
  if lhs.segment === rhs.segment { return lhs.offset - rhs.offset }
  guard let left = lhs.segment else { return -1 }
  guard let right = rhs.segment else { return 1 }
  return compareSegmentPositions(left, right)
}

public func compareSegmentPositions(_ left: BaseSegment, _ right: BaseSegment) -> Int {
  if left === right { return 0 }
  if left.endpointType == .start || right.endpointType == .end { return -1 }
  if left.endpointType == .end || right.endpointType == .start { return 1 }
  return left.referenceOrdinal.lexicographicallyPrecedes(right.referenceOrdinal) ? -1 : 1
}

extension BaseSegment {
  var referenceOrdinal: [Int] {
    if let detachedOrdinal { return detachedOrdinal }
    guard let parent else { return [] }
    var path: [Int] = []
    if let index = parent.children.firstIndex(where: {
      if case .segment(let segment) = $0 { return segment === self }
      return false
    }) { path.append(index) }
    var block = parent
    while let parent = block.parent {
      if let index = parent.children.firstIndex(where: {
        if case .block(let child) = $0 { return child === block }
        return false
      }) { path.append(index) }
      block = parent
    }
    return path.reversed()
  }
}
