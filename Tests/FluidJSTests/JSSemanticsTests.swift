import FluidJS
import Foundation
import Testing

/// Golden vectors produced by Node (`npm run fixtures` in harness/): FluidJS must match
/// `JSON.stringify` / `JSON.parse` exactly.
struct JSSemanticsTests {
    let fixture: JSONValue

    init() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("harness/fixtures/js-semantics.json")
        fixture = try JSON.parse(String(contentsOf: url, encoding: .utf8))
    }

    private func cases(_ name: JSString) throws -> [JSONValue] {
        try fixture.member(name).asArray()
    }

    private func double(_ hex: JSONValue) throws -> Double {
        Double(bitPattern: UInt64(try hex.asString().description, radix: 16)!)
    }

    @Test func stringifyNumbers() throws {
        let cases = try cases("stringifyNumbers")
        #expect(!cases.isEmpty)
        for testCase in cases {
            let bits = try testCase.member("bits").asString().description
            let expected = try testCase.member("json").asString().description
            #expect(JSON.stringify(.number(try double(testCase.member("bits")))) == expected, "bits \(bits)")
        }
    }

    @Test func parseNumbers() throws {
        let cases = try cases("parseNumbers")
        #expect(!cases.isEmpty)
        for testCase in cases {
            let text = try testCase.member("json").asString().description
            let parsed = try JSON.parse(text).asNumber()
            let expected = try double(testCase.member("bits"))
            #expect(parsed.bitPattern == expected.bitPattern, "text \(text)")
        }
    }

    @Test func strings() throws {
        let cases = try cases("strings")
        #expect(!cases.isEmpty)
        for testCase in cases {
            let units = ContiguousArray(try testCase.member("utf16").asArray().map { UInt16(try $0.asInt()) })
            let json = try testCase.member("json").asString().description
            #expect(JSON.stringify(.string(JSString(utf16: units))) == json, "utf16 \(Array(units))")
            let parsed = try JSON.parse(json).asString()
            #expect(parsed.utf16 == units, "json \(json)")
        }
    }

    @Test func objects() throws {
        let cases = try cases("objects")
        #expect(!cases.isEmpty)
        for testCase in cases {
            var object = JSObject<JSONValue>()
            let keys = try testCase.member("insertionOrder").asArray().map { try $0.asString() }
            for (index, key) in keys.enumerated() {
                object[key] = .number(Double(index))
            }
            let json = try testCase.member("json").asString().description
            #expect(JSON.stringify(.object(object)) == json, "keys \(keys)")
            let reparsed = try JSON.parse(json)
            #expect(JSON.stringify(reparsed) == json)
        }
    }
}
