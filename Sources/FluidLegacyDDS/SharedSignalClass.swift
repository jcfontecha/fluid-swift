import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
// The public API exposes `FluidValue` and `FluidSerializer`, so clients need them too.
import FluidSharedObjectBase

/// The op a signal sends: `{"type":"signal","metadata":...}`, with `metadata` omitted when undefined.
/// Port of `packages/dds/legacy-dds/src/signal/interfaces.ts` ISignalOperation.
public struct ISignalOperation: Equatable, Sendable {
  public let metadata: FluidValue

  public init(metadata: FluidValue) {
    self.metadata = metadata
  }

  public func json(_ serializer: FluidSerializer) -> JSONValue {
    var object = JSObject<JSONValue>()
    object["type"] = .string("signal")
    if metadata != .undefined {
      object["metadata"] = serializer.encode(metadata)
    }
    return .object(object)
  }
}

/// An op-backed notification channel. It is not the runtime's ephemeral signal transport, and it holds no state.
/// Port of `packages/dds/legacy-dds/src/signal/sharedSignal.ts` SharedSignalClass; the TS factory
/// (`sharedSignalFactory.ts`) is carried by the `Channel` conformance: `type`, `init(id:)` and
/// `load(id:summary:)`.
public final class SharedSignalClass: SharedObject<Void> {
  public override class var type: JSString { "https://graph.microsoft.com/types/signal" }

  private static let snapshotFileName: JSString = "header"

  private let serializer = FluidSerializer()

  /// "notify" (metadata, isLocal). Metadata is undefined when the signal carried none.
  public var notifyEvent: ((FluidValue, Bool) -> Void)?

  /// `notify`: a detached signal returns with no event and no submission. An attached one emits "notify" locally
  /// first, then submits.
  public func notify(_ metadata: FluidValue? = nil) throws {
    guard isAttached else {
      return
    }
    let op = ISignalOperation(metadata: metadata ?? .undefined)
    notifyCore(op, isLocal: true)
    try submitLocalMessage(op.json(serializer), ())
  }

  /// `summarizeCore`: one `header` blob holding the JSON empty string.
  public override func summarize() -> SummaryTree {
    .singleBlob(Self.snapshotFileName, "\"\"")
  }

  /// `loadCore`: the loader ignores storage entirely.
  public override func loadCore(_ summary: SummaryTree) throws {}

  /// `processMessage`: only a remote op is dispatched. A local ack is ignored without validating its type.
  public override func processMessagesCore(_ contents: [Content], local: Bool) throws {
    for content in contents {
      try processMessage(content.message, local: local)
    }
  }

  private func processMessage(_ message: SequencedMessage, local: Bool) throws {
    guard message.type == MessageType.operation, !local else {
      return
    }
    let object = try message.contents.asObject()
    guard object["type"] == .string("signal") else {
      throw SharedObjectError("Unknown operation")
    }
    let metadata = try object["metadata"].map { try serializer.decode($0) } ?? .undefined
    notifyCore(ISignalOperation(metadata: metadata), isLocal: false)
  }

  private func notifyCore(_ op: ISignalOperation, isLocal: Bool) {
    notifyEvent?(op.metadata, isLocal)
  }

  /// `rollback`: nothing to roll back. The optimistic local "notify" is not undone.
  public override func rollback(_ content: JSONValue, localOpMetadata: Void) throws {}

  /// `applyStashedOp`: a signal is recognized and deliberately does nothing, with no event and no submission.
  public override func applyStashedOp(_ content: JSONValue) throws {
    guard try content.asObject()["type"] == .string("signal") else {
      throw SharedObjectError("unreachable: unknown signal operation")
    }
  }
}
