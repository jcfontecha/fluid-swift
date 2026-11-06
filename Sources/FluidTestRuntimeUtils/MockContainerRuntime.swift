import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS

public enum FlushMode { case immediate, turnBased }

public final class MockContainerRuntime<C: Channel>: IFluidDataStoreRuntime {
  /// The mock always has a connection identity; TS `MockFluidDataStoreRuntime.clientId`.
  public var clientId: JSString? { currentClientId }
  private var currentClientId: JSString
  public let channel: C
  public private(set) var lastSequenceNumber: Int
  public private(set) var connected = true
  public let flushMode: FlushMode
  private var clientSequenceNumber = 0
  private struct Pending {
    let csn: Int
    let contents: JSONValue
    let metadata: C.LocalOpMetadata
  }
  private var pendingMessages: [Pending] = []
  private var outbox: [(JSONValue, C.LocalOpMetadata, Int)] = []
  private var outbound: [UnsequencedMessage] = []
  private var remote: [SequencedMessage] = []

  public init(
    clientId: JSString, channel: C, lastSequenceNumber: Int, flushMode: FlushMode = .immediate
  ) {
    currentClientId = clientId
    self.channel = channel
    self.lastSequenceNumber = lastSequenceNumber
    self.flushMode = flushMode
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
    lastSequenceNumber = message.sequenceNumber
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
    outbound.append(
      UnsequencedMessage(
        clientId: currentClientId, clientSequenceNumber: clientSequenceNumber,
        referenceSequenceNumber: reference, contents: contents))
    pendingMessages.append(
      Pending(csn: clientSequenceNumber, contents: contents, metadata: metadata))
  }
}

/// Membership listeners fire synchronously after mutation, in registration order.
public final class MockQuorumClients {
  public private(set) var members = JSObject<JSONValue>()
  public var memberAdded: ((JSString, JSONValue) -> Void)?
  public var memberRemoved: ((JSString) -> Void)?
  public init() {}
  public func addMember(_ id: JSString, _ member: JSONValue) {
    members[id] = member
    memberAdded?(id, member)
  }
  public func removeMember(_ id: JSString) {
    members[id] = nil
    memberRemoved?(id)
  }
  public func getMember(_ id: JSString) -> JSONValue? { members[id] }
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
