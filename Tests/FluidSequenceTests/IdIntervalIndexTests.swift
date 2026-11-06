import Testing
import FluidMergeTree
@testable import FluidSequence

struct IdIntervalIndexTests {
  @Test func mapOrderAndReplacement() throws {
    let client = Client(id: "A")
    try client.insert(at: 0, text: "abcdef")
    let index = IdIntervalIndex()
    let first = try SequenceInterval(client: client, id: "10", label: "a", start: 0, end: 1)
    let second = try SequenceInterval(client: client, id: "0", label: "a", start: 2, end: 3)
    let replacement = try SequenceInterval(client: client, id: "10", label: "a", start: 4, end: 5)
    index.add(first)
    index.add(second)
    index.add(replacement)
    #expect(Array(index).map(\.id) == ["10", "0"])
    #expect(index.getIntervalById("10") === replacement)
    index.remove(first)
    #expect(index.getIntervalById("10") == nil)
    index.add(first)
    #expect(Array(index).map(\.id) == ["0", "10"])
  }
}
