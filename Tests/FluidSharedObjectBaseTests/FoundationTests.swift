import FluidCounter
import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase
import Testing

@Test func counterStashAndRollback() throws {
  let counter = SharedCounter(id: "c")
  var submissions: [(JSONValue, Int)] = []
  let runtime = TestDataStoreRuntime()
  counter.connect(runtime) { submissions.append(($0, $1)) }
  let op = try JSON.parse(#"{"type":"increment","incrementAmount":7}"#)
  try counter.applyStashedOp(op)
  #expect(counter.value == 7)
  #expect(submissions.count == 1)
  try counter.rollback(op, localOpMetadata: submissions[0].1)
  #expect(counter.value == 0)
}

@Test func serializedHandleRoundTrip() throws {
  let serializer = FluidSerializer(contextPath: "/store")
  let handle = FluidHandle(absolutePath: "/store/dds")
  var bound: [JSString] = []
  let encoded = serializer.encode(.handle(handle)) { bound.append($0.absolutePath) }
  #expect(JSON.stringify(encoded) == #"{"type":"__fluid_handle__","url":"/store/dds"}"#)
  #expect(bound == ["/store/dds"])
  let decoded = try serializer.decode(JSON.parse(#"{"type":"__fluid_handle__","url":"dds"}"#))
  #expect(decoded == .handle(handle))
}

private final class BunchProbe: SharedObject<Int> {
  var order: [String] = []
  var fail = false
  override func processMessagesCore(_ contents: [Content], local: Bool) throws {
    order.append("core:\(contents.count)")
    if fail { throw SharedObjectError("probe failure") }
  }
}
@Test func bunchEventsBracketOneCoreCall() throws {
  let probe = BunchProbe(id: "probe")
  let message = try SequencedMessage(
    json: JSON.parse(
      #"{"clientId":"remote","clientSequenceNumber":1,"referenceSequenceNumber":0,"sequenceNumber":1,"minimumSequenceNumber":0,"type":"op","contents":{}}"#
    ))
  probe.on("pre-op") { _, _ in probe.order.append("pre") }
  probe.on("op") { _, _ in probe.order.append("post") }
  let contents = [
    BunchProbe.Content(message: message, metadata: nil),
    BunchProbe.Content(message: message, metadata: nil),
  ]
  try probe.processMessages(contents, local: false)
  #expect(probe.order == ["pre", "pre", "core:2", "post", "post"])
  probe.order = []
  probe.fail = true
  #expect(throws: SharedObjectError.self) { try probe.processMessages(contents, local: false) }
  #expect(probe.order == ["pre", "pre", "core:2"])
}

/// A datastore runtime that never connected; channels hold it weakly.
private final class TestDataStoreRuntime: IFluidDataStoreRuntime {
  var clientId: JSString? { nil }
}
