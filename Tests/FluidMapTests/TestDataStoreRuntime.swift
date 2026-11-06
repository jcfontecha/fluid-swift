import FluidDatastoreDefinitions
import FluidJS

/// A datastore runtime with a fixed client ID; channels hold it weakly.
final class TestDataStoreRuntime: IFluidDataStoreRuntime {
  var clientId: JSString?
  init(clientId: JSString?) {
    self.clientId = clientId
  }
}
