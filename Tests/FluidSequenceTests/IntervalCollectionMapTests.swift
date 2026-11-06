import Testing
import FluidJS
import FluidMergeTree
@testable import FluidSequence

struct IntervalCollectionMapTests {
  @Test func lazyCreationAndEmptySummary() {
    let map = IntervalCollectionMap(client: Client(id: "A", collaborating: false))
    var labels: [JSString] = []
    map.created = { labels.append($0.label) }
    let first = map.get("comments")
    #expect(first === map.get("comments"))
    _ = map.get("0")
    #expect(labels == ["comments", "0"])
    #expect(map.labels == labels)
    #expect(JSON.stringify(map.serialize()) == "{\"0\":{\"type\":\"sharedStringIntervalCollection\",\"value\":{\"label\":\"0\",\"intervals\":[],\"version\":2}},\"comments\":{\"type\":\"sharedStringIntervalCollection\",\"value\":{\"label\":\"comments\",\"intervals\":[],\"version\":2}}}")
  }

  @Test func compressedRoundtrip() throws {
    let client = Client(id: "A", collaborating: false)
    _ = try client.insert(at: 0, text: "abcdef")
    let map = IntervalCollectionMap(client: client)
    _ = try map.get("comments").add(id: "i", start: 1, end: 3)
    let summary = map.serialize()
    let loaded = IntervalCollectionMap(client: client)
    try loaded.populate(summary)
    #expect(loaded.serialize() == summary)
  }
}

extension IntervalCollectionMapTests {
  @Test func legacyIdentityAndMissingPropertiesLoad() throws {
    let client = Client(id: "A", collaborating: false)
    _ = try client.insert(at: 0, text: "abcd")
    let map = IntervalCollectionMap(client: client)
    try map.populate(JSON.parse("{\"intervalCollections/comments\":{\"type\":\"sharedStringIntervalCollection\",\"value\":[{\"start\":1,\"end\":2,\"intervalType\":2,\"sequenceNumber\":0}]}}"))
    let interval = try #require(map.get("comments").getIntervalById("legacy1-2"))
    #expect(interval.properties.isEmpty)
  }
}
