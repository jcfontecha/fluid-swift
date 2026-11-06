import Testing
import FluidJS
import FluidMergeTree
import FluidTestRuntimeUtils
@testable import FluidSequence

struct SequenceMaintenanceTests {
  @Test func splitPrecedesDeltaAndAckCarriesMessage() throws {
    let text = SharedString(id: "text")
    try text.insertText(0, "abcd")
    let factory = MockContainerRuntimeFactory<SharedString>()
    _ = factory.createContainerRuntime(clientId: "A", channel: text)
    var order: [Int] = []
    text.sequenceDelta.on { order.append($0.deltaOperation) }
    text.sequenceMaintenance.on { event in
      order.append(event.deltaOperation)
      if event.deltaOperation == -4 {
        #expect(!event.isLocal)
        #expect(event.opArgs?.sequencedMessage?.clientId == "A")
      } else { #expect(event.isLocal) }
    }
    try text.insertText(2, "x")
    #expect(order.prefix(2) == [-2, 0])
    try factory.processAllMessages()
    #expect(order.contains(-4))
  }

  @Test func rangesSortAndResolveOnlyOnFirstAccess() throws {
    let text = SharedString(id: "text")
    try text.insertText(0, "abcd")
    var saved: SequenceDeltaEvent?
    let token = text.sequenceDelta.on { saved = $0 }
    try text.insertText(2, "x")
    let event = try #require(saved)
    text.sequenceDelta.off(token)
    try text.insertText(0, "prefix")
    #expect(event.first?.position == 8)
    try text.insertText(0, "more")
    #expect(event.first?.position == 8)
    #expect(event.first?.operation == 0)
  }
}

extension SequenceMaintenanceTests {
  @Test func splitCallbackSeesTemporaryParentBeforeInsertion() throws {
    let text = SharedString(id: "text")
    try text.insertText(0, "abcd")
    try text.insertMarker(4, refType: 1)
    var positions: [Int] = []
    text.sequenceMaintenance.on { event in
      if event.deltaOperation == -2 { positions = event.ranges.map(\.position) }
    }
    try text.insertText(2, "x")
    #expect(positions == [0, 3])
  }
}

extension SequenceMaintenanceTests {
  @Test func reconnectPreservesLocalPerspectiveDuringRemovalAck() throws {
    let client = Client(id: "A", collaborating: false)
    _ = try client.insert(at: 0, text: "abcd")
    let interval = try SequenceInterval(client: client, id: "i", label: "c",
      start: SequencePlace(1, side: .after), end: SequencePlace(2, side: .before))
    client.startOrUpdateCollaboration("A")
    let removal = try client.remove(start: 1, end: 3)
    _ = try client.insert(at: 1, text: "x")
    client.startOrUpdateCollaboration("B")
    var startDuringEndSlide: Int?
    interval.end.afterSlide = { _ in startDuringEndSlide = client.localReferencePositionToPosition(interval.start) }
    try client.process(removal, sender: "B", sequence: 1, referenceSequence: 0)
    #expect(startDuringEndSlide == 1)
  }
}
