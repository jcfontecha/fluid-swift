import FluidJS

/// Ports mergeTreeNodes.ts MergeBlock. Eight children split into two four-child
/// blocks; a stable block therefore contains at most seven children.
public final class MergeBlock {
  enum Child {
    case segment(BaseSegment)
    case block(MergeBlock)
  }
  weak var parent: MergeBlock?
  var children: [Child] = []
  var needsScour: Bool?
  var localLength = 0
  var partialLengths = PartialSequenceLengths(segments: [], minimumSequence: 0)

  func refresh() {
    localLength = 0
    partialLengths = PartialSequenceLengths(
      segments: [], minimumSequence: partialLengths.minimumSequence)
    for child in children {
      switch child {
      case .segment(let segment):
        localLength += Perspective.local.contains(segment) ? segment.length : 0
        partialLengths.add(PartialSequenceLengths(segments: [segment], minimumSequence: 0))
      case .block(let block):
        localLength += block.localLength
        partialLengths.add(block.partialLengths)
      }
    }
  }
  func length(from perspective: Perspective) -> Int {
    switch perspective {
    case .local: return localLength
    case .prior(let sequence, let client):
      return partialLengths.length(sequence: sequence, client: client)
    case .reconnecting(let sequence, let localSequence):
      if let length = partialLengths.reconnectingLength(
        sequence: sequence, localSequence: localSequence)
      {
        return length
      }
      return segments.reduce(0) { $0 + (perspective.contains($1) ? $1.length : 0) }
    }
  }

  func assignParents() {
    for child in children {
      switch child {
      case .segment(let segment): segment.parent = self
      case .block(let block): block.parent = self
      }
    }
  }
  var segments: ContiguousArray<BaseSegment> {
    var result: ContiguousArray<BaseSegment> = []
    for child in children {
      switch child {
      case .segment(let segment): result.append(segment)
      case .block(let block): result.append(contentsOf: block.segments)
      }
    }
    return result
  }
}
