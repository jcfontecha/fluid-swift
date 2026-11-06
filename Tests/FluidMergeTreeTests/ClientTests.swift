import FluidJS
import Testing

@testable import FluidMergeTree

@Test func concurrentSamePositionInsertsUseSequenceNotClientName() throws {
  let a = Client(id: "A")
  let b = Client(id: "B")
  let left = try a.insert(at: 0, text: "a")
  let right = try b.insert(at: 0, text: "b")
  for c in [a, b] {
    try c.process(left, sender: "A", sequence: 1, referenceSequence: 0)
    try c.process(right, sender: "B", sequence: 2, referenceSequence: 0)
    #expect(c.text == "ba")
  }
}
@Test func ordinaryRemovePreservesConcurrentInsertion() throws {
  let a = Client(id: "A")
  let b = Client(id: "B")
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
  let c = Client(id: "A")
  _ = try c.insert(at: 0, text: "A😀B")
  _ = try c.remove(start: 1, end: 2)
  #expect(Array(c.text.utf16) == [65, 0xde00, 66])
}

@Test func reconnectRegeneratesPendingInsertionAgainstRemoteRemoval() throws {
  let client = Client(id: "A")
  let initial = try client.insert(at: 0, text: "hi my friend")
  try client.process(initial, sender: "A", sequence: 1, referenceSequence: 0)
  _ = try client.insert(at: 6, text: "good ")
  let removal = object([("type", .number(1)), ("pos1", .number(3)), ("pos2", .number(6))])
  try client.process(removal, sender: "B", sequence: 2, referenceSequence: 1)
  let rebased = try client.regeneratePendingOps()
  #expect(rebased.count == 1)
  #expect(try rebased[0].member("pos1").asInt() == 3)
  #expect(client.text == "hi good friend")
  try client.process(rebased[0], sender: "A", sequence: 3, referenceSequence: 2)
  #expect(client.text == "hi good friend")
}

@Test func rollbackRestoresInsertRemoveAndAnnotation() throws {
  let client = Client(id: "A")
  let initial = try client.insert(at: 0, text: "abc")
  try client.process(initial, sender: "A", sequence: 1, referenceSequence: 0)
  _ = try client.insert(at: 1, text: "x")
  try client.rollbackPendingOp()
  #expect(client.text == "abc")
  _ = try client.remove(start: 0, end: 2)
  try client.rollbackPendingOp()
  #expect(client.text == "abc")
  _ = try client.edit(
    object([
      ("type", .number(2)), ("pos1", .number(0)),
      ("pos2", .number(3)), ("props", object([("color", .string("red"))])),
    ]))
  try client.rollbackPendingOp()
  #expect(
    client.segments.filter { Perspective.local.contains($0) }.allSatisfy {
      $0.properties?["color"] == nil
    })
}

@Test func reconnectCanRepeatAfterOneEditSplitsIntoMultipleOperations() throws {
  let client = Client(id: "A")
  _ = try client.insert(at: 0, text: "abcd")
  _ = try client.edit(
    object([
      ("type", .number(2)), ("pos1", .number(1)),
      ("pos2", .number(3)), ("props", object([("color", .string("red"))])),
    ]))
  let first = try client.regeneratePendingOps()
  let second = try client.regeneratePendingOps()
  #expect(first == second)
  #expect(second.count == 2)
}

@Test func repeatedReconnectDoesNotRepeatNormalizationCallbacks() throws {
  let client = Client(id: "A")
  let initial = try client.insert(at: 0, text: "abcd")
  try client.process(initial, sender: "A", sequence: 1, referenceSequence: 0)
  _ = try client.insert(at: 2, text: "x")
  let ref = try client.createLocalReferencePosition(at: 2, refType: 128)
  var callbacks = 0
  ref.beforeSlide = { _ in callbacks += 1 }
  ref.afterSlide = { _ in callbacks += 1 }
  let removal = object([("type", .number(1)), ("pos1", .number(0)), ("pos2", .number(2))])
  try client.process(removal, sender: "B", sequence: 2, referenceSequence: 1)
  _ = try client.regeneratePendingOps()
  _ = try client.regeneratePendingOps()
  #expect(callbacks == 2)
}
