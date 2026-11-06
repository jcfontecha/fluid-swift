import FluidJS
import FluidDriverDefinitions

/// A DDS as seen by its hosting runtime (`IChannel` + the `SharedObject` runtime hooks).
///
/// Everything here runs on the container's serial executor and is synchronous by design
/// (ARCHITECTURE.md §2).
public protocol Channel: AnyObject {
    /// Per-op metadata the channel attaches to a local submit and gets back when it is sequenced.
    associatedtype LocalOpMetadata

    static var type: JSString { get }

    init(id: JSString)

    /// Loads the channel from its summary (`SharedObject.loadCore`).
    static func load(id: JSString, summary: SummaryTree) throws -> Self

    /// Attaches the channel to its datastore runtime and delta connection; from now on local edits
    /// are submitted.
    func connect(
        _ runtime: any IFluidDataStoreRuntime,
        _ submit: @escaping (_ contents: JSONValue, _ localOpMetadata: LocalOpMetadata) -> Void
    )

    /// Processes one sequenced op (`SharedObject.processMessagesCore`). For local ops,
    /// `localOpMetadata` is what was passed to `submit`.
    func process(_ message: SequencedMessage, local: Bool, localOpMetadata: LocalOpMetadata?) throws

    func setConnectionState(_ connected: Bool)
    func reSubmitCore(_ content: JSONValue, localOpMetadata: LocalOpMetadata) throws
    func rollback(_ content: JSONValue, localOpMetadata: LocalOpMetadata) throws
    func applyStashedOp(_ content: JSONValue) throws

    /// `SharedObject.summarizeCore`.
    func summarize() -> SummaryTree
}

/// The part of `IFluidDataStoreRuntime` (datastore-definitions/src/dataStoreRuntime.ts) that
/// channels read.
public protocol IFluidDataStoreRuntime: AnyObject {
    /// Undefined while the container has never connected.
    var clientId: JSString? { get }

    /// `getQuorum()`: the connected members, in the order the quorum added them.
    func getQuorum() -> any IQuorumClients

    /// `deltaManager`.
    var deltaManager: any IDeltaManager { get }
}

/// The part of `IFluidParentContext` (runtime-definitions/src/dataStoreContext.ts) that a datastore
/// runtime reads from the context hosting it: the container runtime, or a datastore context.
public protocol IFluidParentContext: AnyObject {
    /// `deltaManager`.
    var deltaManager: any IDeltaManager { get }

    /// `getQuorum()`.
    func getQuorum() -> any IQuorumClients
}
