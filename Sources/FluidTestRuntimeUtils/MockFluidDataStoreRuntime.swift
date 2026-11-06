import FluidDatastoreDefinitions
import FluidJS

/// Port of `MockFluidDataStoreRuntime` (test-runtime-utils/src/mocks.ts), the members channels read.
public final class MockFluidDataStoreRuntime: IFluidDataStoreRuntime {
  public var clientId: JSString?
  /// `MockFluidDataStoreRuntime.deltaManagerInternal`.
  public let mockDeltaManager = MockDeltaManager()
  public let quorum = MockQuorumClients()
  public var deltaManager: any IDeltaManager { mockDeltaManager }

  public init(clientId: JSString?) {
    self.clientId = clientId
  }

  public func getQuorum() -> any IQuorumClients { quorum }
}

/// Port of `MockFluidDataStoreContext` (test-runtime-utils/src/mocks.ts), the parent-context members a
/// `FluidDataStoreRuntime` reads.
public final class MockFluidDataStoreContext: IFluidParentContext {
  public let mockDeltaManager = MockDeltaManager()
  public let quorum = MockQuorumClients()
  public var deltaManager: any IDeltaManager { mockDeltaManager }

  public init() {}

  public func getQuorum() -> any IQuorumClients { quorum }
}
