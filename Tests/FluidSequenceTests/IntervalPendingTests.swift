import Testing
import FluidJS
import FluidMergeTree
import FluidDriverDefinitions
@testable import FluidSequence

struct IntervalPendingTests {
  private func seeded() throws -> (Client, IntervalCollection) {
    let client = Client(id: "A", collaborating: false)
    _ = try client.insert(at: 0, text: "abcdef")
    let collection = IntervalCollection(client: client, label: "comments")
    _ = try collection.add(id: "i", start: 1, end: 3)
    client.startOrUpdateCollaboration("A")
    return (client, collection)
  }

  private func message(_ seq: Int, sender: JSString = "B") throws -> SequencedMessage {
    try SequencedMessage(json: sequenceObject([
      ("type", .string("op")), ("clientId", .string(sender)),
      ("sequenceNumber", .number(Double(seq))), ("referenceSequenceNumber", .number(0)),
      ("minimumSequenceNumber", .number(0)), ("clientSequenceNumber", .number(Double(seq))),
      ("contents", .null),
    ]))
  }

  private func delta(start: Int? = nil, end: Int? = nil, color: JSString? = nil) -> JSONValue {
    var props = JSObject<JSONValue>()
    if let color { props["color"] = .string(color) }
    props["intervalId"] = .string("i")
    props["referenceRangeLabels"] = .array([.string("comments")])
    var fields = JSObject<JSONValue>()
    fields["start"] = start.map { .number(Double($0)) }
    fields["end"] = end.map { .number(Double($0)) }
    fields["properties"] = .object(props)
    return .object(fields)
  }

  @Test func remoteEndpointsDoNotReplacePendingLocalEndpoints() throws {
    let (client, collection) = try seeded()
    var sent: [(JSONValue, IntervalLocalOpMetadata)] = []
    collection.submit = { _, value, metadata in sent.append((value, metadata)) }
    _ = try collection.change("i", start: 2, end: 4)
    try collection.process("change", value: delta(start: 0, end: 1), message: message(1), metadata: nil)
    let current = try #require(collection.getIntervalById("i"))
    #expect(client.localReferencePositionToPosition(current.start) == 2)
    let pending = try #require(sent.first)
    try collection.process("change", value: pending.0, message: message(2, sender: "A"), metadata: pending.1)
    #expect(current.start.includes(64))
    #expect(collection.pendingCount == 0)
  }

  @Test func pendingPropertyOverlaySurvivesRemoteThenRollback() throws {
    let (_, collection) = try seeded()
    var sent: [(JSONValue, IntervalLocalOpMetadata)] = []
    collection.submit = { _, value, metadata in sent.append((value, metadata)) }
    var props = JSObject<JSONValue>()
    props["color"] = .string("local")
    _ = try collection.change("i", properties: props)
    try collection.process("change", value: delta(color: "remote"), message: message(1), metadata: nil)
    #expect(collection.getIntervalById("i")?.properties["color"] == .string("local"))
    let pending = try #require(sent.first)
    try collection.rollback(pending.1)
    #expect(collection.getIntervalById("i")?.properties["color"] == .string("remote"))
    #expect(collection.pendingCount == 0)
  }

  @Test func remoteDeleteWinsOverPendingChangeAck() throws {
    let (_, collection) = try seeded()
    var sent: [(JSONValue, IntervalLocalOpMetadata)] = []
    collection.submit = { _, value, metadata in sent.append((value, metadata)) }
    _ = try collection.change("i", start: 2, end: 4)
    try collection.process("delete", value: delta(), message: message(1), metadata: nil)
    let pending = try #require(sent.first)
    try collection.process("change", value: pending.0, message: message(2, sender: "A"), metadata: pending.1)
    #expect(collection.getIntervalById("i") == nil)
    #expect(collection.pendingCount == 0)
  }
}

extension IntervalPendingTests {
  @Test func reconnectUsesIntervalLocalSequenceNotLatestOptimisticPosition() throws {
    let (client, collection) = try seeded()
    var sent: [(JSONValue, IntervalLocalOpMetadata)] = []
    collection.submit = { _, value, metadata in sent.append((value, metadata)) }
    _ = try collection.change("i", start: 2, end: 4)
    let pending = try #require(sent.first)
    _ = try client.insert(at: 0, text: "later")
    let rebased = try #require(try collection.rebase(pending.0, metadata: pending.1))
    #expect(try rebased.member("start").asInt() == 2)
    #expect(try rebased.member("end").asInt() == 4)
  }

  @Test func reconnectDropsDetachedAddAndSubmitsDelete() throws {
    let (client, collection) = try seeded()
    var sent: [(JSString, JSONValue, IntervalLocalOpMetadata)] = []
    collection.submit = { sent.append(($0, $1, $2)) }
    _ = try collection.add(id: "new", start: 1, end: 3)
    let pending = try #require(sent.first)
    try client.process(sequenceObject([("pos1", .number(0)), ("pos2", .number(6)), ("type", .number(1))]),
      sender: "B", sequence: 1, referenceSequence: 0)
    let rebased = try collection.rebase(pending.1, metadata: pending.2)
    #expect(rebased == nil)
    #expect(collection.getIntervalById("new") == nil)
    #expect(sent.last?.0 == "delete")
  }
}
