import FluidDatastoreDefinitions

/// A runtime that reports `deltaManager.lastSequenceNumber`, the sequence number a write captures as
/// its `refSeq`. `IFluidDataStoreRuntime` does not expose it yet, so the register collection asks for
/// it through this refinement.
public protocol LastSequenceNumberRuntime: IFluidDataStoreRuntime {
  var lastSequenceNumber: Int { get }
}
