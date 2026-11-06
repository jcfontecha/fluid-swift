internal import FluidDatastoreDefinitions
internal import FluidJS
internal import FluidStatic

/// The objects a container starts with, as typed properties. The init spells each object's key:
///
/// ```swift
/// struct Checklist: ContainerSchema {
///     let title: SharedString
///     let items: SharedMap<Item>
///
///     init(_ objects: InitialObjects) {
///         title = objects["title"]
///         items = objects["items"]
///     }
/// }
/// ```
///
/// Loading runs the init twice: once over fresh objects to learn each key and kind, in the order
/// the init reads them, and once over the loaded container's objects.
public protocol ContainerSchema {
    init(_ objects: InitialObjects)
}

/// A distributed data structure a `ContainerSchema` can hold.
public protocol SharedObject: AnyObject {
    /// How the object is made over the port's channel. Only the Fluid module can build one.
    static var kind: SharedObjectKind<Self> { get }
}

/// Builds one native object type over its port channel type.
public struct SharedObjectKind<Object: SharedObject> {
    /// The port's channel class, which the channel registry is built from.
    let channelType: any FluidStatic.SharedObjectKind.Type
    /// A new object over a new, unattached channel.
    let make: (JSString) -> Object
    /// The object over a loaded channel, or nil when the channel is a different kind.
    let adopt: (any Channel) -> Object?
}

/// The objects a `ContainerSchema`'s init reads by key.
public final class InitialObjects {
    private enum Source {
        /// The first pass: every read makes a fresh object and records its key and kind.
        case recording
        /// The second pass: every read resolves the loaded container's object.
        case loaded(JSObject<any Channel>)
    }

    private let source: Source
    private(set) var channelTypes = JSObject<any FluidStatic.SharedObjectKind.Type>()
    /// The first key whose loaded object is missing or of a different kind.
    private(set) var mismatchedKey: String?

    private init(source: Source) {
        self.source = source
    }

    /// The port schema `Schema` declares.
    static func schema<Schema: ContainerSchema>(of schema: Schema.Type) -> FluidStatic.ContainerSchema {
        let objects = InitialObjects(source: .recording)
        _ = Schema(objects)
        return FluidStatic.ContainerSchema(initialObjects: objects.channelTypes)
    }

    /// `Schema` over a loaded container's initial objects.
    static func resolve<Schema: ContainerSchema>(
        _ schema: Schema.Type, from channels: JSObject<any Channel>
    ) throws(FluidError) -> Schema {
        let objects = InitialObjects(source: .loaded(channels))
        let resolved = Schema(objects)
        if let key = objects.mismatchedKey {
            throw .schemaMismatch(key: key)
        }
        return resolved
    }

    public subscript<Object: SharedObject>(key: String) -> Object {
        let kind = Object.kind
        let id = JSString(key)
        switch source {
        case .recording:
            precondition(channelTypes[id] == nil, "The schema reads \"\(key)\" twice.")
            channelTypes[id] = kind.channelType
            return kind.make(id)
        case .loaded(let channels):
            if let channel = channels[id], let object = kind.adopt(channel) {
                return object
            }
            mismatchedKey = mismatchedKey ?? key
            // Never seen: `resolve` throws once the init returns.
            return kind.make(id)
        }
    }
}

/// Why a container could not be loaded, beyond the network and token errors the service reports.
public enum FluidError: Error, Equatable {
    /// The loaded container has no object under `key`, or one of a different kind than the schema
    /// declares.
    case schemaMismatch(key: String)
}
