import FluidDriverDefinitions
import FluidJS
import FluidMap
import FluidTestRuntimeUtils
import Testing

/// directory.ts registerEventsOnSubDirectory adds bubbling listeners on every create, even when
/// the child already exists.
@Test func repeatedCreatePreservesBubblingRegistrations() throws {
  let directory = SharedDirectory(id: "directory")
  var events: [JSString] = []
  directory.subDirectoryCreated = { path, _ in events.append(path) }
  let one = try directory.createSubDirectory("one")
  try directory.createSubDirectory("one")
  events.removeAll()
  try one.createSubDirectory("two")
  #expect(events == ["one/two", "one/two"])
}

/// A remote clear emits valueChanged for each pending lifetime in lifetime order. Acknowledging
/// the first set of "10" keeps its lifetime ahead of "constructor", although its remaining
/// pending set was submitted last.
@Test func remoteClearEmitsPendingLifetimesInLifetimeOrder() throws {
  let directory = SharedDirectory(id: "directory")
  let runtime = MockFluidDataStoreRuntime(clientId: "local")
  var submitted: [(JSONValue, DirectoryLocalOpMetadata)] = []
  directory.connect(runtime) { submitted.append(($0, $1)) }
  try directory.set("10", .number(1))
  try directory.set("constructor", .number(2))
  try directory.set("10", .number(3))
  let ack = try message(clientId: "local", sequenceNumber: 1, contents: submitted[0].0)
  try directory.process(ack, local: true, localOpMetadata: submitted[0].1)
  var changed: [JSString] = []
  directory.valueChanged = { event, _ in changed.append(event.key) }
  let clear = try message(
    clientId: "remote", sequenceNumber: 2, contents: JSON.parse(#"{"type":"clear","path":"/"}"#))
  try directory.process(clear, local: false, localOpMetadata: nil)
  #expect(changed == ["10", "constructor"])
}

private func message(
  clientId: JSString, sequenceNumber: Int, contents: JSONValue
) throws -> SequencedMessage {
  var object = JSObject<JSONValue>()
  object["clientId"] = .string(clientId)
  object["clientSequenceNumber"] = .number(Double(sequenceNumber))
  object["referenceSequenceNumber"] = .number(0)
  object["sequenceNumber"] = .number(Double(sequenceNumber))
  object["minimumSequenceNumber"] = .number(0)
  object["type"] = .string("op")
  object["contents"] = contents
  return try SequencedMessage(json: .object(object))
}
