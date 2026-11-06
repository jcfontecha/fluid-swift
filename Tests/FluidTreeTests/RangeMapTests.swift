import Foundation
import FluidJS
import Testing
@testable import FluidTree

@Test func rangeMapSplitsOffsetsAndPreservesClonedEntries() {
    let map = RangeMap<Int, Int>(offsetKey: +, subtractKeys: { Double($0 - $1) }, offsetValue: +)
    map.set(10, count: 10, value: 100)
    let clone = map.clone()
    #expect(map.delete(12, count: 4) == 4)
    #expect(map.getFirst(16, count: 10).value == 106)
    #expect(map.getFirst(10, count: 10).length == 2)
    #expect(map.getFirst(12, count: 10).length == 4)
    #expect(clone.getFirst(12, count: 10).value == 102)
    #expect(clone.getFirst(12, count: 10).length == 8)
}

@Test func rangeMapMatchesThousandTypeScriptStructuralScenarios() throws {
    let url = try #require(Bundle.module.url(forResource: "range-map", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    let context = BTreeStorageContext()
    for fixture in fixtures {
        let map = RangeMap<Int, Int>(offsetKey: +, subtractKeys: { Double($0 - $1) }, offsetValue: +, context: context)
        func structure(_ map: RangeMap<Int, Int>) -> JSONValue {
            map.structure(key: { .number(Double($0)) }, value: { .number(Double($0)) })
        }
        #expect(try structure(map) == fixture.member("initial"))
        for operation in try fixture.member("setup").asArray() {
            try map.set(operation.member("start").asInt(), count: operation.member("count").asInt(), value: operation.member("value").asInt())
        }
        let clone = map.clone()
        var results: [JSONValue] = []
        for operation in try fixture.member("operations").asArray() {
            if try operation.member("remove") == .bool(true) {
                results.append(.number(Double(try clone.delete(operation.member("start").asInt(), count: operation.member("count").asInt()))))
            } else {
                try clone.set(operation.member("start").asInt(), count: operation.member("count").asInt(), value: operation.member("value").asInt())
                results.append(.null)
            }
        }
        #expect(try JSONValue.array(results) == fixture.member("results"))
        let queries = try fixture.member("queries").asArray().map { query in
            let result = try clone.getFirst(query.member("start").asInt(), count: query.member("count").asInt())
            return JSONValue.array([result.value.map { .number(Double($0)) } ?? .null, .number(Double(result.length))])
        }
        #expect(try JSONValue.array(queries) == fixture.member("output"))
        #expect(try structure(map) == fixture.member("original"))
        #expect(try structure(clone) == fixture.member("changed"))
    }
}

@Test func rangeMapUnionSplitsIntersectionsAndOffsetsValues() throws {
    let first = RangeMap<Int, Int>(offsetKey: +, subtractKeys: { Double($0 - $1) }, offsetValue: +)
    let second = RangeMap<Int, Int>(offsetKey: +, subtractKeys: { Double($0 - $1) }, offsetValue: +)
    first.set(0, count: 10, value: 10)
    second.set(3, count: 10, value: 20)
    let merged = try RangeMap.union(first, second)
    #expect(merged.getFirst(0, count: 20).length == 3)
    #expect(merged.getFirst(4, count: 20).value == 21)
    #expect(merged.getFirst(10, count: 20).value == 27)
    #expect(first.getFirst(4, count: 1).value == 14)
}

@Test func rangeMapUnionMatchesThousandTypeScriptStructuralScenarios() throws {
    let url = try #require(Bundle.module.url(forResource: "range-union", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    let context = BTreeStorageContext()
    for fixture in fixtures {
        let first = RangeMap<Int, Int>(offsetKey: +, subtractKeys: { Double($0 - $1) }, offsetValue: +, context: context)
        let second = RangeMap<Int, Int>(offsetKey: +, subtractKeys: { Double($0 - $1) }, offsetValue: +, context: context)
        for (key, map) in [(JSString("left"), first), (JSString("right"), second)] {
            for operation in try fixture.member(key).asArray() {
                try map.set(operation.member("start").asInt(), count: operation.member("count").asInt(), value: operation.member("value").asInt())
            }
        }
        let merged = try RangeMap.union(first, second)
        func structure(_ map: RangeMap<Int, Int>) -> JSONValue { map.structure(key: { .number(Double($0)) }, value: { .number(Double($0)) }) }
        #expect(try structure(first) == fixture.member("first"))
        #expect(try structure(second) == fixture.member("second"))
        #expect(try structure(merged) == fixture.member("result"))
    }
}
