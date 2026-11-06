import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS

public enum AttachState { case detached, attaching, attached }
public struct SharedObjectError: Error, CustomStringConvertible {
  public let description: String
  public init(_ description: String) { self.description = description }
}

/// Port of `packages/dds/shared-object-base/src/sharedObject.ts` SharedObjectCore.
open class SharedObjectCore<Metadata>: Channel {
  public typealias LocalOpMetadata = Metadata
  open class var type: JSString { "" }
  public let id: JSString
  public private(set) var attachState: AttachState = .detached
  public private(set) var bound = false
  public private(set) var connected = false
  public private(set) var closed: SharedObjectError?
  private var submit: ((JSONValue, Metadata) -> Void)?
  public struct Content {
    public let message: SequencedMessage
    public let metadata: Metadata?
    public init(message: SequencedMessage, metadata: Metadata?) {
      self.message = message
      self.metadata = metadata
    }
  }
  public typealias Listener = (SequencedMessage, Bool) throws -> Void
  private var listeners: [(Int, JSString, Listener)] = []
  private var nextListener = 0
  public required init(id: JSString) { self.id = id }
  open class func load(id: JSString, summary: SummaryTree) throws -> Self {
    let value = self.init(id: id)
    value.bound = true
    try value.loadCore(summary)
    return value
  }
  open func loadCore(_ summary: SummaryTree) throws {
    throw SharedObjectError("load not implemented")
  }
  public var isAttached: Bool { bound && attachState != .detached }
  public func bindToContext(_ bind: () -> Void = {}) {
    guard !bound else { return }
    bound = true
    bind()
  }
  public func attach() {
    guard attachState == .detached else { return }
    attachState = .attaching
    if bound { didAttach() }
    attachState = .attached
  }
  /// The hosting datastore runtime (`SharedObjectCore.runtime`), known once connected.
  public private(set) weak var runtime: (any IFluidDataStoreRuntime)?
  public func connect(
    _ runtime: any IFluidDataStoreRuntime, _ submit: @escaping (JSONValue, Metadata) -> Void
  ) {
    self.runtime = runtime
    if self.submit == nil { self.submit = submit }
    let wasAttached = isAttached
    bound = true
    attachState = .attached
    if !wasAttached { didAttach() }
    setConnectionState(true)
  }
  public func setConnectionState(_ value: Bool) {
    guard isAttached, connected != value else { return }
    connected = value
    if value { onConnect() } else { onDisconnect() }
  }
  open func didAttach() {}
  open func onConnect() {}
  open func onDisconnect() {}
  public func verifyOpen() throws { if let closed { throw closed } }
  public func submitLocalMessage(_ content: JSONValue, _ metadata: Metadata) throws {
    if let closed { throw closed }
    if isAttached { submit?(content, metadata) }
  }
  @discardableResult public func on(_ event: JSString, _ listener: @escaping Listener) -> Int {
    nextListener += 1
    listeners.append((nextListener, event, listener))
    return nextListener
  }
  public func off(_ token: Int) { listeners.removeAll { $0.0 == token } }
  private func emit(_ event: JSString, _ message: SequencedMessage, _ local: Bool) throws {
    do {
      for (_, name, listener) in listeners where name == event { try listener(message, local) }
    } catch {
      let failure = SharedObjectError("SharedObjectEventListenerException (\(event)): \(error)")
      closed = closed ?? failure
      throw failure
    }
  }
  public func process(_ message: SequencedMessage, local: Bool, localOpMetadata: Metadata?) throws {
    try processMessages([Content(message: message, metadata: localOpMetadata)], local: local)
  }
  public func processMessages(_ contents: [Content], local: Bool) throws {
    if let closed { throw closed }
    for content in contents { try emit("pre-op", content.message, local) }
    try processMessagesCore(contents, local: local)
    for content in contents { try emit("op", content.message, local) }
  }
  open func processMessagesCore(_ contents: [Content], local: Bool) throws {
    throw SharedObjectError("process not implemented")
  }
  open func reSubmitCore(_ content: JSONValue, localOpMetadata: Metadata) throws {
    try submitLocalMessage(content, localOpMetadata)
  }
  open func rollback(_ content: JSONValue, localOpMetadata: Metadata) throws {
    throw SharedObjectError("rollback not supported")
  }
  open func applyStashedOp(_ content: JSONValue) throws {
    throw SharedObjectError("stash not implemented")
  }
  open func summarize() -> SummaryTree { SummaryTree() }
}
/// Port of `packages/dds/shared-object-base/src/sharedObject.ts` SharedObject.
open class SharedObject<Metadata>: SharedObjectCore<Metadata> {}
public struct SummaryWithStats {
  public let summary: SummaryTree
  public let treeNodeCount = 1
  public let blobNodeCount = 1
  public let handleNodeCount = 0
  public let totalBlobSize: Int
  public let unreferencedBlobSize = 0
}
public func createSingleBlobSummary(_ name: JSString, _ content: JSString) -> SummaryWithStats {
  SummaryWithStats(
    summary: .singleBlob(name, content), totalBlobSize: content.description.utf8.count)
}
