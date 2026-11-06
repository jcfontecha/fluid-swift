import FluidContainerDefinitions
import FluidDatastore
import FluidDatastoreDefinitions
import FluidJS

/// Ports fluidContainer.ts `IFluidContainerEvents`.
public enum FluidContainerEvent {
    case connected
    case disconnected
    case saved
    case dirty
    case disposed(error: (any Error)?)
}

/// Ports fluid-static/src/fluidContainer.ts `FluidContainer`: the app-facing container over the
/// loader's container and the root data object. It is not Sendable: it belongs to the actor that
/// owns the loader container (ARCHITECTURE.md section 2), so its reads, DDS edits and events are
/// synchronous on that owner.
///
/// `create` and `uploadBlob` are not ported: the root data object cannot create datastores or
/// upload attachment blobs yet.
public final class FluidContainer {
    private let container: any IContainer
    private let rootDataObject: RootDataObject
    private var containerListener: Int?
    private let attachHandler: (@isolated(any) () async throws -> String)?
    public let events = ListenerList<FluidContainerEvent>()

    /// fluidContainer.ts constructor: forwards the container's `connected`, `closed` (as
    /// `disposed`), `disconnected`, `saved` and `dirty` events. The listener captures only the
    /// event list, so the container does not retain this object.
    init(container: any IContainer, rootDataObject: RootDataObject, attach: (@isolated(any) () async throws -> String)? = nil) {
        attachHandler = attach
        self.container = container
        self.rootDataObject = rootDataObject
        containerListener = container.events.on { [events] event in
            switch event {
            case .connected:
                events.emit(.connected)
            case .closed(let error):
                events.emit(.disposed(error: error))
            case .disconnected:
                events.emit(.disconnected)
            case .saved:
                events.emit(.saved)
            case .dirty:
                events.emit(.dirty)
            default:
                break
            }
        }
    }

    public var isDirty: Bool { container.isDirty }

    public var attachState: AttachState { container.attachState }

    public var disposed: Bool { container.closed }

    public var connectionState: ConnectionState { container.connectionState }

    /// The schema's initial objects, in the order the root data object stores them.
    public var initialObjects: JSObject<any Channel> { rootDataObject.initialObjects }

    /// fluidContainer.ts `attach`: a loaded container has no attach method; only a service
    /// client's detached container provides one.
    public nonisolated(nonsending) func attach() async throws -> String {
        if container.attachState != .detached {
            throw DatastoreError("Cannot attach container. Container is not in detached state.")
        }
        guard let attachHandler else {
            throw DatastoreError("Cannot attach container. Attach method not provided.")
        }
        return try await attachHandler()
    }

    public func connect() {
        container.connect()
    }

    public func disconnect() {
        container.disconnect()
    }

    /// fluidContainer.ts `dispose`: closes the container, which emits `disposed`, then stops
    /// forwarding its events.
    public func dispose() {
        container.close(nil)
        if let containerListener {
            container.events.off(containerListener)
            self.containerListener = nil
        }
    }
}

/// Ports fluidContainer.ts `createFluidContainer`. The loader's entry point for a fluid-static
/// container is the root data object (`DOProviderContainerRuntimeFactory`). Runs on the caller's
/// isolation, which owns the container.
public nonisolated(nonsending) func createFluidContainer(container: any IContainer, attach: (@isolated(any) () async throws -> String)? = nil) async throws -> FluidContainer {
    let entryPoint = try await container.getEntryPoint()
    // fluidContainer.ts assert 0xb9e.
    guard let rootDataObject = entryPoint as? RootDataObject else {
        throw DatastoreError("0xb9e: entryPoint must be of type IStaticEntryPoint")
    }
    return FluidContainer(container: container, rootDataObject: rootDataObject, attach: attach)
}
