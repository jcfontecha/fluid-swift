import FluidJS

/// Ports mergeTree.ts structural insertion and zamboni.ts block reclamation.
/// Client owns operation sequencing; this type owns physical segment membership.
public final class MergeTree {
  private(set) var root = MergeBlock()
  private struct Scour {
    var segment: BaseSegment?
    var sequence: Int
  }
  private var scour: [Scour] = []
  private var cachedSegments: ContiguousArray<BaseSegment>?
  var segments: ContiguousArray<BaseSegment> {
    if let cachedSegments { return cachedSegments }
    let result = root.segments
    cachedSegments = result
    return result
  }

  func position(of segment: BaseSegment, perspective: Perspective) -> Int {
    var total = 0
    var target = MergeBlock.Child.segment(segment)
    var parent = segment.parent
    while let block = parent {
      for child in block.children {
        switch (child, target) {
        case (.segment(let a), .segment(let b)) where a === b: break
        case (.block(let a), .block(let b)) where a === b: break
        default:
          switch child {
          case .segment(let leaf): total += perspective.contains(leaf) ? leaf.length : 0
          case .block(let nested): total += nested.length(from: perspective)
          }
          continue
        }
        break
      }
      target = .block(block)
      parent = block.parent
    }
    return total
  }

  func normalizeSegmentsOnRebase() {
    var run: [BaseSegment] = []
    func normalize() {
      defer { run = [] }
      let remotelyRemoved: (BaseSegment) -> Bool = { $0.removals.contains { $0.sequence != -1 } }
      guard run.count > 1, run.contains(where: { $0.insertion.sequence == -1 }),
        run.contains(where: remotelyRemoved),
        let lastLocal = run.last(where: { !remotelyRemoved($0) })
      else { return }
      let original = run
      for segment in original.reversed() {
        guard let source = run.firstIndex(where: { $0 === segment }) else { continue }
        if remotelyRemoved(segment) {
          guard let destination = run.firstIndex(where: { $0 === lastLocal }), source < destination
          else { continue }
          run.remove(at: source)
          run.insert(segment, at: destination)
        } else if let removal = segment.removals.first {
          var destination = source
          while destination + 1 < run.count {
            let next = run[destination + 1]
            if remotelyRemoved(next) || next.insertion.localSequence == nil
              || !(removal < next.insertion)
            {
              break
            }
            destination += 1
          }
          if destination != source {
            run.remove(at: source)
            run.insert(segment, at: destination)
          }
        }
      }
      let slots = original.compactMap { segment -> (MergeBlock, Int)? in
        guard let parent = segment.parent,
          let index = parent.children.firstIndex(where: {
            if case .segment(let leaf) = $0 { return leaf === segment }
            return false
          })
        else { return nil }
        return (parent, index)
      }
      precondition(slots.count == run.count)
      for segment in run {
        for ref in segment.localRefs.references { ref.beforeSlide?(ref) }
      }
      for (index, segment) in run.enumerated() {
        let (parent, slot) = slots[index]
        parent.children[slot] = .segment(segment)
        segment.parent = parent
      }
      for (parent, _) in slots { refreshPath(parent) }
      cachedSegments = nil
      for segment in run {
        for ref in segment.localRefs.references { ref.afterSlide?(ref) }
      }
    }
    for segment in segments {
      if !segment.removals.isEmpty || segment.insertion.sequence == -1 {
        run.append(segment)
      } else {
        normalize()
      }
    }
    normalize()
  }

  func reload(_ segments: [BaseSegment]) {
    scour = []
    cachedSegments = nil
    var nodes = segments.map { MergeBlock.Child.segment($0) }
    repeat {
      var blocks: [MergeBlock.Child] = []
      for offset in stride(from: 0, to: nodes.count, by: 7) {
        let block = MergeBlock()
        block.children = Array(nodes[offset..<min(offset + 7, nodes.count)])
        block.assignParents()
        block.refresh()
        blocks.append(.block(block))
      }
      if blocks.isEmpty {
        root = MergeBlock()
        return
      }
      if blocks.count == 1, case .block(let block) = blocks[0] {
        root = block
        return
      }
      nodes = blocks
    } while true
  }

