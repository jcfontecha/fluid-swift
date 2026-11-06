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

    /// Attaches the channel to a delta connection; from now on local edits are submitted.
    func connect(_ submit: @escaping (_ contents: JSONValue, _ localOpMetadata: LocalOpMetadata) -> Void)

    /// Processes one sequenced op (`SharedObject.processMessagesCore`). For local ops,
    /// `localOpMetadata` is what was passed to `submit`.
    func process(_ message: SequencedMessage, local: Bool, localOpMetadata: LocalOpMetadata?) throws

    /// `SharedObject.summarizeCore`.
    func summarize() -> SummaryTree
}
