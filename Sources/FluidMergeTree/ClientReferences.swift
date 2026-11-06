import FluidJS

extension Client {
  public func referencePosition(_ reference: LocalReference) -> SequencePosition {
    if reference.segment === startOfTree { return .start }
    if reference.segment === endOfTree { return .end }
    return .position(localReferencePositionToPosition(reference))
  }

  public func createLocalReferencePosition(at position: SequencePosition, refType: Int,
    slidingPreference: SlidingPreference = .forward, canSlideToEndpoint: Bool = false,
    perspective: Perspective = .local) throws -> LocalReference {
    if case .position(let value) = position {
      return try createLocalReferencePosition(at: value, refType: refType, slidingPreference: slidingPreference,
        canSlideToEndpoint: canSlideToEndpoint, perspective: perspective)
    }
    let segment = position == .start ? startOfTree : endOfTree
    let reference = try LocalReference(segment: segment, offset: 0, refType: refType,
      slidingPreference: slidingPreference, canSlideToEndpoint: canSlideToEndpoint)
    segment.localRefs.addLocalRef(reference, offset: 0)
    return reference
  }

  public func createLocalReferencePosition(
    at position: Int, refType: Int, slidingPreference: SlidingPreference = .forward,
    canSlideToEndpoint: Bool = false, perspective: Perspective = .local
  ) throws -> LocalReference {
    if position == -1 {
      return try LocalReference(segment: nil, offset: 0, refType: refType, slidingPreference: slidingPreference, canSlideToEndpoint: canSlideToEndpoint)
    }
    guard position >= 0, let (segment, offset) = mergeTree.containing(position, perspective: perspective)
    else {
      throw JSONDecodingError("reference out of bounds")
    }
    let ref = try LocalReference(
      segment: segment, offset: offset, refType: refType,
      slidingPreference: slidingPreference, canSlideToEndpoint: canSlideToEndpoint)
    if ref.includes(64) && segment.removals.contains(where: { $0.sequence != -1 }) {
      if let target = slideReferenceDestination(ref) {
        return try cloneReference(ref, at: target.segment, offset: target.offset)
      }
      return try LocalReference(segment: nil, offset: 0, refType: refType,
        slidingPreference: slidingPreference, canSlideToEndpoint: canSlideToEndpoint)
    }
    segment.localRefs.addLocalRef(ref, offset: offset)
    return ref
  }

  public func slideReferenceDestination(_ ref: LocalReference) -> (segment: BaseSegment, offset: Int)? {
    guard let segment = ref.segment else { return nil }
    if segment === startOfTree || segment === endOfTree { return (segment, ref.offset) }
    guard segment.removals.contains(where: { $0.sequence != -1 }) else { return (segment, ref.offset) }
    guard let index = segments.firstIndex(where: { $0 === segment }) else { return nil }
    let forward = ref.slidingPreference == .forward
    let present: (BaseSegment) -> Bool = { $0.insertion.sequence != -1 && !$0.removals.contains { $0.sequence != -1 } }
    let next = adjacent(to: index, forward: forward, present: present)
      ?? (referencesCanSlideToEndpoint ? nil : adjacent(to: index, forward: !forward, present: present))
    guard let next else {
      guard ref.canSlideToEndpoint else { return nil }
      return (forward ? endOfTree : startOfTree, 0)
    }
    return (segments[next], next > index ? 0 : segments[next].length - 1)
  }

  /// Ports getSlideToSegoff with LocalReconnectingPerspective and findReconnectionPosition.
  public func rebaseReference(_ ref: LocalReference, localSequence: Int, squash: Bool = false) -> (segment: BaseSegment, offset: Int, position: Int)? {
    guard let segment = ref.segment else { return nil }
    let perspective = Perspective.reconnecting(sequence: currentSequence, localSequence: localSequence)
    if segment === startOfTree { return (segment, 0, 0) }
    if segment === endOfTree { return (segment, 0, length(from: perspective)) }
    guard let index = segments.firstIndex(where: { $0 === segment }) else { return nil }
    let present: (BaseSegment) -> Bool = { segment in
      if squash && segment.insertion.sequence == -1 && !segment.removals.isEmpty { return false }
      return perspective.contains(segment)
    }
    if present(segment) {
      return (segment, ref.offset, mergeTree.position(of: segment, perspective: perspective) + ref.offset)
    }
    let forward = ref.slidingPreference == .forward
    let next = adjacent(to: index, forward: forward, present: present)
      ?? (referencesCanSlideToEndpoint ? nil : adjacent(to: index, forward: !forward, present: present))
    guard let next else {
      guard ref.canSlideToEndpoint else { return nil }
      return forward ? (endOfTree, 0, length(from: perspective)) : (startOfTree, 0, 0)
    }
    let target = segments[next]
    let offset = next > index ? 0 : target.length - 1
    return (target, offset, mergeTree.position(of: target, perspective: perspective) + offset)
  }

  public func cloneReference(_ ref: LocalReference, at segment: BaseSegment, offset: Int) throws -> LocalReference {
    let replacement = try LocalReference(segment: segment, offset: offset, refType: ref.refType,
      slidingPreference: ref.slidingPreference, canSlideToEndpoint: ref.canSlideToEndpoint)
    replacement.properties = ref.properties
    segment.localRefs.addLocalRef(replacement, offset: offset)
    return replacement
  }

