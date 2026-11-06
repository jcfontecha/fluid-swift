import FluidJS
import Testing

@testable import FluidMergeTree

@Test func baselineV1SnapshotIsByteExact() throws {
  let c = MergeTreeClient(id: "A")
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
  let c = MergeTreeClient(id: "A")
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
