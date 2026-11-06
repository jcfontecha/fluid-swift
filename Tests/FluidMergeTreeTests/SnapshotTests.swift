import FluidJS
import Testing

@testable import FluidMergeTree

@Test func baselineV1SnapshotIsByteExact() throws {
  let c = Client(id: "A")
  let op = try c.insert(at: 0, text: "abc")
  try c.process(op, sender: "A", sequence: 1, referenceSequence: 0)
  try c.advanceMinimum(to: 1)
  let summary = try c.snapshot(version: "v1")
  let blob = try summary.member("tree").member("header").member("content").asString()
  #expect(
    blob.description
      == #"{"version":"1","segmentCount":1,"length":3,"segments":["abc"],"startIndex":0,"headerMetadata":{"minSequenceNumber":1,"sequenceNumber":1,"orderedChunkMetadata":[{"id":"header"}],"totalLength":3,"totalSegmentCount":1}}"#
  )
}
@Test func retainedRemovalSnapshotPreservesProvenance() throws {
  let c = Client(id: "A")
  let insert = try c.insert(at: 0, text: "x")
  try c.process(insert, sender: "A", sequence: 1, referenceSequence: 0)
  let remove = try c.remove(start: 0, end: 1)
  try c.process(remove, sender: "A", sequence: 2, referenceSequence: 1)
  let snapshot = try c.snapshot(version: "v1")
  let blob = try snapshot.member("tree").member("header").member("content").asString()
  let chunk = try JSON.parse(blob.description)
  #expect(try chunk.member("length").asInt() == 1)
  let segments = try chunk.member("segments").asArray()
  #expect(try segments[0].member("removedClient").asString() == "A")
  #expect(try segments[0].member("removedSeq").asInt() == 2)
}

@Test func snapshotReadersRoundTripLegacyAndV1() throws {
  let original = Client(id: "A")
  let insert = try original.insert(at: 0, text: "abc")
  try original.process(insert, sender: "A", sequence: 1, referenceSequence: 0)
  try original.advanceMinimum(to: 1)
  for version: JSString in ["legacy", "v1"] {
    let summary = try original.snapshot(version: version)
    let loaded = try SnapshotLoader().load(summary, id: "B")
    #expect(loaded.text == "abc")
    #expect(loaded.currentSequence == 1)
    #expect(loaded.minimumSequence == 1)
    #expect(try loaded.snapshot(version: version) == summary)
  }
}

@Test func legacyCatchupReplaysGroupedOperationsWithoutLocalAcknowledgement() throws {
  let client = Client(id: "A")
  let message = object([
    ("clientId", .string("A")), ("sequenceNumber", .number(1)),
    ("referenceSequenceNumber", .number(0)), ("minimumSequenceNumber", .number(0)),
    (
      "contents",
      object([
        ("type", .number(3)),
        (
          "ops",
          .array([
            object([("type", .number(0)), ("pos1", .number(0)), ("seg", .string("a"))]),
            object([("type", .number(0)), ("pos1", .number(1)), ("seg", .string("b"))]),
          ])
        ),
      ])
    ),
  ])
  let summary = try client.snapshot(version: "legacy", catchup: [message])
  let loaded = try SnapshotLoader().load(summary, id: "A")
  #expect(loaded.text == "ab")
  #expect(loaded.currentSequence == 1)
}
