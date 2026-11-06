import FluidJS
import Testing

/// Seeded random edits against a plain insertion-order list, checked after every edit. Key pools
/// are small so keys are overwritten, deleted and re-added, objects cross the indexed-lookup size
/// and JSMap compacts its deleted slots.
struct OrderedCollectionTests {
    /// The same UInt32 LCG the benchmarks use.
    struct Random {
        var state: UInt32
        mutating func next(_ bound: Int) -> Int {
            state = state &* 1664525 &+ 1013904223
            return Int(state >> 8) % bound
        }
    }

    /// `Object.keys` order of keys listed in insertion order: canonical array indices ascending,
    /// then the other keys as inserted.
    func objectKeysOrder(_ insertionOrder: [JSString]) -> [JSString] {
        func index(_ key: JSString) -> UInt64? {
            let text = key.description
            guard let value = UInt64(text), String(value) == text, value <= 4_294_967_294 else { return nil }
            return value
        }
        let indices = insertionOrder.filter { index($0) != nil }.sorted { index($0)! < index($1)! }
        return indices + insertionOrder.filter { index($0) == nil }
    }

    @Test(arguments: [1, 2, 3, 4, 5])
    func objectMatchesModel(seed: UInt32) {
        var random = Random(state: seed)
        let pool: [JSString] = (0..<48).map { $0 % 3 == 0 ? JSString("\($0)") : JSString("key\($0)") } + ["01", "4294967295", ""]
        var object = JSObject<Double>()
        var model: [(key: JSString, value: Double)] = []
        for step in 0..<4000 {
            let key = pool[random.next(pool.count)]
            if random.next(3) == 0 {
                object[key] = nil
                model.removeAll { $0.key == key }
            } else {
                object[key] = Double(step)
                if let position = model.firstIndex(where: { $0.key == key }) {
                    model[position].value = Double(step)
                } else {
                    model.append((key, Double(step)))
                }
            }
            let keys = objectKeysOrder(model.map(\.key))
            #expect(object.keys == keys)
            #expect(object.count == model.count)
            #expect(object.orderedEntries.map(\.value) == keys.map { key in model.first { $0.key == key }!.value })
            #expect(pool.allSatisfy { key in object[key] == model.first { $0.key == key }?.value })
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5])
    func mapMatchesModel(seed: UInt32) {
        var random = Random(state: seed)
        var map = JSMap<Int, Int>()
        var model: [(key: Int, value: Int)] = []
        for step in 0..<4000 {
            let key = random.next(64)
            switch random.next(20) {
            case 0:
                map.clear()
                model.removeAll()
            case 1...9:
                let present = model.contains { $0.key == key }
                #expect(map.delete(key) == present)
                model.removeAll { $0.key == key }
            default:
                map.set(key, step)
                if let position = model.firstIndex(where: { $0.key == key }) {
                    model[position].value = step
                } else {
                    model.append((key, step))
                }
            }
            #expect(map.keys == model.map(\.key))
            #expect(map.entries.map(\.value) == model.map(\.value))
            #expect(map.size == model.count)
            #expect(map.has(key) == model.contains { $0.key == key })
            #expect(map.get(key) == model.first { $0.key == key }?.value)
        }
    }
}
