import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidPactMap
import FluidSharedObjectBase
import FluidTestRuntimeUtils
import Testing

/// One connected PactMap with its runtime, as pactMap.spec.ts `createConnectedPactMap`.
private struct Client {
  let map: PactMapClass
  let runtime: MockContainerRuntime<PactMapClass>
}

private func connected(
  _ id: JSString, _ factory: MockContainerRuntimeFactory<PactMapClass>
) -> Client {
  let map = PactMapClass(id: "pactMap")
  let runtime = factory.createContainerRuntime(clientId: id, channel: map)
  return Client(map: map, runtime: runtime)
}

/// What a client observed in a `pending` or `accepted` event.
private struct Observation: Equatable {
  let event: JSString
  let key: JSString
  let pending: JSONValue?
  let accepted: JSONValue?
}

private func observe(_ map: PactMapClass, into log: Log) {
  map.pending = { [unowned map] key in
    log.entries.append(
      Observation(
        event: "pending", key: key, pending: map.getPending(key), accepted: map.get(key)))
  }
  map.accepted = { [unowned map] key in
    log.entries.append(
      Observation(
        event: "accepted", key: key, pending: map.getPending(key), accepted: map.get(key)))
  }
}

private final class Log {
  var entries: [Observation] = []
}

private func text(_ value: String) -> JSONValue { .string(JSString(value)) }

// MARK: Connected state, single client

/// pactMap.spec.ts "Connected state, single client" › "Can set a value and read it from all clients".
@Test func singleClientSetIsPendingThenAccepted() throws {
  let factory = MockContainerRuntimeFactory<PactMapClass>()
  let client = connected("A", factory)
  let log = Log()
  observe(client.map, into: log)
  try client.map.set("key", text("value"))
  try factory.processAllMessages()
  #expect(
    log.entries == [
      Observation(event: "pending", key: "key", pending: text("value"), accepted: nil),
      Observation(event: "accepted", key: "key", pending: nil, accepted: text("value")),
    ])
  #expect(client.map.get("key") == text("value"))
}

// MARK: Connected state, multiple clients

/// "Connected state, multiple clients" › "Can set a value and read it from all clients".
@Test func twoClientsBothSeePendingThenAccepted() throws {
  let factory = MockContainerRuntimeFactory<PactMapClass>()
  let first = connected("A", factory)
  let second = connected("B", factory)
  let log1 = Log()
  let log2 = Log()
  observe(first.map, into: log1)
  observe(second.map, into: log2)
  try first.map.set("key", text("value"))
  try factory.processAllMessages()
  let expected = [
    Observation(event: "pending", key: "key", pending: text("value"), accepted: nil),
    Observation(event: "accepted", key: "key", pending: nil, accepted: text("value")),
  ]
  #expect(log1.entries == expected)
  #expect(log2.entries == expected)
}

/// "Resolves simultaneous sets and deletes with first-write-wins".
@Test func simultaneousSetsAndDeletesFirstWriteWins() throws {
  let factory = MockContainerRuntimeFactory<PactMapClass>()
  let first = connected("A", factory)
  let second = connected("B", factory)
  try first.map.set("key", text("expected"))
  try second.map.set("key", text("unexpected1"))
  try factory.processAllMessages()
  #expect(first.map.get("key") == text("expected"))
  #expect(second.map.get("key") == text("expected"))

  try second.map.delete("key")
  try first.map.set("key", text("unexpected2"))
  try factory.processAllMessages()
  #expect(first.map.get("key") == nil)
  #expect(second.map.get("key") == nil)
}

/// A sequenced message from `clientId`, delivered straight to a channel.
private func message(
  _ clientId: JSString, _ sequenceNumber: Int, _ contents: JSONValue
) throws -> SequencedMessage {
  var json = JSObject<JSONValue>()
  json["clientId"] = .string(clientId)
  json["clientSequenceNumber"] = .number(1)
  json["referenceSequenceNumber"] = .number(0)
  json["sequenceNumber"] = .number(Double(sequenceNumber))
  json["minimumSequenceNumber"] = .number(0)
  json["type"] = .string("op")
  json["contents"] = contents
  return try SequencedMessage(json: .object(json))
}