  func update(_ segment: BaseSegment, before: BaseSegment? = nil) {
    let added = PartialSequenceLengths(segments: [segment], minimumSequence: 0)
    let removed = PartialSequenceLengths(segments: before.map { [$0] } ?? [], minimumSequence: 0)
    let delta =
      (Perspective.local.contains(segment) ? segment.length : 0)
      - (before.map { Perspective.local.contains($0) ? $0.length : 0 } ?? 0)
    var block = segment.parent
    while let current = block {
      pruneHistory(current)
      current.localLength += delta
      current.partialLengths.add(removed, scale: -1)
      current.partialLengths.add(added)
      block = current.parent
    }
  }

  // Minimum advancement does not scan the document. Cold blocks prune lazily
  // when an edit or indexed lookup next visits them, as in TS partial lengths.
  private func pruneHistory(_ block: MergeBlock) {
    let minimum = root.partialLengths.minimumSequence
    if block.partialLengths.minimumSequence < minimum {
      block.partialLengths.advanceMinimum(to: minimum)
    }
  }

  func refreshPath(_ start: MergeBlock?) {
    var block = start
    while let current = block {
      pruneHistory(current)
      current.refresh()
      block = current.parent
    }
  }

  func containing(_ position: Int, perspective: Perspective) -> (BaseSegment, Int)? {
    func find(_ block: MergeBlock, _ position: Int) -> (BaseSegment, Int)? {
      var remaining = position
      for child in block.children {
        switch child {
        case .segment(let segment):
          let length = perspective.contains(segment) ? segment.length : 0
          if remaining < length { return (segment, remaining) }
          remaining -= length
        case .block(let nested):
          pruneHistory(nested)
          let length = nested.length(from: perspective)
          if remaining < length { return find(nested, remaining) }
          remaining -= length
        }
      }
      return nil
    }
    return find(root, position)
  }

  func insertionTarget(at position: Int, perspective: Perspective, stamp: Stamp, minimum: Int)
    -> BaseSegment?
  {
    func find(_ block: MergeBlock, _ position: Int, last: Bool) -> BaseSegment? {
      var remaining = position
      for (index, child) in block.children.enumerated() {
        let isLast = last && index == block.children.count - 1
        switch child {
        case .segment(let segment):
          if let first = segment.removals.first, first.sequence != -1,
            first.sequence <= minimum, !isLast
          {
            continue
          }
          let count = perspective.contains(segment) ? segment.length : 0
          let tie =
            remaining == 0
            && (segment.insertion < stamp
              || segment.removals.first.map { $0.sequence != -1 && stamp < $0 } == true)
          if remaining < count || (remaining == count && tie) { return segment }
          remaining -= count
        case .block(let nested):
          pruneHistory(nested)
          let count = nested.length(from: perspective)
          if remaining <= count, let found = find(nested, remaining, last: isLast) { return found }
          remaining -= count
        }
      }
      return nil
    }
    return find(root, position, last: true)
  }

  func range(_ start: Int, _ end: Int, perspective: Perspective) -> [BaseSegment] {
    var result: [BaseSegment] = []
    func visit(_ block: MergeBlock, _ base: Int) {
      var position = base
      for child in block.children {
        switch child {
        case .segment(let segment):
          let count = perspective.contains(segment) ? segment.length : 0
          if count > 0 && position >= start && position < end { result.append(segment) }
          position += count
        case .block(let nested):
          pruneHistory(nested)
          let count = nested.length(from: perspective)
          if position < end && position + count > start { visit(nested, position) }
          position += count
        }
        if position >= end { return }
      }
    }
    visit(root, 0)
    return result
  }

  func insert(_ segment: BaseSegment, before next: BaseSegment?) {
    cachedSegments = nil
    let block: MergeBlock
    let index: Int
    if let next, let parent = next.parent,
      let found = parent.children.firstIndex(where: {
        if case .segment(let value) = $0 { return value === next }
        return false
      })
    {
      block = parent
      index = found
    } else {
      var last = root
      while case .block(let child) = last.children.last { last = child }
      block = last
      index = last.children.count
    }
    block.children.insert(.segment(segment), at: index)
    segment.parent = block
    update(segment)
    split(block)
  }

  func insertSplit(_ right: BaseSegment, after left: BaseSegment) {
    cachedSegments = nil
    guard let block = left.parent,
      let index = block.children.firstIndex(where: {
        if case .segment(let segment) = $0 { return segment === left }
        return false
      })
    else { preconditionFailure("split segment has no parent") }
    block.children.insert(.segment(right), at: index + 1)
    right.parent = block
    block.refresh()
    split(block)
  }

