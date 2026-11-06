import Foundation
import Testing
import FluidJS
import FluidMergeTree
import FluidDriverDefinitions
@testable import FluidSequence

struct SequenceSummaryFixtureTests {
  @Test func upstreamSummaryBytesAndReload() throws {
    let url = try #require(Bundle.module.url(forResource: "summaries", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    for fixture in fixtures {
      let scenario = try fixture.member("scenario").asString()
      let v1 = try fixture.member("v1") == .bool(true)
      let version: IntervalSerializationFormat = try fixture.member("intervalFormat") == .string("1") ? .v1 : .v2
      let text = SharedString(id: "text")
      text.newMergeTreeSnapshotFormat = v1
      text.intervalSerializationFormat = version
      text.intervalStickinessEnabled = true
      text.referencesCanSlideToEndpoint = true
      switch scenario {
      case "empty": break
      case "unicode":
        var props = JSObject<JSONValue>()
        props["color"] = .string("red")
        props["absent"] = .null
        try text.insertText(0, "A😀B", properties: props)
        try text.removeRange(1, 2)
        var marker = JSObject<JSONValue>()
        marker["referenceTileLabels"] = .array([.string("paragraph")])
        try text.insertMarker(1, refType: 1, properties: marker)
      case "chunks":
        for block in 0..<5 {
          var props = JSObject<JSONValue>()
          props["block"] = .number(Double(block))
          try text.insertText(text.getLength(), JSString(String(repeating: String(block), count: 6000)), properties: props)
        }
      case "intervals":
        try text.insertText(0, "abcdefgh")
        var props = JSObject<JSONValue>()
        props["color"] = .string("red")
        let collection = text.getIntervalCollection("comments")
        try collection.add(id: "whole", start: SequencePlace.start, end: SequencePlace.end, properties: props)
        try collection.add(id: "none", start: SequencePlace(2, side: .before), end: SequencePlace(5, side: .after))
        _ = text.getIntervalCollection("0")
      default: Issue.record("unknown fixture scenario")
      }
      let expected = try SummaryTree(json: fixture.member("summary"))
      #expect(try text.summarizeSequence() == expected, Comment(rawValue: "\(scenario), v1=\(v1), intervals=\(version)"))
      let loaded = try SharedString.load(id: "loaded", summary: expected)
      loaded.intervalSerializationFormat = version
      let expectedText = try fixture.member("text")
      #expect(JSONValue.array(loaded.getText().utf16.map { .number(Double($0)) }) == expectedText)
      #expect(try loaded.summarizeSequence() == expected, Comment(rawValue: "reload \(scenario), v1=\(v1), intervals=\(version)"))
    }
  }
}
