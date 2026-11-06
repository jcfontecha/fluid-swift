import Testing
import FluidJS
import FluidMergeTree
@testable import FluidSequence

/// Ports sequenceInterval endpoint reference behavior and intervalCollection serialization cases.
struct SequenceIntervalTests {
  private func seededClient() throws -> Client {
    let client = Client(id: "A")
    let insert = try client.insert(at: 0, text: "abcdef")
    try client.process(insert, sender: "A", sequence: 1, referenceSequence: 0)
    return client
  }

  @Test func slideAfterRemoval() throws {
    let client = try seededClient()
    let interval = try SequenceInterval(client: client, id: "i", label: "comments", start: 1, end: 3)
    let removal = try client.remove(start: 1, end: 4)
    try client.process(removal, sender: "A", sequence: 2, referenceSequence: 1)
    #expect(client.localReferencePositionToPosition(interval.start) == 1)
    #expect(client.localReferencePositionToPosition(interval.end) == 1)
    #expect(interval.start.segment?.text == "ef")
    #expect(interval.end.segment?.text == "ef")
  }

  @Test func serializeInUpstreamOrder() throws {
    let client = try seededClient()
    var props = JSObject<JSONValue>()
    props["color"] = .string("red")
    let interval = try SequenceInterval(client: client, id: "i", label: "comments", start: 1, end: 3, properties: props)
    #expect(JSON.stringify(interval.serialize()) == "{\"end\":3,\"intervalType\":2,\"sequenceNumber\":1,\"start\":1,\"stickiness\":2,\"startSide\":0,\"endSide\":0,\"properties\":{\"color\":\"red\",\"intervalId\":\"i\",\"referenceRangeLabels\":[\"comments\"]}}")
  }
}

struct PendingIntervalTests {
  @Test func pendingEndpointsStayUntilAcknowledged() throws {
    let client = Client(id: "A")
    let insert = try client.insert(at: 0, text: "abcdef")
    try client.process(insert, sender: "A", sequence: 1, referenceSequence: 0)
    let interval = try SequenceInterval(client: client, id: "pending", label: "comments", start: 1, end: 3, pending: true)
    try client.process(sequenceObject([
      ("pos1", .number(1)), ("pos2", .number(4)), ("type", .number(1)),
    ]), sender: "B", sequence: 2, referenceSequence: 1)
    #expect(interval.start.includes(128))
    #expect(interval.start.includes(16))
    #expect(interval.end.includes(32))
    #expect(interval.start.segment?.text == "bcd")
    try interval.acknowledge()
    #expect(interval.start.includes(64))
    #expect(interval.end.includes(64))
    #expect(interval.start.segment?.text == "ef")
    #expect(interval.end.segment?.text == "ef")
  }

  @Test func remoteEndpointsUseReferencePerspective() throws {
    let client = Client(id: "A")
    let insert = try client.insert(at: 0, text: "abc")
    try client.process(insert, sender: "A", sequence: 1, referenceSequence: 0)
    _ = try client.insert(at: 0, text: "local")
    let interval = try SequenceInterval(client: client, id: "remote", label: "comments", start: 1, end: 2, perspective: .prior(sequence: 1, client: "B"))
    #expect(client.localReferencePositionToPosition(interval.start) == 6)
    #expect(client.localReferencePositionToPosition(interval.end) == 7)
  }
}

extension SequenceIntervalTests {
  @Test func publicPropertiesExcludeSerializedIdentity() throws {
    let client = try seededClient()
    var props = JSObject<JSONValue>()
    props["color"] = .null
    let interval = try SequenceInterval(client: client, id: "i", label: "c", start: 0, end: 1, properties: props)
    #expect(interval.properties.isEmpty)
    #expect(try interval.serialize().member("properties").member("intervalId") == .string("i"))
  }
}

extension SequenceIntervalTests {
  @Test func acknowledgedSlidesRecreateEndpointsInStartEndOrder() throws {
    let client = try seededClient()
    let interval = try SequenceInterval(client: client, id: "i", label: "c", start: 0, end: 1, pending: true)
    try client.process(sequenceObject([("pos1", .number(0)), ("pos2", .number(5)), ("type", .number(1))]),
      sender: "B", sequence: 2, referenceSequence: 1)
    try interval.acknowledge()
    var order: [String] = []
    interval.start.afterSlide = { _ in order.append("start") }
    interval.end.afterSlide = { _ in order.append("end") }
    try client.process(sequenceObject([("pos1", .number(0)), ("pos2", .number(1)), ("type", .number(1))]),
      sender: "B", sequence: 3, referenceSequence: 2)
    #expect(order == ["start", "end"])
  }
}

extension SequenceIntervalTests {
  @Test func cloneSharesLiveEndpointReferences() throws {
    let client = try seededClient()
    let interval = try SequenceInterval(client: client, id: "i", label: "c", start: 1, end: 3)
    let clone = interval.clone()
    #expect(clone.start === interval.start)
    #expect(clone.end === interval.end)
    _ = try client.insert(at: 1, text: "x")
    #expect(client.localReferencePositionToPosition(clone.start) == 2)
  }
}
