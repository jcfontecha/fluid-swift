import FluidJS

// Ports mergeTree.ts segment mutation. Client supplies operation stamps and
// translates messages; the tree owns splitting, ordering and range mutation.
extension MergeTree {
  func splitBoundary(_ position: Int, perspective: Perspective) throws {
    guard let (segment, offset) = containing(position, perspective: perspective), offset > 0 else {
      return
    }
    let right = try segment.split(at: offset)
    // TS publishes the split while the right leaf has a parent/temporary ordinal but is not inserted yet.
    right.parent = segment.parent
    right.detachedOrdinal = segment.referenceOrdinal + [0]
    maintenance?(.split, [MergeTreeDeltaSegment(segment: segment), MergeTreeDeltaSegment(segment: right)])
    right.detachedOrdinal = nil
    insertSplit(right, after: segment)
  }
  func apply(
    _ operation: JSONValue, perspective: Perspective, stamp: Stamp, group: SegmentGroup?,
    minimumSequence: Int, currentSequence: Int, segmentFactory: ((JSONValue, Stamp) throws -> BaseSegment)? = nil, delta: (([MergeTreeDeltaSegment]) throws -> Void)? = nil,
    slideBeforeDelta: (([BaseSegment]) -> Void)? = nil
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
      if let segmentFactory {
        segment = try segmentFactory(payload, stamp)
      } else {
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
      try delta?([MergeTreeDeltaSegment(segment: segment)])
    } else {
      let end = try operation.member("pos2").asInt()
      try splitBoundary(end, perspective: perspective)
      var removed: [BaseSegment] = []
      var localOverlap: [BaseSegment] = []
      var changes: [MergeTreeDeltaSegment] = []
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
          let previous = segment.propertyManager.handleProperties(updates, properties: &properties, stamp: stamp)
          segment.properties = properties
          if Perspective.local.contains(segment) { changes.append(MergeTreeDeltaSegment(segment: segment, propertyDeltas: previous)) }
        } else {
          if Perspective.local.contains(segment) { changes.append(MergeTreeDeltaSegment(segment: segment)) }
          if stamp.sequence != -1 {
            if before.removals.isEmpty { removed.append(segment) }
            else if !before.removals.contains(where: { $0.sequence != -1 }) && !segment.localRefs.empty {
              localOverlap.append(segment)
            }
          }
          segment.removals.append(stamp)
          segment.removals.sort()
          update(segment, before: before)
        }
      }
      slideBeforeDelta?(localOverlap)
      if !changes.isEmpty { try delta?(changes) }
      return removed
    }
    return []
  }
}
