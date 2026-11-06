import FluidJS

/// The part of `IQuorumClients` (driver-definitions/src/protocol.ts) that channels read.
///
/// TS declares the members as `Map<string, ISequencedClient>`; a member's value is kept as
/// `JSONValue` because the mock quorums store the partial `{}` object, which is not a full
/// `ISequencedClient`.
public protocol IQuorumClients: AnyObject {
    /// `getMembers()`: a snapshot in JS `Map` insertion order.
    func getMembers() -> JSMap<JSString, JSONValue>

    /// `getMember(clientId)`.
    func getMember(_ clientId: JSString) -> JSONValue?

    /// `on("addMember", listener)`. Listeners run synchronously in registration order. Returns a
    /// token for `off`.
    @discardableResult
    func onAddMember(_ listener: @escaping (_ clientId: JSString, _ client: JSONValue) -> Void) -> Int

    /// `on("removeMember", listener)`. Returns a token for `off`.
    @discardableResult
    func onRemoveMember(_ listener: @escaping (_ clientId: JSString) -> Void) -> Int

    /// `off(event, listener)`, for a token returned by `onAddMember` or `onRemoveMember`.
    func off(_ token: Int)
}

/// `ReadOnlyInfo` (container-definitions/src/deltas.ts), without `forced` and `storageOnly`,
/// which channels do not read.
public struct ReadOnlyInfo: Equatable, Sendable {
    public var readonly: Bool

    /// Set when the client is read-only because it lacks write permission.
    public var permissions: Bool?

    public init(readonly: Bool, permissions: Bool? = nil) {
        self.readonly = readonly
        self.permissions = permissions
    }
}

/// The part of `IDeltaManager` (container-definitions/src/deltas.ts) that channels read through
/// `IFluidDataStoreRuntime.deltaManager`.
public protocol IDeltaManager: AnyObject {
    /// The sequence number of the last message the container processed.
    var lastSequenceNumber: Int { get }

    /// Minimum sequence number of the last processed message (or the loaded snapshot).
    var minimumSequenceNumber: Int { get }

    /// Whether the client can write: connected in write mode.
    var active: Bool { get }

    var readOnlyInfo: ReadOnlyInfo { get }
}
