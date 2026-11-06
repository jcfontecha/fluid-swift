import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS

/// Ports loader.ts ConnectionState, with its TS numeric values.
public enum ConnectionState: Int, Sendable {
    case disconnected = 0
    case catchingUp = 1
    case connected = 2
    case establishingConnection = 3
}

/// Ports loader.ts AttachState, with its TS string values.
public enum AttachState: String, Sendable {
    case detached = "Detached"
    case attaching = "Attaching"
    case attached = "Attached"
}

/// Ports loader.ts IContainerEvents.
public enum ContainerEvent {
    case connected(clientId: JSString)
    case disconnected
    case closed(error: (any Error)?)
    case saved
    case dirty
    case readonly(Bool)
    case metadataUpdate(JSObject<JSString>)
}

/// Ports loader.ts IContainer. A container owns one serial executor (ARCHITECTURE.md section 2),
/// so IContainer is an actor protocol: reads are synchronous on that executor, and a caller
/// outside it awaits. `audience`, `events` and the entry point are non-Sendable and are read only
/// from code isolated to the container.
public protocol IContainer: Actor {
    var connectionState: ConnectionState { get }
    var isDirty: Bool { get }
    var closed: Bool { get }
    var attachState: AttachState { get }
    var clientId: JSString? { get }
    var audience: any IAudience { get }
    var readOnlyInfo: ReadOnlyInfo { get }
    var containerMetadata: JSObject<JSString> { get }
    var events: ListenerList<ContainerEvent> { get }
    func connect() async throws
    func disconnect() async
    func close(_ error: (any Error)?) async
    /// loader.ts `getEntryPoint`: the runtime's entry point (FluidObject), for example
    /// fluid-static's root data object.
    func getEntryPoint() async throws -> AnyObject
}
