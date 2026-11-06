import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS

/// Port of `MockContainerRuntimeFactory` (test-runtime-utils/src/mocks.ts) for one channel type:
/// a shared quorum and a sequencer that delivers each message to every runtime in creation order.
/// The minimum sequence number is always 0, which no channel under test reads.
public final class MockContainerRuntimeFactory<C: Channel> {
  public let quorum = MockQuorumClients()
  public private(set) var runtimes: [MockContainerRuntime<C>] = []
  public private(set) var sequenceNumber = 0
  private var messages: [UnsequencedMessage] = []

  public init() {}

  /// `createContainerRuntime`.
  public func createContainerRuntime(
    clientId: JSString, channel: C, flushMode: FlushMode = .immediate
  ) -> MockContainerRuntime<C> {
    let runtime = MockContainerRuntime(
      clientId: clientId, channel: channel, lastSequenceNumber: sequenceNumber,
      flushMode: flushMode, quorum: quorum)
    runtime.onSend = { [unowned self] message in messages.append(message) }
    runtime.onDropOutstanding = { [unowned self] clientId in clearOutstandingClientMessages(clientId) }
    // Messages the channel sent while attaching (connect) predate the hooks.
    messages.append(contentsOf: runtime.takeOutbound())
    runtimes.append(runtime)
    return runtime
  }

  /// `clearOutstandingClientMessages` (mocksForReconnection.ts): drops every unsequenced message from `clientId`.
  public func clearOutstandingClientMessages(_ clientId: JSString) {
    messages.removeAll { $0.clientId == clientId }
  }

  /// `outstandingMessageCount`.
  public var outstandingMessageCount: Int { messages.count }

  /// `processOneMessage`.
  public func processOneMessage() throws {
    guard !messages.isEmpty else {
      throw JSONDecodingError("There are no more messages to process")
    }
    let message = messages.removeFirst()
    sequenceNumber += 1
    var json = JSObject<JSONValue>()
    json["clientId"] = .string(message.clientId)
    json["clientSequenceNumber"] = .number(Double(message.clientSequenceNumber))
    json["referenceSequenceNumber"] = .number(Double(message.referenceSequenceNumber))
    json["sequenceNumber"] = .number(Double(sequenceNumber))
    json["minimumSequenceNumber"] = .number(0)
    json["type"] = .string(MessageType.operation)
    json["contents"] = message.contents
    let sequenced = try SequencedMessage(json: .object(json))
    for runtime in runtimes {
      try runtime.process(sequenced)
    }
  }

  /// `processSomeMessages`.
  public func processSomeMessages(_ count: Int) throws {
    for _ in 0..<count {
      try processOneMessage()
    }
  }

  /// `processAllMessages`: also processes messages submitted while processing.
  public func processAllMessages() throws {
    while !messages.isEmpty {
      try processOneMessage()
    }
  }
}
