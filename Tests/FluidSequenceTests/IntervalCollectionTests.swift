import Testing
import FluidJS
import FluidMergeTree
@testable import FluidSequence

struct IntervalCollectionTests {
  @Test func mutationOrderAndSummary() throws {
    let client = Client(id: "A", collaborating: false)
    _ = try client.insert(at: 0, text: "abcdef")
    let collection = IntervalCollection(client: client, label: "comments")
    var names: [JSString] = []
    collection.event = { names.append($0.name) }
    var props = JSObject<JSONValue>()
    props["color"] = .string("red")
    _ = try collection.add(id: "i", start: 1, end: 3, properties: props)
    #expect(JSON.stringify(collection.serialize()) == "{\"label\":\"comments\",\"intervals\":[[1,3,0,2,{\"color\":\"red\",\"intervalId\":\"i\"}]],\"version\":2}")
    props["color"] = .string("blue")
    _ = try collection.change("i", start: 2, end: 4, properties: props)
    #expect(names == ["addInterval", "propertyChanged", "changed", "changeInterval", "changed"])
    _ = try collection.removeIntervalById("i")
    #expect(collection.getIntervalById("i") == nil)
    #expect(names.last == "deleteInterval")
  }

  @Test func slidingReindexesAndReportsChanges() throws {
    let client = Client(id: "A", collaborating: false)
    _ = try client.insert(at: 0, text: "abcdef")
    let collection = IntervalCollection(client: client, label: "c")
    _ = try collection.add(id: "i", start: 1, end: 3)
    var slides = 0
    collection.event = { if $0.name == "changeInterval" && $0.slide { slides += 1 } }
    _ = try client.remove(start: 1, end: 4)
    #expect(slides > 0)
    let interval = try #require(collection.getIntervalById("i"))
    #expect(client.localReferencePositionToPosition(interval.start) == 1)
    #expect(client.localReferencePositionToPosition(interval.end) == 1)
  }
}
