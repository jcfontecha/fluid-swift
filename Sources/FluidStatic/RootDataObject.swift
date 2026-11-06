import FluidJS
import FluidAqueduct
import FluidContainerRuntime
import FluidDatastore
import FluidDatastoreDefinitions
import FluidMap

/// Ports packages/framework/fluid-static/src/rootDataObject.ts existing initialObjects resolution.
public final class RootDataObject: DataObject {
    public private(set) var initialObjects: [JSString: any Channel] = [:]
    public init(runtime: ContainerRuntime) throws {
        var rootId: JSString?
        for alias in try runtime.aliases.asArray() {
            let pair = try alias.asArray()
            guard pair.count == 2 else { throw DatastoreError("invalid datastore alias") }
            if pair[0] == .string("rootDOId") { rootId = try pair[1].asString() }
        }
        guard let rootId else { throw DatastoreError("rootDOId alias missing") }
        try super.init(runtime: runtime.channelCollection.getDatastore(rootId))
        guard let directory = try root.getSubDirectory("initial-objects-key") else {
            throw DatastoreError("initialObjects directory missing")
        }
        for (name, value) in try directory.entries() {
            guard let value, try value.member("type") == .string("__fluid_handle__") else {
                throw DatastoreError("initialObject must be a handle")
            }
            let path = try value.member("url").asString().description.split(separator: "/")
            guard path.count == 2 else { throw DatastoreError("invalid initialObject channel path") }
            initialObjects[name] = try runtime.channelCollection.getDatastore(JSString(String(path[0]))).getChannel(JSString(String(path[1])))
        }
    }
}
