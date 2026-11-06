import FluidDriverDefinitions
import FluidJS
import FluidMap
import Testing

@Test func mapSummaryExcludesOptimisticOverlay() throws {
  let map = SharedMap(id: "map")
  let runtime = TestDataStoreRuntime(clientId: "local")
  map.connect(runtime) { _, _ in }
  try map.set("pending", .number(7))
  #expect(map.get("pending") == .number(7))
  #expect(try map.summarize().readAndParse("header").member("content").asObject().isEmpty)
}

@Test func mapRollbackRevealsInterveningRemoteValue() throws {
  let map = SharedMap(id: "map")
  var saved: (JSONValue, PendingLocalOpMetadata)?
  let runtime = TestDataStoreRuntime(clientId: "local")
  map.connect(runtime) { saved = ($0, $1) }
  try map.set("key", .number(7))
  let remote = try SequencedMessage(
    json: JSON.parse(
      #"{"clientId":"remote","clientSequenceNumber":1,"referenceSequenceNumber":0,"sequenceNumber":1,"minimumSequenceNumber":0,"type":"op","contents":{"key":"key","type":"set","value":{"type":"Plain","value":9}}}"#
    ))
  try map.process(remote, local: false, localOpMetadata: nil)
  #expect(map.get("key") == .number(7))
  let submission = try #require(saved)
  try map.rollback(submission.0, localOpMetadata: submission.1)
  #expect(map.get("key") == .number(9))
}
