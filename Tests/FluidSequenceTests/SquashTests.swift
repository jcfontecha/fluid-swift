import Testing
import FluidJS
import FluidMergeTree
@testable import FluidSequence

struct SequenceSquashTests {
  @Test func squashElidesInsertedThenRemovedSegments() throws {
    let client = Client(id: "A")
    _ = try client.insert(at: 0, text: "x")
    _ = try client.remove(start: 0, end: 1)
    let operations = try client.regeneratePendingOps(squash: true)
    #expect(operations.count == 2)
    for (index, op) in operations.enumerated() {
      #expect(try op.member("ops").asArray().isEmpty)
      try client.process(op, sender: "A", sequence: index + 1, referenceSequence: 0)
    }
    #expect(client.pendingOperationCount == 0)
    #expect(client.length == 0)
  }

  @Test func squashRebaseDoesNotTargetLaterRemovedLocalInsertion() throws {
    let client = Client(id: "A", collaborating: false)
    _ = try client.insert(at: 0, text: "abc")
    client.startOrUpdateCollaboration("A")
    _ = try client.insert(at: 1, text: "x")
    let collection = IntervalCollection(client: client, label: "c")
    var metadata: IntervalLocalOpMetadata?
    collection.submit = { _, _, pending in metadata = pending }
    let interval = try collection.add(id: "i", start: 1, end: 1)
    let pending = try #require(metadata)
    _ = try client.remove(start: 1, end: 2)
    let rebased = try #require(try collection.rebase(interval.serialize(), metadata: pending, squash: true))
    #expect(try rebased.member("start").asInt() == 2)
    #expect(interval.start.segment?.text == "bc")
  }
}
