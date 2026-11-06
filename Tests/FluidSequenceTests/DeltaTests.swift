import Testing
import FluidJS
import FluidMergeTree
@testable import FluidSequence

struct SequenceDeltaTests {
  @Test func removalDeltaPrecedesEndpointSlide() throws {
    let text = SharedString(id: "channel")
    try text.insertText(0, "abcde")
    let interval = try SequenceInterval(client: text.client, id: "i", label: "c", start: 1, end: 2)
    var order: [String] = []
    interval.start.beforeSlide = { _ in order.append("slide") }
    text.sequenceDelta = { event in
      order.append("delta")
      #expect(event.deltaOperation == 1)
      #expect(event.isLocal)
      #expect(event.ranges.count == 1)
      #expect(event.ranges.first?.segment.text == "bc")
    }
    try text.removeRange(1, 3)
    #expect(order == ["delta", "slide"])
  }

  @Test func annotationDeltaContainsPreviousValues() throws {
    let text = SharedString(id: "channel")
    try text.insertText(0, "abc", properties: try sequenceObject([("color", .string("red"))]).asObject())
    var events: [SequenceDeltaEvent] = []
    text.sequenceDelta = { events.append($0) }
    try text.annotateRange(0, 2, try sequenceObject([("color", .string("blue")), ("size", .number(3))]).asObject())
    #expect(events.count == 1)
    #expect(events.first?.ranges.first?.propertyDeltas["color"] == .string("red"))
    #expect(events.first?.ranges.first?.propertyDeltas["size"] == .null)
  }
}

extension SequenceDeltaTests {
  @Test func acknowledgedOverlapSlidesBeforeNewRemovalDelta() throws {
    let client = Client(id: "A", collaborating: false)
    _ = try client.insert(at: 0, text: "abcdef")
    let interval = try SequenceInterval(client: client, id: "i", label: "c", start: 1, end: 2)
    client.startOrUpdateCollaboration("A")
    _ = try client.remove(start: 1, end: 3)
    var order: [String] = []
    interval.start.afterSlide = { _ in order.append("slide") }
    client.delta = { _, _, _ in order.append("delta") }
    try client.process(sequenceObject([("pos1", .number(1)), ("pos2", .number(4)), ("type", .number(1))]),
      sender: "B", sequence: 1, referenceSequence: 0)
    #expect(order == ["slide", "delta"])
  }
}
