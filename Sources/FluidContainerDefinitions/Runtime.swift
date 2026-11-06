import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS

/// Ports runtime.ts IContainerContext: what the loader hands the runtime factory at load. The
/// runtime is synchronous (ARCHITECTURE.md section 2), so `baseSnapshot` is the snapshot with
/// every blob already read, not TS's lazily read ISnapshotTree.
public struct IContainerContext {
    public let clientId: JSString?
    public let clientDetails: IClientDetails
    public let baseSnapshot: SummaryTree?
    public let deltaManager: any IDeltaManager
    public let quorum: any IQuorumClients
    public let attachState: AttachState

    public init(
        clientId: JSString?, clientDetails: IClientDetails, baseSnapshot: SummaryTree?,
        deltaManager: any IDeltaManager, quorum: any IQuorumClients, attachState: AttachState
    ) {
        self.clientId = clientId
        self.clientDetails = clientDetails
        self.baseSnapshot = baseSnapshot
        self.deltaManager = deltaManager
        self.quorum = quorum
        self.attachState = attachState
    }
}

/// Ports runtime.ts IRuntimeFactory, which the loader instantiates in place of TS's code loader.
/// `Runtime` is the concrete runtime the loader drives: container-definitions sits below
/// container-runtime, as in TS, so the loader binds it (`any IRuntimeFactory<ContainerRuntime>`).
/// TS's IRuntime exposes `getEntryPoint()`; here the factory returns the entry point beside the
/// runtime it instantiated.
public protocol IRuntimeFactory<Runtime>: Sendable {
    associatedtype Runtime: AnyObject
    func instantiateRuntime(_ context: IContainerContext, existing: Bool) throws
        -> (runtime: Runtime, entryPoint: AnyObject)
}

/// Ports core-interfaces config.ts IConfigProviderBase: raw feature-gate values by name, read by
/// the loader through telemetry-utils' `getBoolean`.
public protocol IConfigProviderBase: Sendable {
    func getRawConfig(_ name: String) -> JSONValue?
}
