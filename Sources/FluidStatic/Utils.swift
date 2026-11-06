import FluidJS
import FluidDatastore

/// Ports fluid-static/src/utils.ts `parseDataObjectsFromSharedObjects`. DataObjectKind is not
/// ported, so only the shared-object half of the TS tuple exists.
///
/// TS deduplicates kinds in a `Set` by identity: here a kind is a class, so identity is its
/// `ObjectIdentifier`.
public func parseDataObjectsFromSharedObjects(_ schema: ContainerSchema) throws -> [ChannelFactory] {
    var seen = Set<ObjectIdentifier>()
    var sharedObjects: [ChannelFactory] = []
    let kinds = schema.initialObjects.entries.map(\.value) + (schema.dynamicObjectTypes ?? [])
    for kind in kinds {
        let inserted = seen.insert(ObjectIdentifier(kind)).inserted
        if inserted {
            sharedObjects.append(kind.getFactory())
        }
    }
    if sharedObjects.isEmpty {
        throw DatastoreError("Container cannot be initialized without any DataTypes")
    }
    return sharedObjects
}
