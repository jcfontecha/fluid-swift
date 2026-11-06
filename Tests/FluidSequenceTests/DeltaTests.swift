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
    text.sequenceDelta.on { event in
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
    text.sequenceDelta.on { events.append($0) }
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

/// sharedString events are Node EventEmitter events: any number of listeners, in registration order.
struct SequenceEventListenerTests {
  @Test func everyListenerRunsInRegistrationOrder() throws {
    let text = SharedString(id: "channel")
    var order: [String] = []
    text.sequenceDelta.on { _ in order.append("first") }
    text.sequenceDelta.on { _ in order.append("second") }
    try text.insertText(0, "a")
    #expect(order == ["first", "second"])
  }

  @Test func offRemovesOnlyThatListener() throws {
    let text = SharedString(id: "channel")
    var order: [String] = []
    let first = text.sequenceDelta.on { _ in order.append("first") }
    text.sequenceDelta.on { _ in order.append("second") }
    text.sequenceDelta.off(first)
    try text.insertText(0, "a")
    #expect(order == ["second"])
  }

  /// Node `emit` runs the listeners registered when it starts: one added during an emit runs from
  /// the next emit, and one removed during an emit still runs for it.
  @Test func emitUsesListenersRegisteredWhenItStarts() throws {
    let text = SharedString(id: "channel")
    var order: [String] = []
    var second = 0
    text.sequenceDelta.on { _ in
      order.append("first")
      text.sequenceDelta.off(second)
      text.sequenceDelta.on { _ in order.append("added") }
    }
    second = text.sequenceDelta.on { _ in order.append("second") }
    try text.insertText(0, "a")
    #expect(order == ["first", "second"])
    order = []
    try text.insertText(0, "b")
    #expect(order == ["first", "added"])
  }
}
