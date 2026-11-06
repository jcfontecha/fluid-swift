import FluidJS
import Testing

@testable import FluidMergeTree

@Test func referencesFollowSplitButTransientReferencesDoNot() throws {
  let client = Client(id: "A")
  _ = try client.insert(at: 0, text: "abcd")
  let ref = try client.createLocalReferencePosition(at: 3, refType: 128)
  let transient = try client.createLocalReferencePosition(at: 3, refType: 256)
  let original = ref.segment
  _ = try client.insert(at: 2, text: "X")
  #expect(ref.segment !== original)
  #expect(transient.segment === original)
  #expect(client.localReferencePositionToPosition(ref) == 4)
  #expect(client.localReferencePositionToPosition(transient) == 3)
  #expect(ref.segment?.localRefs.has(ref) == true)
  #expect(transient.segment?.localRefs.has(transient) == false)
}

@Test func slideWaitsForAckAndSkipsPendingInsertion() throws {
  let client = Client(id: "A")
  let initial = try client.insert(at: 0, text: "abcd")
  try client.process(initial, sender: "A", sequence: 1, referenceSequence: 0)
  let ref = try client.createLocalReferencePosition(at: 1, refType: 64)
  let stay = try client.createLocalReferencePosition(at: 1, refType: 128)
  var events: [String] = []
  ref.beforeSlide = { _ in events.append("before") }
  ref.afterSlide = { _ in events.append("after") }
  let removal = try client.remove(start: 1, end: 3)
  let tombstone = ref.segment
  _ = try client.insert(at: 1, text: "X")
  #expect(events.isEmpty)
  try client.process(removal, sender: "A", sequence: 2, referenceSequence: 1)
  #expect(events == ["before", "after"])
  #expect(ref.segment !== tombstone)
  #expect(stay.segment === tombstone)
  #expect(ref.segment?.text == "d")
  #expect(client.localReferencePositionToPosition(ref) == 2)
}

@Test func slideGroupsPreserveOrderAndSimpleReferencesDetach() throws {
  let client = Client(id: "A")
  let initial = try client.insert(at: 0, text: "abcd")
  try client.process(initial, sender: "A", sequence: 1, referenceSequence: 0)
  let first = try client.createLocalReferencePosition(at: 0, refType: 64)
  let second = try client.createLocalReferencePosition(at: 1, refType: 64)
  let simple = try client.createLocalReferencePosition(at: 1, refType: 0)
  let target = try client.createLocalReferencePosition(at: 3, refType: 128)
  // Force separate source leaves, just as a concurrent insertion would.
  _ = try client.insert(at: 1, text: "X")
  var callbacks: [Int] = []
  first.beforeSlide = { _ in callbacks.append(1) }
  second.beforeSlide = { _ in callbacks.append(2) }
  let removal = object([("type", .number(1)), ("pos1", .number(0)), ("pos2", .number(3))])
  try client.process(removal, sender: "B", sequence: 2, referenceSequence: 1)
  #expect(callbacks == [1, 2])
  #expect(first.segment === target.segment)
  let refs = target.segment?.localRefs.references ?? []
  #expect(refs.count == 3)
  #expect(refs[0] === first)
  #expect(refs[1] === second)
  #expect(refs[2] === target)
  #expect(client.localReferencePositionToPosition(simple) == -1)
}

@Test func emptyTreeDetachesSlidingReferencesAndCallsBothCallbacks() throws {
  let client = Client(id: "A")
  let initial = try client.insert(at: 0, text: "a")
  try client.process(initial, sender: "A", sequence: 1, referenceSequence: 0)
  let slide = try client.createLocalReferencePosition(at: 0, refType: 64)
  let stay = try client.createLocalReferencePosition(at: 0, refType: 128)
  var events: [Bool] = []
  slide.beforeSlide = { ref in events.append(ref.segment != nil) }
  slide.afterSlide = { ref in events.append(ref.segment != nil) }
  let removal = try client.remove(start: 0, end: 1)
  try client.process(removal, sender: "A", sequence: 2, referenceSequence: 1)
  #expect(events == [true, false])
  #expect(client.localReferencePositionToPosition(slide) == -1)
  #expect(client.localReferencePositionToPosition(stay) == 0)
  #expect(stay.segment?.localRefs.size == 1)
}

@Test func appendTransfersRegisteredReferencesBeforeLengthChanges() throws {
  let left = TextSegment(text: "ab", insertion: Stamp(sequence: 0, client: "A"))
  let right = TextSegment(text: "cd", insertion: Stamp(sequence: 0, client: "A"))
  let ref = try LocalReference(segment: right, offset: 1, refType: 128)
  right.localRefs.addLocalRef(ref, offset: 1)
  left.localRefs.append(right.localRefs)
  #expect(ref.segment === left)
  #expect(ref.offset == 3)
  #expect(right.localRefs.empty)
  #expect(left.localRefs.has(ref))
}

@Test func endpointReferencesRemainAnchoredAfterNewInsertion() throws {
  let client = Client(id: "A", referencesCanSlideToEndpoint: true)
  let insert = try client.insert(at: 0, text: "ab")
  try client.process(insert, sender: "A", sequence: 1, referenceSequence: 0)
  let end = try client.createLocalReferencePosition(at: 1, refType: 64, canSlideToEndpoint: true)
  let start = try client.createLocalReferencePosition(
    at: 0, refType: 64,
    slidingPreference: .backward, canSlideToEndpoint: true)
  let remove = try client.remove(start: 0, end: 2)
  try client.process(remove, sender: "A", sequence: 2, referenceSequence: 1)
  #expect(client.localReferencePositionToPosition(start) == 0)
  #expect(client.localReferencePositionToPosition(end) == 0)
  _ = try client.insert(at: 0, text: "xyz")
  #expect(client.localReferencePositionToPosition(start) == 0)
  #expect(client.localReferencePositionToPosition(end) == 3)
}

@Test func trackingGroupRetainsReferenceAcrossSplitAndReclamation() throws {
  let client = Client(id: "A")
  let initial = try client.insert(at: 0, text: "abc")
  try client.process(initial, sender: "A", sequence: 1, referenceSequence: 0)
  let group = TrackingGroup()
  do {
    let ref = try client.createLocalReferencePosition(at: 1, refType: 128)
    group.link(ref)
    #expect(group.has(ref))
  }
  let removal = try client.remove(start: 1, end: 2)
  try client.process(removal, sender: "A", sequence: 2, referenceSequence: 1)
  try client.advanceMinimum(to: 2)
  let ref = try #require(group.references.first)
  #expect(ref.segment?.text == "b")
  #expect(client.localReferencePositionToPosition(ref) == -1)
  group.unlink(ref)
  #expect(group.references.isEmpty)
}
