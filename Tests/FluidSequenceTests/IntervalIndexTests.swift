import Testing
import FluidJS
import FluidMergeTree
@testable import FluidSequence

struct IntervalIndexTests {
  @Test func sidedComparatorAndInclusiveOverlap() throws {
    let client = Client(id: "A", collaborating: false)
    _ = try client.insert(at: 0, text: "abcdef")
    let before = try SequenceInterval(client: client, id: "b", label: "c", start: 1, end: 3)
    let after = try SequenceInterval(client: client, id: "a", label: "c",
      start: SequencePlace(1, side: .after), end: SequencePlace(3, side: .after))
    #expect(after.compareStart(before) < 0)
    #expect(after.compareEnd(before) > 0)
    let touching = try SequenceInterval(client: client, id: "t", label: "c", start: 3, end: 4)
    #expect(before.overlaps(touching))
    #expect(!before.overlapsPos(3, 4))
  }

  @Test func indexesFollowSlidesAndDetachEmptiesThem() throws {
    let text = SharedString(id: "text")
    try text.insertText(0, "abcdefgh")
    let collection = text.getIntervalCollection("c")
    let overlap = OverlappingIntervalsIndex(sequence: text)
    let endpoint = EndpointIndex(sequence: text)
    try collection.add(id: "z", start: 1, end: 4)
    try collection.add(id: "a", start: 2, end: 4)
    collection.attachIndex(overlap)
    collection.attachIndex(endpoint)
    #expect(try overlap.findOverlappingIntervals(start: 4, end: 5).map(\.id) == ["z", "a"])
    #expect(try endpoint.previousInterval(4)?.id == "z")
    #expect(try endpoint.nextInterval(4)?.id == "a")
    try text.removeRange(1, 5)
    #expect(try overlap.findOverlappingIntervals(start: 1, end: 1).count == 2)
    #expect(collection.detachIndex(overlap))
    #expect(try overlap.findOverlappingIntervals(start: 0, end: 2).isEmpty)
    #expect(!collection.detachIndex(overlap))
  }

  @Test func tombstoneAnchorsRemainOrderedWhenVisiblePositionsCoincide() throws {
    let client = Client(id: "A", collaborating: false)
    _ = try client.insert(at: 0, text: "abcdef")
    client.startOrUpdateCollaboration("A")
    let early = try SequenceInterval(client: client, id: "z", label: "c", start: 1, end: 1, pending: true)
    let late = try SequenceInterval(client: client, id: "a", label: "c", start: 3, end: 3, pending: true)
    _ = try client.remove(start: 1, end: 4)
    #expect(early.compare(late) < 0)
    #expect(client.localReferencePositionToPosition(early.start) == client.localReferencePositionToPosition(late.start))
  }
}