private func setOp(_ key: String, _ value: String, refSeq: Int) throws -> JSONValue {
  try JSON.parse(#"{"type":"set","key":"\#(key)","value":"\#(value)","refSeq":\#(refSeq)}"#)
}

/// spec "Behavior" 2: a sequenced proposal is valid only if its refSeq is at least the accepted
/// sequence number. A stale one is ignored with no event, even after the earlier proposal settled.
@Test func staleSequencedProposalIsIgnored() throws {
  // The only quorum member is the remote client R, who sends everything.
  let quorum = MockQuorumClients()
  let map = PactMapClass(id: "p")
  let runtime = MockContainerRuntime(
    clientId: "A", channel: map, lastSequenceNumber: 0, quorum: quorum)
  quorum.removeMember("A")
  quorum.addMember("R", .object(JSObject()))
  let log = Log()
  observe(map, into: log)
  try runtime.process(message("R", 1, setOp("key", "one", refSeq: 0)))
  try runtime.process(message("R", 3, JSON.parse(#"{"type":"accept","key":"key"}"#)))
  #expect(map.getWithDetails("key")?.acceptedSequenceNumber == 3)
  let events = log.entries.count

  try runtime.process(message("R", 4, setOp("key", "stale", refSeq: 2)))
  #expect(log.entries.count == events)
  #expect(!map.isPending("key"))
  #expect(map.get("key") == text("one"))

  try runtime.process(message("R", 5, setOp("key", "fresh", refSeq: 3)))
  #expect(map.getPending("key") == text("fresh"))
  #expect(map.get("key") == text("one"))
}

/// "Behavior" 1: set while a proposal is sequenced and pending submits nothing.
@Test func setWhilePendingSubmitsNothing() throws {
  let factory = MockContainerRuntimeFactory<PactMapClass>()
  let first = connected("A", factory)
  _ = connected("B", factory)
  try first.map.set("key", text("one"))
  try factory.processOneMessage()
  #expect(first.map.isPending("key"))
  try first.map.set("key", text("two"))
  #expect(factory.outstandingMessageCount == 2)  // only the two accepts
  try factory.processAllMessages()
  #expect(first.map.get("key") == text("one"))
}

/// "Behavior" 1: delete is a no-op for an absent key, a pending key and an accepted undefined.
@Test func deleteNoOps() throws {
  let factory = MockContainerRuntimeFactory<PactMapClass>()
  let first = connected("A", factory)
  try first.map.delete("missing")
  #expect(factory.outstandingMessageCount == 0)
  try first.map.set("key", text("one"))
  try factory.processOneMessage()
  try first.map.delete("key")
  #expect(factory.outstandingMessageCount == 1)  // pending: only the accept
  try factory.processAllMessages()
  try first.map.delete("key")
  try factory.processAllMessages()
  #expect(first.map.get("key") == nil)
  #expect(first.map.getWithDetails("key") != nil)
  try first.map.delete("key")
  #expect(factory.outstandingMessageCount == 0)
}

/// "Behavior" 2 and 4: wire format of set ops, and an accepted sequence number equal to the final
/// signoff's sequence number, not the proposal's.
@Test func opsAndAcceptedSequenceNumber() throws {
  let factory = MockContainerRuntimeFactory<PactMapClass>()
  let first = connected("A", factory)
  let second = connected("B", factory)
  try first.map.set("a", .number(7))
  let set = first.runtime.takeOutbound()
  #expect(JSON.stringify(set[0].contents) == #"{"type":"set","key":"a","value":7,"refSeq":0}"#)
  try second.map.set("b", nil)
  #expect(
    JSON.stringify(second.runtime.takeOutbound()[0].contents)
      == #"{"type":"set","key":"b","refSeq":0}"#)
  try factory.processAllMessages()
  // set a (1), set b (2), then accepts for "a" from A (3) and B (4): B's is the final signoff.
  let details = first.map.getWithDetails("a")
  #expect(details?.value == .number(7))
  #expect(details?.acceptedSequenceNumber == 4)
  #expect(first.map.getWithDetails("b")?.acceptedSequenceNumber == 6)
}

// MARK: Summaries

/// spec "Wire and persisted formats": the single `header` blob and load round trip.
@Test func summaryBlobsAndLoad() throws {
  let factory = MockContainerRuntimeFactory<PactMapClass>()
  let first = connected("c1", factory)
  _ = connected("c2", factory)
  #expect(
    try summaryText(first.map) == "[]")
  try first.map.set("a", .number(6))
  try factory.processOneMessage()
  #expect(
    try summaryText(first.map)
      == #"[["a",{"pending":{"value":6,"expectedSignoffs":["c1","c2"]}}]]"#)
  try factory.processAllMessages()
  #expect(
    try summaryText(first.map)
      == #"[["a",{"accepted":{"value":6,"sequenceNumber":3}}]]"#)
  try first.map.set("a", .number(7))
  try factory.processOneMessage()
  #expect(
    try summaryText(first.map)
      == #"[["a",{"accepted":{"value":6,"sequenceNumber":3},"pending":{"value":7,"expectedSignoffs":["c1","c2"]}}]]"#
  )
  try factory.processAllMessages()
  try first.map.delete("a")
  try factory.processAllMessages()
  #expect(
    try summaryText(first.map)
      == #"[["a",{"accepted":{"sequenceNumber":9}}]]"#)

  let loaded = try PactMapClass.load(id: "loaded", summary: first.map.summarize())
  #expect(loaded.get("a") == nil)
  #expect(loaded.getWithDetails("a")?.acceptedSequenceNumber == 9)
  #expect(try summaryText(loaded) == #"[["a",{"accepted":{"sequenceNumber":9}}]]"#)
}

/// Load copies pending pacts verbatim: no quorum filtering, no automatic acceptance, no events.
@Test func loadKeepsPendingWithoutEvents() throws {
  let summary = SummaryTree.singleBlob(
    "header", #"[["__proto__",{"pending":{"value":1,"expectedSignoffs":["gone"]}}]]"#)
  let loaded = try PactMapClass.load(id: "p", summary: summary)
  #expect(loaded.isPending("__proto__"))
  #expect(loaded.getPending("__proto__") == .number(1))
  #expect(try summaryText(loaded) == #"[["__proto__",{"pending":{"value":1,"expectedSignoffs":["gone"]}}]]"#)
}

private func summaryText(_ map: PactMapClass) throws -> String {
  guard case .tree(let tree) = map.summarize(), let header = tree.tree["header"] else {
    throw JSONDecodingError("no header")
  }
  return try header.json.member("content").asString().description
}

// MARK: Quorum

/// "Behavior" 5: a departing member's signoff is dropped and, when it was the last one, the value is
/// accepted at the sequence number the container last processed. Members who join after the
/// proposal was sequenced are not added to its signoffs.
@Test func memberRemovalAcceptsAtLastSequenceNumber() throws {
  let factory = MockContainerRuntimeFactory<PactMapClass>()
  let first = connected("A", factory)
  let second = connected("B", factory)
  factory.quorum.addMember("ghost", .object(JSObject()))
  let log1 = Log()
  let log2 = Log()
  observe(first.map, into: log1)
  observe(second.map, into: log2)
  try first.map.set("key", text("value"))
  try factory.processAllMessages()  // set (1), accepts from A (2) and B (3)
  #expect(first.map.isPending("key"))
  #expect(try summaryText(first.map).contains(#""expectedSignoffs":["ghost"]"#))
  factory.quorum.addMember("late", .object(JSObject()))
  factory.quorum.removeMember("late")  // never part of the signoffs: nothing happens
  #expect(first.map.isPending("key"))

  factory.quorum.removeMember("ghost")
  #expect(first.map.get("key") == text("value"))
  #expect(first.map.getWithDetails("key")?.acceptedSequenceNumber == 3)
  #expect(second.map.getWithDetails("key")?.acceptedSequenceNumber == 3)
  #expect(log1.entries.map(\.event) == ["pending", "accepted"])
  #expect(log2.entries.map(\.event) == ["pending", "accepted"])
}

/// "Behavior" 3: with nobody to sign off, a proposal settles immediately at the set's sequence number.
@Test func emptySignoffListAcceptsImmediately() throws {
  let quorum = MockQuorumClients()
  let map = PactMapClass(id: "p")
  let runtime = MockContainerRuntime(
    clientId: "A", channel: map, lastSequenceNumber: 0, quorum: quorum)
  let log = Log()
  observe(map, into: log)
  try map.set("key", text("value"))
  let set = runtime.takeOutbound()[0]
  quorum.removeMember("A")
  var json = JSObject<JSONValue>()
  json["clientId"] = .string("A")
  json["clientSequenceNumber"] = .number(1)
  json["referenceSequenceNumber"] = .number(0)
  json["sequenceNumber"] = .number(5)
  json["minimumSequenceNumber"] = .number(0)
  json["type"] = .string("op")
  json["contents"] = set.contents
  try runtime.process(SequencedMessage(json: .object(json)))
  #expect(map.getWithDetails("key")?.acceptedSequenceNumber == 5)
  #expect(log.entries.map(\.event) == ["pending", "accepted"])
}

// MARK: Detached/Attach

/// "Detached/Attach" › "Can set and delete values before attaching and functions normally after
/// attaching". Detached sets settle in a microtask, never synchronously.
@Test func detachedSetsSettleInMicrotasksThenAttach() throws {
  let map = PactMapClass(id: "pactMap")
  #expect(!map.isAttached)
  let log = Log()
  observe(map, into: log)
  try map.set("foo", text("bar"))
  try map.set("baz", text("boop"))
  #expect(log.entries.isEmpty)
  #expect(map.get("baz") == nil)
  try map.runMicrotasks()
  #expect(map.get("baz") == text("boop"))
  #expect(map.getWithDetails("baz")?.acceptedSequenceNumber == 0)
  try map.delete("foo")
  try map.runMicrotasks()
  #expect(map.get("foo") == nil)

  let factory = MockContainerRuntimeFactory<PactMapClass>()
  _ = factory.createContainerRuntime(clientId: "A", channel: map)
  #expect(map.isAttached)
  #expect(map.get("baz") == text("boop"))
  try map.set("woz", text("wiz"))
  try factory.processAllMessages()
  #expect(map.get("woz") == text("wiz"))
}

// MARK: Disconnect/Reconnect

private func twoClients() -> (
  MockContainerRuntimeFactory<PactMapClass>, Client, Client
) {
  let factory = MockContainerRuntimeFactory<PactMapClass>()
  let first = connected("A", factory)
  let second = connected("B", factory)
  return (factory, first, second)
}

/// "Doesn't resubmit accept ops that were sent before offline".
@Test func acceptsSentBeforeOfflineAreNotResubmitted() throws {
  let (factory, first, second) = twoClients()
  try first.map.set("key", text("expected"))
  try factory.processSomeMessages(1)
  second.runtime.disconnect()
  try second.runtime.reconnect(clientId: "B2")
  try factory.processAllMessages()
}

/// "Doesn't resubmit unsequenced proposals that were sent before offline but are futile after reconnect".
@Test func futileProposalSentBeforeOfflineIsDropped() throws {
  let (factory, first, second) = twoClients()
  try first.map.set("key", text("unexpected"))
  first.runtime.disconnect()
  try factory.processAllMessages()
  try second.map.set("key", text("expected"))
  try factory.processAllMessages()
  #expect(second.map.get("key") == text("expected"))
  #expect(first.map.get("key") == nil)
  try first.runtime.reconnect(clientId: "A2")
  #expect(factory.outstandingMessageCount == 0)
  try factory.processAllMessages()
  #expect(first.map.get("key") == text("expected"))
}

/// "Unsequenced proposals sent before offline and still valid after reconnect are accepted after reconnect".
@Test func validProposalSentBeforeOfflineIsResubmitted() throws {
  let (factory, first, second) = twoClients()
  try first.map.set("key", text("expected"))
  first.runtime.disconnect()
  try first.runtime.reconnect(clientId: "A2")
  try factory.processAllMessages()
  #expect(first.map.get("key") == text("expected"))
  #expect(second.map.get("key") == text("expected"))
}

/// "Doesn't resubmit unsequenced proposals that were sent during offline but are futile after reconnect".
@Test func futileProposalSentDuringOfflineIsDropped() throws {
  let (factory, first, second) = twoClients()
  first.runtime.disconnect()
  try first.map.set("key", text("unexpected"))
  try factory.processAllMessages()
  try second.map.set("key", text("expected"))
  try factory.processAllMessages()
  #expect(second.map.get("key") == text("expected"))
  #expect(first.map.get("key") == nil)
  try first.runtime.reconnect(clientId: "A2")
  #expect(factory.outstandingMessageCount == 0)
  #expect(first.map.get("key") == text("expected"))
}

/// "Unsequenced proposals sent during offline and still valid after reconnect are accepted after reconnect".
@Test func validProposalSentDuringOfflineIsResubmitted() throws {
  let (factory, first, second) = twoClients()
  first.runtime.disconnect()
  try first.map.set("key", text("expected"))
  try first.runtime.reconnect(clientId: "A2")
  try factory.processAllMessages()
  #expect(first.map.get("key") == text("expected"))
  #expect(second.map.get("key") == text("expected"))
}

/// "Sequenced proposals that were accepted during offline have correct state after reconnect".
@Test func proposalAcceptedDuringOfflineHasCorrectStateAfterReconnect() throws {
  let (factory, first, second) = twoClients()
  try first.map.set("key", text("expected"))
  try factory.processOneMessage()
  first.runtime.disconnect()
  try factory.processAllMessages()
  try first.runtime.reconnect(clientId: "A2")
  #expect(factory.outstandingMessageCount == 1)
  #expect(first.map.get("key") == text("expected"))
  #expect(second.map.get("key") == text("expected"))
}

/// "Sequenced proposals that remained pending during offline have correct state after reconnect".
@Test func proposalPendingDuringOfflineHasCorrectStateAfterReconnect() throws {
  let (factory, first, second) = twoClients()
  try first.map.set("key", text("expected"))
  try factory.processOneMessage()
  first.runtime.disconnect()
  try first.runtime.reconnect(clientId: "A2")
  #expect(factory.outstandingMessageCount == 2)
  #expect(first.map.get("key") == nil)
  #expect(second.map.get("key") == nil)
  try factory.processAllMessages()
  #expect(first.map.get("key") == text("expected"))
  #expect(second.map.get("key") == text("expected"))
}

// MARK: Errors

/// "Invariants": a duplicate accept while other signoffs remain throws 0x2f9; stash and rollback
/// are unsupported; an unknown op throws.
@Test func errorsAndUnsupportedOperations() throws {
  let (factory, first, _) = twoClients()
  #expect(throws: SharedObjectError.self) { try first.map.applyStashedOp(.null) }
  try first.map.set("key", text("v"))
  try factory.processOneMessage()
  var accept = JSObject<JSONValue>()
  accept["type"] = .string("accept")
  accept["key"] = .string("key")
  var envelope = JSObject<JSONValue>()
  envelope["clientId"] = .string("gone")
  envelope["clientSequenceNumber"] = .number(1)
  envelope["referenceSequenceNumber"] = .number(1)
  envelope["sequenceNumber"] = .number(2)
  envelope["minimumSequenceNumber"] = .number(0)
  envelope["type"] = .string("op")
  envelope["contents"] = .object(accept)
  let message = try SequencedMessage(json: .object(envelope))
  #expect(throws: SharedObjectError.self) {
    try first.map.process(message, local: false, localOpMetadata: nil)
  }
  accept["type"] = .string("bogus")
  envelope["contents"] = .object(accept)
  let unknown = try SequencedMessage(json: .object(envelope))
  #expect(throws: SharedObjectError.self) {
    try first.map.process(unknown, local: false, localOpMetadata: nil)
  }
}
