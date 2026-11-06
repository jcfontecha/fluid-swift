import FluidJS

extension Client {
  /// Ports mergeTree.ts rollback. Rollback is LIFO and never revives a remotely
  /// removed segment. Property rollback operates on identity, not visible ranges.
  public func rollbackPendingOp() throws {
    guard let message = pendingMessages.popLast() else {
      throw JSONDecodingError("rollback without pending operation")
    }
    rollingBack = true
    defer { rollingBack = false }
    var groups: [SegmentGroup] = []
    while pending.count > pendingHead, pending.last?.localSequence == message {
      groups.append(pending.removeLast())
    }
    var removed: [BaseSegment] = []
    for group in groups {
      let type = try group.operation.member("type").asInt()
      var changes: [MergeTreeDeltaSegment] = []
      for segment in group.segments {
        let before = segment.clone()
        group.unlink(segment)
        switch type {
        case 0:
          if Perspective.local.contains(segment) { changes.append(MergeTreeDeltaSegment(segment: segment)) }
          let maintenance = Stamp(sequence: -2, client: "")
          segment.insertion = maintenance
          segment.removals.append(maintenance)
          segment.removals.sort()
          removed.append(segment)
        case 1:
          segment.removals.removeAll { $0.sequence == -1 && $0.localSequence == group.localSequence }
          if !Perspective.local.contains(before) && Perspective.local.contains(segment) {
            changes.append(MergeTreeDeltaSegment(segment: segment))
          }
        case 2:
          var properties = segment.properties
          segment.propertyManager.rollback(
            localSequence: group.localSequence, properties: &properties)
          segment.properties = properties
          var deltas = JSObject<JSONValue>()
          for (key, _) in try group.operation.member("props").asObject().entries {
            if before.properties?[key] != properties?[key] { deltas[key] = before.properties?[key] ?? .null }
          }
          if Perspective.local.contains(segment) { changes.append(MergeTreeDeltaSegment(segment: segment, propertyDeltas: deltas)) }
        default: throw JSONDecodingError("unsupported rollback operation")
        }
        mergeTree.update(segment, before: before)
      }
      if !changes.isEmpty {
        let inverse = type == 0 ? 1 : type == 1 ? 0 : 2
        try delta?(object([("type", .number(Double(inverse)))]), changes, true)
      }
    }
    slideReferences(on: removed)
    mergeTree.zamboni(minimum: minimumSequence)
  }

  /// Ports client.ts resetPendingDeltaToOps for ordinary production operations.
  public func regeneratePendingOps(squash: Bool = false) throws -> [JSONValue] {
    if lastNormalization?.sequence != currentSequence
      || lastNormalization?.localSequence != localSequence || lastNormalization?.squash != squash
    {
      normalizingSquashed = squash
      defer { normalizingSquashed = false }
      try beforeNormalize?()
      mergeTree.normalizeSegmentsOnRebase()
      lastNormalization = (currentSequence, localSequence, squash)
    }
    let original = Array(pending.dropFirst(pendingHead))
    pending = []
    pendingHead = 0
    let order = Dictionary(
      uniqueKeysWithValues: segments.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
    var result: [Int: [JSONValue]] = [:]
    for group in original {
      let type = try group.operation.member("type").asInt()
      let sorted = group.segments.sorted {
        order[ObjectIdentifier($0), default: 0] < order[ObjectIdentifier($1), default: 0]
      }
      var operations: [JSONValue] = []
      for segment in sorted {
        group.unlink(segment)
        let perspective = Perspective.reconnecting(
          sequence: currentSequence, localSequence: group.localSequence)
        let position = mergeTree.position(of: segment, perspective: perspective)
        let removed = segment.removals.contains { $0.sequence != -1 }
        let operation: JSONValue
        switch type {
        case 0:
          if squash && !segment.removals.isEmpty {
            let before = segment.clone()
            let stamp = Stamp(sequence: 0, client: "squash")
            segment.insertion = stamp
            segment.removals = [stamp]
            mergeTree.update(segment, before: before)
            mergeTree.schedule(segment, sequence: 0, current: currentSequence)
            continue
          }
          let copy = segment.clone()
          let payload = try group.operation.member("seg")
          if case .object(let fields) = payload {
            copy.properties = try fields["props"].map { try $0.asObject() }
          } else {
            copy.properties = nil
          }
          operation = object([
            ("pos1", .number(Double(position))), ("seg", copy.toJSON()), ("type", .number(0)),
          ])
        case 1:
          if removed { continue }
          operation = object([
            ("pos1", .number(Double(position))),
            ("pos2", .number(Double(position + segment.length))), ("type", .number(1)),
          ])
        case 2:
          if removed { continue }
          operation = object([
            ("pos1", .number(Double(position))),
            ("pos2", .number(Double(position + segment.length))),
            ("props", try group.operation.member("props")), ("type", .number(2)),
          ])
        default: throw JSONDecodingError("unsupported pending operation")
        }
        let replacement = SegmentGroup(localSequence: group.localSequence, operation: operation)
        replacement.link(segment)
        pending.append(replacement)
        operations.append(operation)
      }
      result[group.localSequence, default: []].append(contentsOf: operations)
    }
    return pendingMessages.map { sequence in
      let operations = result[sequence, default: []]
      return operations.count == 1
        ? operations[0] : object([("ops", .array(operations)), ("type", .number(3))])
    }
  }
}
