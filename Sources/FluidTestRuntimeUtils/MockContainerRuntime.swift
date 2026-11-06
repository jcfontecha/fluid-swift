import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS

public enum FlushMode { case immediate, turnBased }

public final class MockContainerRuntime<C: Channel>: IFluidDataStoreRuntime {
  /// The mock always has a connection identity; TS `MockFluidDataStoreRuntime.clientId`.
  public var clientId: JSString? { currentClientId }
  private var currentClientId: JSString
  public let channel: C
  public var lastSequenceNumber: Int { mockDeltaManager.lastSequenceNumber }
  public private(set) var connected = true
  public let flushMode: FlushMode
  /// `MockContainerRuntimeFactory.quorum`: shared by every runtime created with it.
  public let quorum: MockQuorumClients
  /// `MockFluidDataStoreRuntime.deltaManagerInternal`.
  public let mockDeltaManager = MockDeltaManager()
  public var deltaManager: any IDeltaManager { mockDeltaManager }
  public func getQuorum() -> any IQuorumClients { quorum }
  private var clientSequenceNumber = 0
  private struct Pending {
    let csn: Int
    let contents: JSONValue
    let metadata: C.LocalOpMetadata
  }
  private var pendingMessages: [Pending] = []
  private var outbox: [(JSONValue, C.LocalOpMetadata, Int)] = []
  private var outbound: [UnsequencedMessage] = []
  /// Called for every message the runtime sends, in submission order. A
  /// `MockContainerRuntimeFactory` uses it to build its shared queue.
  public var onSend: ((UnsequencedMessage) -> Void)?
  /// Called when a disconnect drops the runtime's unsequenced messages
  /// (`MockContainerRuntimeFactory.clearOutstandingClientMessages`).
  public var onDropOutstanding: (() -> Void)?
  private var remote: [SequencedMessage] = []

  public init(
    clientId: JSString, channel: C, lastSequenceNumber: Int, flushMode: FlushMode = .immediate,
    quorum: MockQuorumClients = MockQuorumClients()
  ) {
    currentClientId = clientId
    self.channel = channel
    self.quorum = quorum
    mockDeltaManager.lastSequenceNumber = lastSequenceNumber
    self.flushMode = flushMode
    // MockContainerRuntime's constructor joins the quorum before any channel is created.
    quorum.addMember(clientId, .object(JSObject()))
    channel.connect(self) { [unowned self] contents, metadata in submit(contents, metadata) }
  }
  public func takeOutbound() -> [UnsequencedMessage] {
    defer { outbound.removeAll() }
    return outbound
  }
  public func disconnect() {
    guard connected else { return }
    connected = false
    outbound.removeAll()
    onDropOutstanding?()
    quorum.removeMember(currentClientId)
    for (contents, metadata, _) in outbox {
      clientSequenceNumber += 1
      pendingMessages.append(
        Pending(csn: clientSequenceNumber, contents: contents, metadata: metadata))
    }
    outbox.removeAll()
    channel.setConnectionState(false)
  }
  public func reconnect(clientId: JSString) throws {
    guard !connected else { return }
    connected = true
    let buffered = remote
    remote.removeAll()
    for message in buffered { try process(message) }
    currentClientId = clientId
    clientSequenceNumber = 0
    quorum.addMember(clientId, .object(JSObject()))
    let pending = pendingMessages
    pendingMessages.removeAll()
    for entry in pending {
      try channel.reSubmitCore(entry.contents, localOpMetadata: entry.metadata)
    }
    channel.setConnectionState(true)
  }
  public func process(_ message: SequencedMessage) throws {
    guard connected else {
      remote.append(message)
      return
    }
    mockDeltaManager.lastSequenceNumber = message.sequenceNumber
    let local = message.clientId == currentClientId
    var metadata: C.LocalOpMetadata?
    if local {
      guard let first = pendingMessages.first, first.csn == message.clientSequenceNumber else {
        throw JSONDecodingError("Unexpected local acknowledgement")
      }
      pendingMessages.removeFirst()
      metadata = first.metadata
    }
    try channel.process(message, local: local, localOpMetadata: metadata)
  }
  public func flush() { flushSomeMessages(outbox.count) }
  public func flushSomeMessages(_ count: Int) {
    guard connected, flushMode == .turnBased else { return }
    let messages = Array(outbox.prefix(max(0, count)))
    outbox.removeFirst(messages.count)
    for (contents, metadata, reference) in messages {
      send(contents, metadata, reference: reference)
    }
  }
  public func rollback() throws {
    let messages = outbox.reversed()
    outbox.removeAll()
    for (contents, metadata, _) in messages {
      try channel.rollback(contents, localOpMetadata: metadata)
    }
  }
  private func submit(_ contents: JSONValue, _ metadata: C.LocalOpMetadata) {
    if !connected {
      pendingMessages.append(Pending(csn: -1, contents: contents, metadata: metadata))
    } else {
      clientSequenceNumber += 1
      if flushMode == .turnBased {
        outbox.append((contents, metadata, lastSequenceNumber))
      } else {
        send(contents, metadata, reference: lastSequenceNumber)
      }
    }
  }
  private func send(_ contents: JSONValue, _ metadata: C.LocalOpMetadata, reference: Int) {
    let message = UnsequencedMessage(
      clientId: currentClientId, clientSequenceNumber: clientSequenceNumber,
      referenceSequenceNumber: reference, contents: contents)
    outbound.append(message)
    onSend?(message)
    pendingMessages.append(
      Pending(csn: clientSequenceNumber, contents: contents, metadata: metadata))
  }
}

