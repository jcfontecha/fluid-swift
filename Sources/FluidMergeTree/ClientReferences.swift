import FluidJS

extension Client {
  public func createLocalReferencePosition(
    at position: Int, refType: Int, slidingPreference: SlidingPreference = .forward,
    canSlideToEndpoint: Bool = false
  ) throws -> LocalReference {
    guard position >= 0, let (segment, offset) = mergeTree.containing(position, perspective: .local)
    else {
      throw JSONDecodingError("reference out of bounds")
    }
    let ref = try LocalReference(
      segment: segment, offset: offset, refType: refType,
      slidingPreference: slidingPreference, canSlideToEndpoint: canSlideToEndpoint)
    segment.localRefs.addLocalRef(ref, offset: offset)
    return ref
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
    for preference in [SlidingPreference.forward, .backward] {
      for endpoint in [false, true] {
        var groups: [(destination: Int?, forward: Bool, refs: [LocalReference])] = []
        for segment in removed {
          guard let index = segments.firstIndex(where: { $0 === segment }) else { continue }
          let refs = segment.localRefs.references.filter {
            $0.slidingPreference == preference && $0.canSlideToEndpoint == endpoint
          }
          if refs.isEmpty { continue }
          let present: (BaseSegment) -> Bool = {
            $0.insertion.sequence != -1 && !$0.removals.contains { $0.sequence != -1 }
          }
          let forward = preference == .forward
          let destination =
            adjacent(to: index, forward: forward, present: present)
            ?? (referencesCanSlideToEndpoint
              ? nil : adjacent(to: index, forward: !forward, present: present))
          let slideForward = destination.map { $0 > index } ?? false
          if let last = groups.indices.last, groups[last].destination == destination,
            groups[last].forward == slideForward
          {
            groups[last].refs.append(contentsOf: refs)
          } else {
            groups.append((destination, slideForward, refs))
          }
        }
        for group in groups {
          var preceding: LocalReference?
          for ref in group.refs where !ref.includes(128) {
            if let destination = group.destination {
              if ref.includes(64) {
                ref.beforeSlide?(ref)
                let target = segments[destination]
                target.localRefs.addSliding(ref, forward: group.forward, preceding: preceding)
                preceding = ref
                ref.afterSlide?(ref)
              } else {
                ref.segment?.localRefs.removeLocalRef(ref)
              }
            } else {
              ref.beforeSlide?(ref)
              if endpoint && referencesCanSlideToEndpoint && ref.includes(64) {
                let target = preference == .forward ? endOfTree : startOfTree
                target.localRefs.addSliding(
                  ref, forward: preference == .forward, preceding: preceding)
                preceding = ref
              } else {
                ref.segment?.localRefs.removeLocalRef(ref)
              }
              ref.afterSlide?(ref)
            }
          }
        }
      }
    }
  }
}