  /// Ports interval acknowledgement: transition pending references, then slide removed anchors.
  public func acknowledgeReference(_ reference: LocalReference) throws {
    guard reference.includes(128) else { return }
    try reference.setReferenceType((reference.refType & ~128) | 64)
    if let segment = reference.segment,
      segment.removals.contains(where: { $0.sequence != -1 }) {
      slideReferences(on: [segment])
    }
  }

  public func removeLocalReferencePosition(_ ref: LocalReference) -> LocalReference? {
    ref.segment?.localRefs.removeLocalRef(ref)
  }

  public func localReferencePositionToPosition(_ ref: LocalReference) -> Int {
    if ref.segment === startOfTree { return 0 }
    if ref.segment === endOfTree { return length }
    guard let segment = ref.segment,
      let index = segments.firstIndex(where: { $0 === segment }),
      ref.includes(256) || segment.localRefs.has(ref)
    else { return -1 }
    if Perspective.local.contains(segment) { return position(of: index) + ref.offset }
    let first = segment.removals.first
    let sequence = first.flatMap { $0.sequence == -1 ? nil : $0.sequence } ?? Int.max
    let perspective: Perspective
    if let local = first?.localSequence {
      perspective = .reconnecting(sequence: sequence, localSequence: local)
    } else {
      perspective = .prior(sequence: sequence, client: id)
    }
    let forward = ref.slidingPreference == .forward
    guard let next = adjacent(to: index, forward: forward, present: { perspective.contains($0) })
    else {
      return forward ? length : 0
    }
    return position(of: next) + (forward ? 0 : segments[next].length - 1)
  }

  private func position(of index: Int) -> Int {
    mergeTree.position(of: segments[index], perspective: .local)
  }

  private func adjacent(to index: Int, forward: Bool, present: (BaseSegment) -> Bool) -> Int? {
    var next = index + (forward ? 1 : -1)
    while segments.indices.contains(next) {
      if present(segments[next]) { return next }
      next += forward ? 1 : -1
    }
    return nil
  }

  /// mergeTree.ts slideAckedRemovedSegmentReferences: all stamps must be updated
  /// before selecting destinations. Pending insertions are never slide targets.
  internal func slideReferences(on removed: [BaseSegment]) {
    struct SlideGroup {
      var destination: Int?
      var forward: Bool
      var references: [LocalReference]
    }
    var forwardGroup: SlideGroup?
    var backwardGroup: SlideGroup?
    let present: (BaseSegment) -> Bool = {
      $0.insertion.sequence != -1 && !$0.removals.contains { $0.sequence != -1 }
    }
    func slide(_ group: SlideGroup?, preference: SlidingPreference) {
      guard let group else { return }
      var preceding: LocalReference?
      if group.destination == nil && referencesCanSlideToEndpoint {
        let endpoint = preference == .forward ? endOfTree : startOfTree
        for ref in group.references where ref.canSlideToEndpoint && ref.includes(64) {
          ref.beforeSlide?(ref)
          endpoint.localRefs.addSliding(ref, forward: group.forward, preceding: preceding)
          preceding = ref
          ref.afterSlide?(ref)
        }
        preceding = nil
      }
      for ref in group.references where !ref.includes(128) {
        if group.destination == nil && referencesCanSlideToEndpoint && ref.canSlideToEndpoint && ref.includes(64) { continue }
        if let destination = group.destination {
          if ref.includes(64) {
            ref.beforeSlide?(ref)
            segments[destination].localRefs.addSliding(ref, forward: group.forward, preceding: preceding)
            preceding = ref
            ref.afterSlide?(ref)
          } else { ref.segment?.localRefs.removeLocalRef(ref) }
        } else {
          ref.beforeSlide?(ref)
          ref.segment?.localRefs.removeLocalRef(ref)
          ref.afterSlide?(ref)
        }
      }
    }
    func append(_ segment: BaseSegment, at index: Int, preference: SlidingPreference, group: inout SlideGroup?) {
      let references = segment.localRefs.references.filter { $0.slidingPreference == preference }
      guard !references.isEmpty else { return }
      let forward = preference == .forward
      let destination = adjacent(to: index, forward: forward, present: present)
        ?? (referencesCanSlideToEndpoint ? nil : adjacent(to: index, forward: !forward, present: present))
      let slideForward = destination.map { $0 > index } ?? false
      if group?.destination != destination || group?.forward != slideForward {
        slide(group, preference: preference)
        group = SlideGroup(destination: destination, forward: slideForward, references: references)
      } else {
        group?.references.append(contentsOf: references)
      }
    }
    // Upstream flushes a direction's preceding group as each segment changes its destination,
    // then flushes the two trailing groups. Grouping all forward slides first changes interval events.
    for segment in removed {
      guard let index = segments.firstIndex(where: { $0 === segment }) else { continue }
      append(segment, at: index, preference: .forward, group: &forwardGroup)
      append(segment, at: index, preference: .backward, group: &backwardGroup)
    }
    slide(forwardGroup, preference: .forward)
    slide(backwardGroup, preference: .backward)
  }
}
