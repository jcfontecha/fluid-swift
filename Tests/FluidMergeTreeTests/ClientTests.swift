import FluidJS
import Testing

@testable import FluidMergeTree

@Test func concurrentSamePositionInsertsUseSequenceNotClientName() throws {
  let a = MergeTreeClient(id: "A")
  let b = MergeTreeClient(id: "B")
  let left = try a.insert(at: 0, text: "a")
  let right = try b.insert(at: 0, text: "b")
  for c in [a, b] {
    try c.process(left, sender: "A", sequence: 1, referenceSequence: 0)
    try c.process(right, sender: "B", sequence: 2, referenceSequence: 0)
    #expect(c.text == "ba")
  }
}
@Test func ordinaryRemovePreservesConcurrentInsertion() throws {
  let a = MergeTreeClient(id: "A")
  let b = MergeTreeClient(id: "B")
  let initial = try a.insert(at: 0, text: "abc")
  for c in [a, b] { try c.process(initial, sender: "A", sequence: 1, referenceSequence: 0) }
  let remove = try a.remove(start: 0, end: 3)
  let insert = try b.insert(at: 1, text: "😀")
  for c in [a, b] {
    try c.process(remove, sender: "A", sequence: 2, referenceSequence: 1)
    try c.process(insert, sender: "B", sequence: 3, referenceSequence: 1)
    #expect(c.text == "😀")
    #expect(c.length == 2)
  }
}
@Test func removeHalfASurrogate() throws {
  let c = MergeTreeClient(id: "A")
  _ = try c.insert(at: 0, text: "A😀B")
  _ = try c.remove(start: 1, end: 2)
  #expect(Array(c.text.utf16) == [65, 0xde00, 66])
}
