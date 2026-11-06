import Testing
import FluidJS
import FluidDriverDefinitions
@testable import FluidSequence

struct SequenceSummaryTests {
  @Test func emptyLegacyHeaderIsByteExact() throws {
    let text = SharedString(id: "channel")
    let content = try text.summarizeSequence().json.member("tree").member("content").member("tree").member("header").member("content").asString()
    #expect(content == "{\"chunkStartSegmentIndex\":0,\"chunkSegmentCount\":0,\"chunkLengthChars\":0,\"totalLengthChars\":0,\"totalSegmentCount\":0,\"chunkSequenceNumber\":0,\"segmentTexts\":[],\"headerMetadata\":{\"orderedChunkMetadata\":[{\"id\":\"header\"}],\"sequenceNumber\":0,\"totalLength\":0,\"totalSegmentCount\":0}}")
  }

  @Test(arguments: [false, true]) func detachedRoundtrip(v1: Bool) throws {
    let text = SharedString(id: "channel")
    text.newMergeTreeSnapshotFormat = v1
    try text.insertText(0, "A😀B")
    try text.removeRange(1, 2)
    let summary = try text.summarizeSequence()
    let loaded = try SharedString.load(id: "loaded", summary: summary)
    #expect(loaded.getText() == text.getText())
    #expect(loaded.newMergeTreeSnapshotFormat == v1)
    #expect(try loaded.summarizeSequence() == summary)
  }
}

extension SequenceSummaryTests {
  @Test(arguments: [false, true]) func equalPropertiesMergeRegardlessOfKeyOrder(v1: Bool) throws {
    let text = SharedString(id: "channel")
    text.newMergeTreeSnapshotFormat = v1
    var first = JSObject<JSONValue>()
    first["a"] = .number(1)
    first["b"] = .number(2)
    var second = JSObject<JSONValue>()
    second["b"] = .number(2)
    second["a"] = .number(1)
    try text.insertText(0, "x", properties: first)
    try text.insertText(1, "y", properties: second)
    let header = try JSON.parse(text.summarizeSequence().json.member("tree").member("content").member("tree").member("header").member("content").asString().description)
    #expect(try header.member(v1 ? "segmentCount" : "chunkSegmentCount").asInt() == 1)
  }
}