/// Port of `MockDeltaManager` (test-runtime-utils/src/mockDeltas.ts), the members channels read.
public final class MockDeltaManager: IDeltaManager {
  public var lastSequenceNumber = 0
  public var readOnlyInfo = ReadOnlyInfo(readonly: false)
  public init() {}
}

/// Port of `MockQuorumClients` (test-runtime-utils/src/mocks.ts). Listeners fire synchronously
/// after the mutation, in registration order.
public final class MockQuorumClients: IQuorumClients {
  private var members = JSMap<JSString, JSONValue>()
  private var addListeners: [(token: Int, listener: (JSString, JSONValue) -> Void)] = []
  private var removeListeners: [(token: Int, listener: (JSString) -> Void)] = []
  private var nextToken = 0
  public init() {}
  /// `addMember` always emits, even for a client that is already a member (it keeps its position).
  public func addMember(_ id: JSString, _ member: JSONValue) {
    members.set(id, member)
    for entry in addListeners { entry.listener(id, member) }
  }
  /// `removeMember` emits only if the client was a member.
  public func removeMember(_ id: JSString) {
    guard members.delete(id) else { return }
    for entry in removeListeners { entry.listener(id) }
  }
  public func getMembers() -> JSMap<JSString, JSONValue> { members }
  public func getMember(_ clientId: JSString) -> JSONValue? { members.get(clientId) }
  @discardableResult
  public func onAddMember(_ listener: @escaping (JSString, JSONValue) -> Void) -> Int {
    nextToken += 1
    addListeners.append((nextToken, listener))
    return nextToken
  }
  @discardableResult
  public func onRemoveMember(_ listener: @escaping (JSString) -> Void) -> Int {
    nextToken += 1
    removeListeners.append((nextToken, listener))
    return nextToken
  }
  public func off(_ token: Int) {
    addListeners.removeAll { $0.token == token }
    removeListeners.removeAll { $0.token == token }
  }
}
public final class MockAudience {
  public private(set) var members = JSObject<JSONValue>()
  public private(set) var currentClientId: JSString?
  public var memberAdded: ((JSString, JSONValue) -> Void)?
  public var memberRemoved: ((JSString, JSONValue) -> Void)?
  public init() {}
  public func setCurrentClientId(_ id: JSString) { currentClientId = id }
  public func addMember(_ id: JSString, _ member: JSONValue) {
    members[id] = member
    memberAdded?(id, member)
  }
  @discardableResult public func removeMember(_ id: JSString) -> Bool {
    guard let old = members[id] else { return false }
    members[id] = nil
    memberRemoved?(id, old)
    return true
  }
}
