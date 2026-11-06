import Foundation
import Testing
import FluidJS
@testable import FluidTree

@Test func btreeCloneIsolatedThroughSplitMergeAndOverwrite() throws {
    let tree = BTree<Int, Int>(compare: { $0 < $1 ? -1 : $0 > $1 ? 1 : 0 })
    for key in 0..<100 { tree.set(key, key * 2) }
    let clone = tree.clone()
    for key in 10..<90 { clone.delete(key) }
    clone.set(0, 99)
    #expect(tree.count == 100)
    #expect(clone.count == 20)
    #expect(tree.get(0) == 0)
    #expect(clone.get(0) == 99)
    #expect(clone.getPairOrNextHigher(10)?.0 == 90)
    #expect(clone.getPairOrNextLower(89)?.0 == 9)
    #expect(tree.entries.map(\.0) == Array(0..<100))
}

@Test func btreeEmptySharedRootProjectsUndefinedPool() throws {
    let context = BTreeStorageContext()
    let empty = BTree<Int, Int>(context: context, compare: { $0 - $1 })
    let other = BTree<Int, Int>(context: context, compare: { $0 - $1 })
    other.set(1, 2)
    let projected = empty.structure(key: { .number(Double($0)) }, value: { .number(Double($0)) })
    let object = try projected.asArray()[1].asArray()
    let root = try object[0].asArray()[1].asArray()[1].asArray()
    #expect(try root[1].asArray()[1].asArray()[1].asArray().count == 32)
    #expect(try root[2].asArray()[1] == .bool(true))
}

@Test func btreeMatchesThousandTypeScriptMutationAndCloneScenarios() throws {
    let url = try #require(Bundle.module.url(forResource: "btree", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    let context = BTreeStorageContext()
    for fixture in fixtures {
        let tree = BTree<Int, Int>(context: context, compare: { $0 - $1 })
        func structure(_ tree: BTree<Int, Int>) -> JSONValue {
            tree.structure(key: { .number(Double($0)) }, value: { .number(Double($0)) })
        }
        #expect(try structure(tree) == fixture.member("initial"))
        for key in try fixture.member("initialKeys").asArray() {
            let key = try key.asInt()
            tree.set(key, key * 3)
        }
        var clone = tree.clone()
        var results: [JSONValue] = []
        for operation in try fixture.member("operations").asArray() {
            switch try operation.member("kind").asString() {
            case "set":
                let result = try clone.set(operation.member("key").asInt(), operation.member("value").asInt(), overwrite: operation.member("overwrite") == .bool(true))
                results.append(.bool(result))
            case "delete":
                results.append(.bool(try clone.delete(operation.member("key").asInt())))
            case "deleteRange":
                results.append(.number(Double(try clone.editRange(operation.member("low").asInt(), operation.member("high").asInt()) { _, _ in .delete })))
            case "map":
                clone = clone.mapValues { value, _ in value.map { $0 + 1 } }
                results.append(.number(Double(clone.count)))
            default: throw JSONDecodingError("unknown BTree fixture operation")
            }
        }
        #expect(try JSONValue.array(results) == fixture.member("results"))
        #expect(try structure(tree) == fixture.member("original"))
        #expect(try structure(clone) == fixture.member("changed"))
        let entries = clone.entries.map { key, value in JSONValue.array([.number(Double(key)), value.map { .number(Double($0)) } ?? .null]) }
        #expect(try JSONValue.array(entries) == fixture.member("entries"))
    }
}

@Test func btreeUndefinedPoolMappingMatchesPinnedDependency() {
    let tree = BTree<Int, Int>(compare: { $0 - $1 })
    tree.set(1, nil)
    tree.set(2, nil)
    let mapped = tree.mapValues { _, key in key * 3 }
    // Pinned TS maps into shared undefVals, so even the original observes this.
    #expect(tree.get(1) == 3)
    #expect(tree.get(2) == 6)
    #expect(mapped.get(1) == 3)
    #expect(mapped.get(2) == 6)
}

@Test func btreeUnionMergesCollisionsWithoutMutatingInputs() throws {
    let context = BTreeStorageContext()
    let left = BTree<Int, Int>(context: context, compare: { $0 - $1 })
    let right = BTree<Int, Int>(context: context, compare: { $0 - $1 })
    for key in 0..<80 { left.set(key, key) }
    for key in 40..<120 { right.set(key, key * 2) }
    let result = try BTree.union(left, right) { _, a, b in try #require(a) + #require(b) }
    #expect(result.count == 120)
    #expect(result.get(50) == 150)
    #expect(left.get(50) == 50)
    #expect(right.get(50) == 100)
}

@Test func btreeUnionMatchesThousandTypeScriptStructuralScenarios() throws {
    let url = try #require(Bundle.module.url(forResource: "btree-union", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSON.parse(String(contentsOf: url, encoding: .utf8)).asArray()
    #expect(fixtures.count == 1000)
    let context = BTreeStorageContext()
    var wroteMismatch = false
    for (seed, fixture) in fixtures.enumerated() {
        let size = try fixture.member("maxNodeSize").asInt()
        let left = BTree<Int, Int>(maxNodeSize: size, context: context, compare: { $0 - $1 })
        for value in try fixture.member("leftKeys").asArray() {
            let key = try value.asInt()
            left.set(key, key + 1)
        }
        let right: BTree<Int, Int>
        if try fixture.member("same") == .bool(true) { right = left }
        else if try fixture.member("cloneRight") == .bool(true) { right = left.clone() }
        else {
            right = BTree<Int, Int>(maxNodeSize: size, context: context, compare: { $0 - $1 })
            for value in try fixture.member("rightKeys").asArray() {
                let key = try value.asInt()
                right.set(key, key * 2 + 1)
            }
        }
        let merged = try BTree.union(left, right) { _, a, b in try #require(a) + #require(b) }
        func structure(_ tree: BTree<Int, Int>) -> JSONValue { tree.structure(key: { .number(Double($0)) }, value: { .number(Double($0)) }) }
        #expect(try structure(left) == fixture.member("left"))
        #expect(try structure(right) == fixture.member("right"))
        let actual = structure(merged)
        let expected = try fixture.member("result")
        if actual != expected && !wroteMismatch {
            var evidence = JSObject<JSONValue>()
            evidence["seed"] = .number(Double(seed))
            evidence["actual"] = actual
            evidence["expected"] = expected
            try JSON.stringify(.object(evidence)).write(toFile: "/tmp/t1-union-mismatch.json", atomically: true, encoding: .utf8)
            wroteMismatch = true
        }
        #expect(actual == expected)
        let entries = merged.entries.map { key, value in JSONValue.array([.number(Double(key)), value.map { .number(Double($0)) } ?? .null]) }
        #expect(try JSONValue.array(entries) == fixture.member("entries"))
    }
}
