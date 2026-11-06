import Testing
import FluidJS
import FluidMergeTree
@testable import FluidSequence

struct SidedIntervalTests {
  @Test func fullStickinessAndSentinelsSerialize() throws {
    let client = Client(id: "A", collaborating: false)
    _ = try client.insert(at: 0, text: "abc")
    let interval = try SequenceInterval(client: client, id: "i", label: "c",
      start: SequencePlace.start, end: SequencePlace.end)
    #expect(interval.startSide == .before)
    #expect(interval.stickiness == 3)
    #expect(try interval.serialize().member("start") == .string("start"))
    #expect(try interval.serialize().member("end") == .string("end"))
    _ = try client.insert(at: 3, text: "more")
    #expect(client.localReferencePositionToPosition(interval.end) == 7)
  }

  @Test func sidesControlSlidingAndSurviveClone() throws {
    let client = Client(id: "A", collaborating: false)
    _ = try client.insert(at: 0, text: "abcd")
    let interval = try SequenceInterval(client: client, id: "i", label: "c",
      start: SequencePlace(1, side: .after), end: SequencePlace(2, side: .after))
    #expect(interval.stickiness == 1)
    #expect(interval.start.slidingPreference == .backward)
    #expect(interval.end.slidingPreference == .backward)
    #expect(interval.clone().startSide == .after)
    _ = try client.remove(start: 1, end: 3)
    #expect(client.localReferencePositionToPosition(interval.start) == 0)
    #expect(client.localReferencePositionToPosition(interval.end) == 0)
  }

  @Test func compressedAndLegacySummaryRetainStickiness() throws {
    let client = Client(id: "A", collaborating: false)
    _ = try client.insert(at: 0, text: "abc")
    let map = IntervalCollectionMap(client: client)
    map.intervalStickinessEnabled = true
    _ = try map.get("c").add(id: "i", start: SequencePlace.start, end: SequencePlace.end)
    for version in [IntervalSerializationFormat.v1, .v2] {
      let saved = map.serialize(version: version)
      let loaded = IntervalCollectionMap(client: client)
      try loaded.populate(saved)
      #expect(loaded.get("c").getIntervalById("i")?.startSide == .before)
      #expect(loaded.serialize(version: version) == saved)
    }
  }
}