  private func split(_ block: MergeBlock) {
    guard block.children.count == 8 else { return }
    let right = MergeBlock()
    right.children = Array(block.children[4...])
    block.children.removeLast(4)
    right.assignParents()
    block.refresh()
    right.refresh()
    if let parent = block.parent,
      let index = parent.children.firstIndex(where: {
        if case .block(let child) = $0 { return child === block }
        return false
      })
    {
      parent.children.insert(.block(right), at: index + 1)
      right.parent = parent
      split(parent)
    } else {
      let parent = MergeBlock()
      parent.children = [.block(block), .block(right)]
      parent.assignParents()
      parent.refresh()
      root = parent
    }
  }

  func schedule(_ segment: BaseSegment, sequence: Int, current: Int) {
    guard let block = segment.parent, block.needsScour != true, sequence > current else { return }
    block.needsScour = true
    scour.append(Scour(segment: segment, sequence: sequence))
    var index = scour.count - 1
    while index > 0 {
      let parent = (index - 1) / 2
      if scour[parent].sequence <= scour[index].sequence { break }
      scour.swapAt(parent, index)
      index = parent
    }
  }

  func zamboni(minimum: Int) {
    if minimum > root.partialLengths.minimumSequence {
      root.partialLengths.advanceMinimum(to: minimum)
    }
    for _ in 0..<2 {
      guard let first = scour.first, first.sequence <= minimum else { break }
      scour.swapAt(0, scour.count - 1)
      scour.removeLast()
      var index = 0
      while index * 2 + 1 < scour.count {
        var child = index * 2 + 1
        if child + 1 < scour.count, scour[child].sequence > scour[child + 1].sequence { child += 1 }
        if scour[index].sequence <= scour[child].sequence { break }
        scour.swapAt(index, child)
        index = child
      }
      guard let block = first.segment?.parent, block.needsScour != false else { continue }
      cachedSegments = nil
      let oldCount = block.children.count
      block.children = scoured(block, minimum: minimum)
      block.needsScour = false
      block.assignParents()
      refreshPath(block)
      if block.children.count < oldCount, block.children.count < 4, let parent = block.parent {
        pack(parent, minimum: minimum)
      }
    }
  }

  private func scoured(_ block: MergeBlock, minimum: Int) -> [MergeBlock.Child] {
    var result: [MergeBlock.Child] = []
    var previous: BaseSegment?
    for child in block.children {
      guard case .segment(let segment) = child, segment.pendingGroups.isEmpty else {
        result.append(child)
        previous = nil
        continue
      }
      if let removal = segment.removals.first {
        if removal.sequence != -1, removal.sequence <= minimum, segment.trackingCollection.empty {
          segment.localRefs.detachOwner()
          segment.parent = nil
        } else {
          result.append(child)
        }
        previous = nil
      } else if segment.insertion.sequence != -1, segment.insertion.sequence <= minimum {
        if let left = previous, left.canAppend(segment),
          (left.properties ?? JSObject()) == (segment.properties ?? JSObject()),
          left.trackingCollection.matches(segment.trackingCollection),
          let lhs = left.text, let rhs = segment.text
        {
          left.localRefs.append(segment.localRefs)
          left.text = JSString(utf16: lhs.utf16 + rhs.utf16)
          segment.trackingCollection.unlinkAll(segment)
          segment.localRefs.detachOwner()
          segment.parent = nil
        } else {
          result.append(child)
          previous = segment
        }
      } else {
        result.append(child)
        previous = nil
      }
    }
    return result
  }

  private func pack(_ parent: MergeBlock, minimum: Int) {
    var nodes: [MergeBlock.Child] = []
    for child in parent.children {
      guard case .block(let block) = child else { preconditionFailure("unbalanced merge tree") }
      nodes.append(contentsOf: scoured(block, minimum: minimum))
      block.parent = nil
    }
    parent.children = []
    if !nodes.isEmpty {
      let count = max(1, min(7, nodes.count / 4))
      let base = nodes.count / count
      let remainder = nodes.count % count
      var offset = 0
      for index in 0..<count {
        let size = base + (index < remainder ? 1 : 0)
        let block = MergeBlock()
        block.children = Array(nodes[offset..<(offset + size)])
        block.assignParents()
        block.refresh()
        parent.children.append(.block(block))
        offset += size
      }
      parent.assignParents()
    }
    refreshPath(parent)
    if parent.children.count < 4, let ancestor = parent.parent {
      pack(ancestor, minimum: minimum)
    }
  }
}
