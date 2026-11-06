import FluidJS
import Testing

@testable import FluidMergeTree

@Test func minimumCoalescesStableSegmentsAndTransfersReferences() throws {
  let client = Client(id: "A")
  let first = try client.insert(at: 0, text: "ab")
  try client.process(first, sender: "A", sequence: 1, referenceSequence: 0)
  let second = try client.insert(at: 2, text: "cd")
  try client.process(second, sender: "A", sequence: 2, referenceSequence: 1)
  let ref = try client.createLocalReferencePosition(at: 3, refType: 128)
  try client.advanceMinimum(to: 2)
  #expect(client.segments.count == 1)
  #expect(ref.segment === client.segments.first)
  #expect(ref.offset == 3)
}

@Test func pendingAnnotationPreventsReclamationUntilAcknowledged() throws {
  let client = Client(id: "A")
  let insert = try client.insert(at: 0, text: "abc")
  try client.process(insert, sender: "A", sequence: 1, referenceSequence: 0)
  let annotation = object([
    ("type", .number(2)), ("pos1", .number(0)),
    ("pos2", .number(3)), ("props", object([("color", .string("red"))])),
  ])
  _ = try client.edit(annotation)
  let remove = object([("type", .number(1)), ("pos1", .number(0)), ("pos2", .number(3))])
  try client.process(remove, sender: "B", sequence: 2, referenceSequence: 1)
  try client.advanceMinimum(to: 2)
  #expect(client.segments.count == 1)
  try client.process(annotation, sender: "A", sequence: 3, referenceSequence: 2)
  try client.advanceMinimum(to: 3)
  #expect(client.segments.isEmpty)
}

@Test func trackedTombstoneSurvivesMinimumAndSplitCopiesTracking() throws {
  let client = Client(id: "A")
  let insertion = try client.insert(at: 0, text: "abcd")
  try client.process(insertion, sender: "A", sequence: 1, referenceSequence: 0)
  let group = TrackingGroup()
  group.link(try #require(client.segments.first))
  let removal = try client.remove(start: 1, end: 3)
  #expect(group.segments.count == 3)
  try client.process(removal, sender: "A", sequence: 2, referenceSequence: 1)
  try client.advanceMinimum(to: 2)
  #expect(client.segments.contains { !$0.removals.isEmpty })
}

@Test func reclaimedReferenceRetainsSegmentIdentityWithoutRetainingTree() throws {
  let client = Client(id: "A")
  let insertion = try client.insert(at: 0, text: "a")
  try client.process(insertion, sender: "A", sequence: 1, referenceSequence: 0)
  let stay = try client.createLocalReferencePosition(at: 0, refType: 128)
  let removal = try client.remove(start: 0, end: 1)
  try client.process(removal, sender: "A", sequence: 2, referenceSequence: 1)
  try client.advanceMinimum(to: 2)
  #expect(client.segments.isEmpty)
  #expect(stay.segment != nil)
  #expect(stay.segment?.localRefs.has(stay) == true)
  #expect(client.localReferencePositionToPosition(stay) == -1)
}

@Test func blockLengthsTrackEveryPerspectiveAfterSplitsAndAck() throws {
  let client = Client(id: "A")
  for sequence in 1...40 {
    let op = object([
      ("type", .number(0)), ("pos1", .number(Double(sequence - 1))),
      ("seg", .string("x")),
    ])
    try client.process(
      op, sender: sequence % 2 == 0 ? "B" : "C",
      sequence: sequence, referenceSequence: sequence - 1)
  }
  let removal = try client.remove(start: 7, end: 31)
  for sequence in 0...40 {
    for name: JSString in ["A", "B", "C"] {
      let perspective = Perspective.prior(sequence: sequence, client: name)
      let expected = client.segments.reduce(0) { $0 + (perspective.contains($1) ? $1.length : 0) }
      #expect(
        client.mergeTree.root.partialLengths.length(sequence: sequence, client: name) == expected)
    }
  }
  try client.process(removal, sender: "A", sequence: 41, referenceSequence: 40)
  #expect(client.mergeTree.root.localLength == 16)
}
