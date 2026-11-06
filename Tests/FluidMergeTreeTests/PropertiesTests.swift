import FluidJS
import XCTest

@testable import FluidMergeTree

final class PropertiesTests: XCTestCase {
  func testPendingAnnotationMasksRemoteAndSurvivesSplit() throws {
    let client = Client(id: "A")
    let insert = try client.insert(at: 0, text: "abcd")
    try client.process(insert, sender: "A", sequence: 1, referenceSequence: 0)
    let local = object([
      ("type", .number(2)), ("pos1", .number(0)), ("pos2", .number(4)),
      ("props", object([("color", .string("red"))])),
    ])
    _ = try client.edit(local)
    let remote = object([
      ("type", .number(2)), ("pos1", .number(1)), ("pos2", .number(3)),
      ("props", object([("color", .string("blue"))])),
    ])
    try client.process(remote, sender: "B", sequence: 2, referenceSequence: 1)
    XCTAssertEqual(client.segments.count, 3)
    XCTAssertTrue(client.segments.allSatisfy { $0.properties?["color"] == .string("red") })
    try client.process(local, sender: "A", sequence: 3, referenceSequence: 1)
    try client.process(remote, sender: "B", sequence: 4, referenceSequence: 3)
    XCTAssertEqual(client.segments[1].properties?["color"], .string("blue"))
    let deletion = object([
      ("type", .number(2)), ("pos1", .number(0)), ("pos2", .number(4)),
      ("props", object([("color", .null)])),
    ])
    _ = try client.edit(deletion)
    XCTAssertTrue(client.segments.allSatisfy { $0.properties?.isEmpty == true })
  }
  func testV1NormalizesLiveEmptyPropertiesButLegacyDoesNot() throws {
    let client = Client(id: "A")
    let insert = try client.insert(at: 0, text: "x")
    try client.process(insert, sender: "A", sequence: 1, referenceSequence: 0)
    let annotation = object([
      ("type", .number(2)), ("pos1", .number(0)), ("pos2", .number(1)),
      ("props", object([("color", .null)])),
    ])
    _ = try client.edit(annotation)
    XCTAssertEqual(client.segments[0].properties?.isEmpty, true)
    _ = try client.snapshot(version: "legacy")
    XCTAssertEqual(client.segments[0].properties?.isEmpty, true)
    _ = try client.snapshot(version: "v1")
    XCTAssertNil(client.segments[0].properties)
  }

}
