import FluidJS
import FluidMap
import Testing

/// map.ts events are Node EventEmitter events: any number of listeners, in registration order.
struct MapEventTests {
  @Test func everyValueChangedListenerRuns() throws {
    let map = SharedMap(id: "map")
    var order: [String] = []
    map.valueChanged.on { changed, local in order.append("first \(changed.key) \(local)") }
    let second = map.valueChanged.on { changed, _ in order.append("second \(changed.key)") }
    try map.set("a", .number(1))
    map.valueChanged.off(second)
    try map.set("b", .number(2))
    #expect(order == ["first a true", "second a", "first b true"])
  }

  /// A clear emits "clear", then "valueChanged" for every key it deleted.
  @Test func everyClearListenerRunsBeforeValueChanged() throws {
    let map = SharedMap(id: "map")
    try map.set("a", .number(1))
    var order: [String] = []
    map.clearEvent.on { local in order.append("clear 1 \(local)") }
    map.clearEvent.on { _ in order.append("clear 2") }
    map.valueChanged.on { changed, _ in order.append("valueChanged \(changed.key)") }
    try map.clear()
    #expect(order == ["clear 1 true", "clear 2", "valueChanged a"])
  }
}
