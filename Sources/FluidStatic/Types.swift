import FluidJS
import FluidDriverDefinitions

/// Ports fluid-static/src/types.ts `ContainerSchema`. `initialObjects` keeps JS property order
/// (`Object.entries` / `Object.values`): array-index keys ascending, then insertion order.
public struct ContainerSchema: Sendable {
    public let initialObjects: JSObject<any SharedObjectKind.Type>
    public let dynamicObjectTypes: [any SharedObjectKind.Type]?

    public init(
        initialObjects: KeyValuePairs<JSString, any SharedObjectKind.Type>,
        dynamicObjectTypes: [any SharedObjectKind.Type]? = nil
    ) {
        var objects = JSObject<any SharedObjectKind.Type>()
        for (key, kind) in initialObjects {
            objects[key] = kind
        }
        self.initialObjects = objects
        self.dynamicObjectTypes = dynamicObjectTypes
    }

    /// The same schema from initial objects built at run time, which `KeyValuePairs` cannot be.
    public init(
        initialObjects: JSObject<any SharedObjectKind.Type>,
        dynamicObjectTypes: [any SharedObjectKind.Type]? = nil
    ) {
        self.initialObjects = initialObjects
        self.dynamicObjectTypes = dynamicObjectTypes
    }
}

/// Ports types.ts `IConnection`.
public struct IConnection: Sendable {
    public let id: String
    public let mode: ConnectionMode

    public init(id: String, mode: ConnectionMode) {
        self.id = id
        self.mode = mode
    }
}

/// Ports types.ts `IMember`. `id` is left to each service's member type: ODSP fills it from an
/// unchecked payload field, so it can be absent there (see `OdspMember`).
public protocol IMember {
    var connections: [IConnection] { get set }
}

/// Ports types.ts `Myself`: a member plus the connection this client uses.
public struct Myself<Member: IMember> {
    public let member: Member
    public let currentConnection: String
}

/// Ports types.ts `IServiceAudienceEvents`.
public enum ServiceAudienceEvent<Member: IMember> {
    case membersChanged
    case memberAdded(clientId: String, member: Member)
    case memberRemoved(clientId: String, member: Member)
}
