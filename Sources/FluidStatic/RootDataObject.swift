import FluidJS
import FluidAqueduct
import FluidContainerDefinitions
import FluidContainerRuntime
import FluidDatastore
import FluidDatastoreDefinitions
import FluidMap
import Foundation

/// rootDataObject.ts `rootDataStoreId`: the alias, not the physical datastore ID.
let rootDataStoreId: JSString = "rootDOId"

/// rootDataObject.ts `rootDataObjectType`: the container registry entry and package path.
let rootDataObjectType: JSString = "rootDO"

/// Ports packages/framework/fluid-static/src/rootDataObject.ts initialObjects resolution.
/// `initialObjects` is assigned in stored directory-entry order, as TS assigns on load completion.
public final class RootDataObject: DataObject {
    public private(set) var initialObjects = JSObject<any Channel>()
    public init(runtime: ContainerRuntime) throws {
        var rootId: JSString?
        for alias in try runtime.aliases.asArray() {
            let pair = try alias.asArray()
            guard pair.count == 2 else { throw DatastoreError("invalid datastore alias") }
            if pair[0] == .string(rootDataStoreId) { rootId = try pair[1].asString() }
        }
        guard let rootId else { throw DatastoreError("default dataStore [rootDOId] must exist") }
        try super.init(runtime: runtime.channelCollection.getDatastore(rootId))
        guard let directory = try root.getSubDirectory("initial-objects-key") else {
            throw DatastoreError("InitialObjects sub-directory was not initialized")
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

/// Ports rootDataObject.ts `RootDataObjectFactory`, a `DataObjectFactory` of type `rootDO`.
/// `sharedObjects` is the root datastore's channel registry.
public final class RootDataObjectFactory {
    public let type: JSString = rootDataObjectType
    public let sharedObjects: [ChannelFactory]

    init(sharedObjects: [ChannelFactory]) throws {
        var factories = sharedObjects
        var types: [JSString] = []
        for factory in factories {
            types.append(try factory.attributes.member("type").asString())
        }
        // aqueduct/src/data-object-factories/dataObjectFactory.ts: DataObjectFactory appends the
        // SharedDirectory factory, then the SharedMap factory, each only if its type is absent.
        if !types.contains(SharedDirectory.type) {
            factories.append(SharedDirectory.getFactory())
            types.append(SharedDirectory.type)
        }
        if !types.contains(SharedMap.type) {
            factories.append(SharedMap.getFactory())
            types.append(SharedMap.type)
        }
        // pureDataObjectFactory.ts: `new Map(sharedObjects.map((ext) => [ext.type, ext]))`. A
        // repeated type keeps its first position and takes the last factory.
        var registry = JSObject<ChannelFactory>()
        for (type, factory) in zip(types, factories) {
            registry[type] = factory
        }
        self.sharedObjects = registry.entries.map(\.value)
    }
}

/// Ports rootDataObject.ts `DOProviderContainerRuntimeFactory`: the container registry holds only
/// the root factory, and runtime options are the version defaults overlaid by the caller's.
public final class DOProviderContainerRuntimeFactory {
    public let rootDataObjectFactory: RootDataObjectFactory
    public let initialObjects: JSObject<any SharedObjectKind.Type>
    public let runtimeOptions: JSObject<JSONValue>
    public let oldestSupportedClient: String

    init(
        schema: ContainerSchema,
        rootDataObjectFactory: RootDataObjectFactory,
        oldestSupportedClient: String,
        runtimeOptions: JSObject<JSONValue>?
    ) {
        var options = defaultRuntimeOptionsForMinVersion(oldestSupportedClient)
        for (key, value) in runtimeOptions?.entries ?? [] {
            options[key] = value
        }
        self.rootDataObjectFactory = rootDataObjectFactory
        self.initialObjects = schema.initialObjects
        self.runtimeOptions = options
        self.oldestSupportedClient = oldestSupportedClient
    }
}

/// Ports rootDataObject.ts `createDOProviderContainerRuntimeFactory`. `rootDataStoreRegistry`
/// is absent because DataObjectKind is not ported.
public func createDOProviderContainerRuntimeFactory(
    schema: ContainerSchema,
    oldestSupportedClient: String,
    runtimeOptionOverrides: JSObject<JSONValue>? = nil
) throws -> DOProviderContainerRuntimeFactory {
    let sharedObjects = try parseDataObjectsFromSharedObjects(schema)
    return DOProviderContainerRuntimeFactory(
        schema: schema,
        rootDataObjectFactory: try RootDataObjectFactory(sharedObjects: sharedObjects),
        oldestSupportedClient: oldestSupportedClient,
        runtimeOptions: runtimeOptionOverrides)
}

/// rootDataObject.ts `DOProviderContainerRuntimeFactory.instantiateRuntime`, through
/// containerRuntime.ts `loadContainerRuntime`: the runtime with the factory's options, the root
/// data object's channel registry, and the root data object as the entry point (provideEntryPoint).
/// Every stored property is immutable and its channel factories capture only types, so the
/// factory is safe to share between containers. New containers initialize the root datastore before publishing the entry point.
extension DOProviderContainerRuntimeFactory: IRuntimeFactory, @unchecked Sendable {
    public func instantiateRuntime(_ context: IContainerContext, existing: Bool) throws
        -> (runtime: ContainerRuntime, entryPoint: AnyObject)
    {
        let runtime = try ContainerRuntime(
            sessionId: UUID().uuidString.lowercased(), clientId: context.clientId?.description ?? "",
            deltaManager: context.deltaManager, quorum: context.quorum, oldestSupportedClient: oldestSupportedClient,
            runtimeOptions: .object(runtimeOptions))
        if existing {
            guard let baseSnapshot = context.baseSnapshot else {
                throw DatastoreError("existing container requires a snapshot")
            }
            try runtime.loadSnapshot(baseSnapshot, factories: rootDataObjectFactory.sharedObjects)
        } else {
            try runtime.initializeDetached()
            let store = try runtime.createDetachedDataStore(packagePath: [rootDataObjectType], factories: rootDataObjectFactory.sharedObjects)
            guard let root = try store.createChannel("root", type: SharedDirectory.type) as? SharedDirectory else {
                throw DatastoreError("DataObject root must be a SharedDirectory")
            }
            try store.bindChannel("root")
            let directory = try root.createSubDirectory("initial-objects-key")
            for (name, kind) in initialObjects.entries {
                let type = try kind.getFactory().attributes.member("type").asString()
                let channel = try store.createChannel(type: type)
                try directory.set(name, store.serializeHandle(channel, bindTo: "root"))
            }
            try runtime.setDetachedAlias(rootDataStoreId, datastoreId: store.id)
        }
        return (runtime, try RootDataObject(runtime: runtime))
    }
}
