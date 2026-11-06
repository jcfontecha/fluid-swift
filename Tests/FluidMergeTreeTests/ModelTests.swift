import FluidJS
import Testing

@testable import FluidMergeTree

// Ported cases from textSegment.spec, perspective and partialLength tests, with
// the overlapping-removal examples pinned by specs/merge-tree/model.md.
@Test func splitsSurrogatePairWithoutRepair() throws {
  let segment = BaseSegment(text: JSString("A😀B"), insertion: Stamp(sequence: 0, client: "A"))
  let right = try segment.split(at: 2)
  #expect(Array(segment.text!.utf16) == [65, 0xd83d])
  #expect(Array(right.text!.utf16) == [0xde00, 66])
  #expect(segment.insertion == right.insertion)
}
@Test func pendingStampSortsAfterSequenced() {
  #expect(Stamp(sequence: 100, client: "Z") < Stamp(sequence: -1, client: "A", localSequence: 1))
  #expect(
    Stamp(sequence: -1, client: "A", localSequence: 1)
      < Stamp(sequence: -1, client: "Z", localSequence: 2))
}
@Test func overlappingRemovalIsSeenByBothRemovers() {
  let segment = BaseSegment(
    text: "x", insertion: Stamp(sequence: 0, client: "origin"),
    removals: [Stamp(sequence: 20, client: "A"), Stamp(sequence: 25, client: "B")])
  #expect(Perspective.prior(sequence: 15, client: "observer").contains(segment))
  #expect(!Perspective.prior(sequence: 15, client: "A").contains(segment))
  #expect(!Perspective.prior(sequence: 15, client: "B").contains(segment))
  let lengths = PartialLengths(segments: [segment], minimumSequence: 10)
  #expect(lengths.length(sequence: 15, client: "observer") == 1)
  #expect(lengths.length(sequence: 15, client: "A") == 0)
  #expect(lengths.length(sequence: 15, client: "B") == 0)
  #expect(lengths.length(sequence: 22, client: "observer") == 0)
}
@Test func localRemovalCannotSubtractUnseenInsertion() {
  let segment = BaseSegment(
    text: "abc", insertion: Stamp(sequence: 12, client: "remote"),
    removals: [Stamp(sequence: -1, client: "local", localSequence: 7)])
  #expect(!Perspective.reconnecting(sequence: 11, localSequence: 7).contains(segment))
  #expect(Perspective.reconnecting(sequence: 12, localSequence: 6).contains(segment))
  #expect(!Perspective.reconnecting(sequence: 12, localSequence: 7).contains(segment))
}
@Test func newlinePreventsTextCoalescing() {
  let stamp = Stamp(sequence: 0, client: "A")
  #expect(!BaseSegment(text: "a\n", insertion: stamp).canAppend(BaseSegment(text: "b", insertion: stamp)))
  #expect(BaseSegment(text: "a", insertion: stamp).canAppend(BaseSegment(text: "b", insertion: stamp)))
}
@Test func partialCollapsePreservesHistoricalQueries() {
  let segments = [
    BaseSegment(text: "abc", insertion: Stamp(sequence: 12, client: "A")),
    BaseSegment(
      text: "xy", insertion: Stamp(sequence: 14, client: "B"),
      removals: [Stamp(sequence: 16, client: "C")]),
  ]
  var lengths = PartialLengths(segments: segments, minimumSequence: 10)
  #expect(lengths.length(sequence: 14, client: "observer") == 5)
  lengths.advanceMinimum(to: 14)
  #expect(lengths.length(sequence: 14, client: "observer") == 5)
  #expect(lengths.length(sequence: 16, client: "observer") == 3)
  #expect(lengths.length(sequence: 14, client: "C") == 3)
}
