import FluidJS

/// Ports sequence.ts's merge-tree or interval local metadata union without untyped payloads.
public enum SequenceLocalOpMetadata {
  case segment(localSequence: Int)
  case interval(label: JSString, metadata: IntervalLocalOpMetadata)

  var localSequence: Int {
    switch self {
    case .segment(let sequence): sequence
    case .interval(_, let metadata): metadata.localSequence
    }
  }
}
