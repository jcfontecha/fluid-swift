import FluidJS

/// Port of `packages/dds/ordered-collection/src/consensusQueue.ts` ConsensusQueueClass, with the type that
/// `consensusOrderedCollectionFactory.ts` registers for the `ConsensusQueue` singleton.
public final class ConsensusQueue: ConsensusOrderedCollection<SnapshotableQueue> {
  public override class var type: JSString { "https://graph.microsoft.com/types/consensus-queue" }
}
