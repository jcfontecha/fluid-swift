import FluidJS

// Ports mergeTree.ts segment mutation. Client supplies operation stamps and
// translates messages; the tree owns splitting, ordering and range mutation.
extension MergeTree {
  private func splitBoundary(_ position: Int, perspective: Perspective) throws {
    guard let (segment, offset) = containing(position, perspective: perspective), offset > 0 else {
      return
    }
    let right = try segment.split(at: offset)
    insertSplit(right, after: segment)
  }
  func apply(
    _ operation: JSONValue, perspective: Perspective, stamp: Stamp, group: SegmentGroup?,
    minimumSequence: Int, currentSequence: Int
  ) throws -> [BaseSegment] {
    let type = try operation.member("type").asInt()
    guard type == 0 || type == 1 || type == 2 else {
      throw JSONDecodingError("merge-tree operation \(type) is not implemented")
    }
    if type == 2 {
      _ = try operation.member("props").asObject()
    }
    let start = try operation.member("pos1").asInt()
    try splitBoundary(start, perspective: perspective)
    if type == 0 {
      let payload = try operation.member("seg")
      let segment: BaseSegment
      switch payload {
      case .string(let text): segment = TextSegment(text: text, insertion: stamp)
      case .object(let fields):
        let props = try fields["props"].map { try $0.asObject() }
        if let text = fields["text"] {
          segment = TextSegment(text: try text.asString(), insertion: stamp, properties: props)
        } else {
          segment = Marker(
            refType: try payload.member("marker").member("refType").asInt(), insertion: stamp,
            properties: props)
        }
      default: throw JSONDecodingError("invalid segment payload")
      }
      if segment.length == 0 { return [] }
      let next = insertionTarget(
        at: start, perspective: perspective, stamp: stamp,
        minimum: minimumSequence)
      insert(segment, before: next)
      if let group {
        group.link(segment)
      } else {
        schedule(segment, sequence: stamp.sequence, current: currentSequence)
      }
    } else {
      let end = try operation.member("pos2").asInt()
      try splitBoundary(end, perspective: perspective)
      var removed: [BaseSegment] = []
      for segment in range(start, end, perspective: perspective) {
        let before = segment.clone()
        if let group {
          group.link(segment)
        } else {
          schedule(segment, sequence: stamp.sequence, current: currentSequence)
        }
        if type == 2 {
          let updates = try operation.member("props").asObject()
          var properties = segment.properties
          segment.propertyManager.handleProperties(updates, properties: &properties, stamp: stamp)
          segment.properties = properties
        } else {
          if stamp.sequence != -1 { removed.append(segment) }
          segment.removals.append(stamp)
          segment.removals.sort()
          update(segment, before: before)
        }
      }
      return removed
    }
    return []
  }
}
