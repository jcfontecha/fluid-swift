/// Port of `packages/dds/ordered-collection/src/interfaces.ts` ConsensusResult.
public enum ConsensusResult: Sendable {
  /// The item goes back to the collection for another client (TS `ConsensusResult.Release`).
  case release
  /// The item is done (TS `ConsensusResult.Complete`).
  case complete
}
