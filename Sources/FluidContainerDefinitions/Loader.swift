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
    case attaching
    case attached
    case connected(clientId: JSString)
    case disconnected
    case closed(error: (any Error)?)
    case disposed(error: (any Error)?)
    case saved
    case dirty
    case readonly(Bool)
    case metadataUpdate(JSObject<JSString>)
}

/// Ports loader.ts IContainer. A container and everything it owns belong to one owner actor
/// (ARCHITECTURE.md section 2) and are plain, synchronous, non-Sendable code on it: reads,
/// listeners and the lifecycle calls are synchronous, as in TS.
public protocol IContainer: AnyObject {
    var connectionState: ConnectionState { get }
    var isDirty: Bool { get }
    var closed: Bool { get }
    var attachState: AttachState { get }
    var clientId: JSString? { get }
    var audience: any IAudience { get }
    var readOnlyInfo: ReadOnlyInfo { get }
    var containerMetadata: JSObject<JSString> { get }
    var events: ListenerList<ContainerEvent> { get }
    /// loader.ts `connect(): void`: starts connecting; `connected` reports the result.
    func connect()
    /// loader.ts `disconnect(): void`.
    func disconnect()
    /// loader.ts `close(error?): void`: disconnects for good and emits `closed`.
    func close(_ error: (any Error)?)
    /// loader.ts `dispose(error?): void`: releases the container's services and emits `disposed`.
    func dispose(_ error: (any Error)?)
    /// loader.ts `getEntryPoint`: the runtime's entry point (FluidObject), for example
    /// fluid-static's root data object.
    nonisolated(nonsending) func getEntryPoint() async throws -> AnyObject
}
