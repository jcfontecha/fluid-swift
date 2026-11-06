import FluidJS
import FluidMap
import Testing

@testable import Fluid

private struct Item: Codable, Equatable {
    var text: String
    var done: Bool
}

@MainActor
struct SharedMapTests {
    @Test func worksLikeADictionary() throws {
        let items = Fluid.SharedMap<Item>.kind.make("map")
        items["milk"] = Item(text: "Milk", done: false)
        items["eggs"] = Item(text: "Eggs", done: false)
        items["milk"]?.done = true
        #expect(items["milk"] == Item(text: "Milk", done: true))
        #expect(items.keys == ["milk", "eggs"])
        items["milk"] = nil
        #expect(items["milk"] == nil)
        #expect(items.keys == ["eggs"])
        items.removeAll()
        #expect(items.keys.isEmpty)
    }

    /// Values travel as JSON a TS client reads: numbers are JS numbers, properties in order.
    @Test func valuesAreStoredAsTSReadableJSON() throws {
        let port = FluidMap.SharedMap(id: "map")
        let items = try #require(Fluid.SharedMap<Item>.kind.adopt(port))
        items["a"] = Item(text: "Milk", done: true)
        #expect(JSON.stringify(try #require(port.get("a"))) == #"{"text":"Milk","done":true}"#)
        let counts = try #require(Fluid.SharedMap<Int>.kind.adopt(port))
        counts["n"] = 3
        #expect(port.get("n") == .number(3))
    }

    @Test func remoteWritesConverge() throws {
        let maps = try TwoMaps<Item>()
        maps.a["milk"] = Item(text: "Milk", done: false)
        try maps.sync()
        maps.b["milk"]?.done = true
        try maps.sync()
        #expect(maps.a["milk"] == Item(text: "Milk", done: true))
    }

    /// A reader of one key is not notified for writes to another (per-key tracking).
    @Test func observationIsPerKey() throws {
        let maps = try TwoMaps<Int>()
        let a = ChangeCounter { _ = maps.b["a"] }
        let b = ChangeCounter { _ = maps.b["b"] }
        maps.a["a"] = 1
        try maps.sync()
        maps.a["a"] = 2
        try maps.sync()
        #expect(a.count == 2)
        #expect(b.count == 0)
    }

    /// `keys` changes when a key is added or deleted, not when a value is overwritten.
    @Test func keysAreObservedOnlyWhenTheKeySetChanges() throws {
        let items = Fluid.SharedMap<Int>.kind.make("map")
        let keys = ChangeCounter { _ = items.keys }
        items["a"] = 1
        items["a"] = 2
        items["b"] = 3
        items["a"] = nil
        #expect(keys.count == 3)
    }

    @Test func removeAllNotifiesEveryKeyReader() throws {
        let items = Fluid.SharedMap<Int>.kind.make("map")
        items["a"] = 1
        items["b"] = 2
        let a = ChangeCounter { _ = items["a"] }
        let keys = ChangeCounter { _ = items.keys }
        items.removeAll()
        #expect(a.count == 1)
        #expect(keys.count == 2)
        #expect(items.keys.isEmpty)
    }

    /// Several native maps over one channel each get every change: listeners do not replace each other.
    @Test func severalViewsOfOneChannelAllObserve() throws {
        let port = FluidMap.SharedMap(id: "map")
        let first = try #require(Fluid.SharedMap<Int>.kind.adopt(port))
        let second = try #require(Fluid.SharedMap<Int>.kind.adopt(port))
        let one = ChangeCounter { _ = first["k"] }
        let two = ChangeCounter { _ = second["k"] }
        first["k"] = 1
        #expect(one.count == 1)
        #expect(two.count == 1)
    }
}
