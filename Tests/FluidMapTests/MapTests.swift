import FluidDriverDefinitions
import FluidJS
import FluidMap
import FluidTestRuntimeUtils
import Testing

@Test func mapPendingClearAndRollback() throws {
  let map = SharedMap(id: "map")
  try map.set("a", .number(1))
  var submissions: [(JSONValue, PendingLocalOpMetadata)] = []
  let runtime = MockFluidDataStoreRuntime(clientId: "local")
  map.connect(runtime) { submissions.append(($0, $1)) }
  try map.clear()
  try map.set("a", .number(2))
  #expect(map.get("a") == .number(2))
  try map.rollback(submissions[1].0, localOpMetadata: submissions[1].1)
  #expect(map.get("a") == nil)
  try map.rollback(submissions[0].0, localOpMetadata: submissions[0].1)
  #expect(map.get("a") == .number(1))
}
@Test func mapProtoSummaryAndLargeSplit() throws {
  let map = SharedMap(id: "map")
  try map.set("__proto__", .number(1))
  try map.set("large", .string(JSString(String(repeating: "x", count: 8190))))
  let summary = map.summarize()
  #expect(try summary.readAndParse("header").member("blobs").asArray() == [.string("blob0")])
  let loaded = try SharedMap.load(id: "loaded", summary: summary)
  #expect(loaded.get("__proto__") == nil)
  #expect(loaded.get("large") == map.get("large"))
}
