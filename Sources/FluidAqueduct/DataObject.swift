import FluidJS
import FluidDatastore
import FluidMap

/// Ports packages/framework/aqueduct/src/data-objects/dataObject.ts existing-instance loading.
open class DataObject {
    public let root: SharedDirectory
    public init(runtime: FluidDataStoreRuntime) throws {
        guard let root = try runtime.getChannel("root") as? SharedDirectory else {
            throw DatastoreError("DataObject root must be a SharedDirectory")
        }
        self.root = root
    }
}
