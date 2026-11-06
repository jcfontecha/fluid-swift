import FluidJS
import FluidMap
import Testing

@Test func undefinedIsPresentAndSurvivesSummary() throws {
  let map = SharedMap(id: "map")
  try map.set("undefined", nil)
  try map.set("null", .null)
  #expect(map.has("undefined"))
  #expect(map.get("undefined") == nil)
  #expect(map.get("null") == .null)
  let loaded = try SharedMap.load(id: "loaded", summary: map.summarize())
  #expect(loaded.has("undefined"))
  #expect(loaded.get("undefined") == nil)
  #expect(loaded.get("null") == .null)
}
