import FluidJS

extension MergeTreeClient {
  public func createLocalReferencePosition(
    at position: Int, refType: Int, slidingPreference: SlidingPreference = .forward
  ) throws -> LocalReference {
    var remaining = position
    guard remaining >= 0 else { throw JSONDecodingError("reference out of bounds") }
    for segment in segments where Perspective.local.contains(segment) {
      if remaining < segment.length {
        let ref = try LocalReference(segment: segment, offset: remaining, refType: refType,
                                     slidingPreference: slidingPreference)
        segment.localRefs.addLocalRef(ref, offset: remaining)
        return ref
      }
      remaining -= segment.length
    }
    throw JSONDecodingError("reference out of bounds")
  }

  public func removeLocalReferencePosition(_ ref: LocalReference) -> LocalReference? {
    ref.segment?.localRefs.removeLocalRef(ref)
  }

  public func localReferencePositionToPosition(_ ref: LocalReference) -> Int {
    guard let segment = ref.segment,
          let index = segments.firstIndex(where: { $0 === segment }),
          ref.includes(256) || segment.localRefs.has(ref) else { return -1 }
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
    guard let next = adjacent(to: index, forward: forward, present: { perspective.contains($0) }) else {
      return forward ? length : 0
    }
    return position(of: next) + (forward ? 0 : segments[next].length - 1)
  }

  private func position(of index: Int) -> Int {
    segments[..<index].reduce(0) { $0 + (Perspective.local.contains($1) ? $1.length : 0) }
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
      var groups: [(destination: Int?, forward: Bool, refs: [LocalReference])] = []
      for segment in removed {
        guard let index = segments.firstIndex(where: { $0 === segment }) else { continue }
        let refs = segment.localRefs.references.filter { $0.slidingPreference == preference }
        if refs.isEmpty { continue }
        let present: (BaseSegment) -> Bool = {
          $0.insertion.sequence != -1 && !$0.removals.contains { $0.sequence != -1 }
        }
        let forward = preference == .forward
        let destination = adjacent(to: index, forward: forward, present: present)
          ?? adjacent(to: index, forward: !forward, present: present)
        let slideForward = destination.map { $0 > index } ?? false
        if let last = groups.indices.last, groups[last].destination == destination,
           groups[last].forward == slideForward {
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
            ref.segment?.localRefs.removeLocalRef(ref)
            ref.afterSlide?(ref)
          }
        }
      }
    }
  }
}
