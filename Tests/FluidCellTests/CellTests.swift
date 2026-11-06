import FluidCell
import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase
import FluidTestRuntimeUtils
import Testing

/// Sequences one outbound message at `sequenceNumber`, as the driver does.
private func sequenced(_ message: UnsequencedMessage, _ sequenceNumber: Int) throws
  -> SequencedMessage
{
  var json = JSObject<JSONValue>()
  json["clientId"] = .string(message.clientId)
  json["clientSequenceNumber"] = .number(Double(message.clientSequenceNumber))
  json["referenceSequenceNumber"] = .number(Double(message.referenceSequenceNumber))
  json["sequenceNumber"] = .number(Double(sequenceNumber))
  json["minimumSequenceNumber"] = .number(0)
  json["type"] = .string("op")
  json["contents"] = message.contents
  return try SequencedMessage(json: .object(json))
}

/// Delivers one sequenced message to every runtime, in the given order.
private func deliver(
  _ message: UnsequencedMessage, _ sequenceNumber: Int,
  to runtimes: [MockContainerRuntime<SharedCell>]
) throws {
  let sequencedMessage = try sequenced(message, sequenceNumber)
  for runtime in runtimes {
    try runtime.process(sequencedMessage)
  }
}

/// cell.spec.ts "Detached state" › APIs: "Can set and get cell data", "can delete cell data".
@Test func cellSetGetDeleteDetached() throws {
  let cell = SharedCell(id: "cell")
  var changed: [FluidValue] = []
  var deleted = 0
  cell.valueChanged = { changed.append($0) }
  cell.deleteEvent = { deleted += 1 }
  try cell.set(.json(.string("testValue")))
  #expect(cell.get() == .json(.string("testValue")))
  #expect(changed == [.json(.string("testValue"))])
  try cell.delete()
  #expect(cell.get() == .undefined)
  #expect(cell.empty())
  #expect(deleted == 1)
}

/// cell.spec.ts "Detached state" › APIs: "can load a SharedCell from snapshot" and
/// "can load a SharedCell with undefined value from snapshot".
@Test func cellLoadsSnapshotValueAndUndefined() throws {
  let cell = SharedCell(id: "cell")
  try cell.set(.json(.string("testValue")))
  let loaded = try SharedCell.load(id: "cell2", summary: cell.summarize())
  #expect(loaded.get() == .json(.string("testValue")))
  let empty = try SharedCell.load(id: "cell3", summary: SharedCell(id: "cell4").summarize())
  #expect(empty.get() == .undefined)
  #expect(empty.empty())
}

/// cell.spec.ts "Connected state" › APIs: "Shouldn't overwrite value if there is pending set".
@Test func cellPendingSetHidesRemoteUntilAcknowledged() throws {
  let cellA = SharedCell(id: "cell1")
  let cellB = SharedCell(id: "cell2")
  let runtimeA = MockContainerRuntime(clientId: "A", channel: cellA, lastSequenceNumber: 0)
  let runtimeB = MockContainerRuntime(clientId: "B", channel: cellB, lastSequenceNumber: 0)
  let runtimes = [runtimeA, runtimeB]
  try cellA.set(.json(.string("value1")))
  try cellB.set(.json(.string("pending1")))
  try cellB.set(.json(.string("pending2")))
  let opsA = runtimeA.takeOutbound()
  let opsB = runtimeB.takeOutbound()

  try deliver(opsA[0], 1, to: runtimes)
  #expect(cellA.get() == .json(.string("value1")))
  #expect(cellB.get() == .json(.string("pending2")))

  try deliver(opsB[0], 2, to: runtimes)
  #expect(cellA.get() == .json(.string("pending1")))
  #expect(cellB.get() == .json(.string("pending2")))

  try deliver(opsB[1], 3, to: runtimes)
  #expect(cellA.get() == .json(.string("pending2")))
  #expect(cellB.get() == .json(.string("pending2")))
}

/// cell.spec.ts "Attributor" › "should retrieve proper attribution in detached state".
@Test func cellDetachedAttributionRoundTripsThroughSummary() throws {
  let cell = SharedCell(id: "cell", attributionTrack: true)
  try cell.set(.json(.string("value")))
  let detached = try JSON.parse(#"{"type":"detached","id":0}"#)
  #expect(cell.getAttribution() == detached)
  let summary = try cell.summarize().readAndParse("header")
  #expect(
    JSON.stringify(summary) == #"{"value":"value","attribution":{"type":"detached","id":0}}"#)
  let loaded = try SharedCell.load(id: "cell2", summary: cell.summarize())
  #expect(loaded.getAttribution() == detached)
}

/// cell.spec.ts "Attributor" › "Retrieve proper attribution information in connected state".
@Test func cellConnectedAttributionFollowsSequenceNumbers() throws {
  let cellA = SharedCell(id: "cell1", attributionTrack: true)
  let cellB = SharedCell(id: "cell2", attributionTrack: true)
  let runtimeA = MockContainerRuntime(clientId: "A", channel: cellA, lastSequenceNumber: 0)
  let runtimeB = MockContainerRuntime(clientId: "B", channel: cellB, lastSequenceNumber: 0)
  let runtimes = [runtimeA, runtimeB]
  try cellA.set(.json(.string("value1")))
  try cellB.set(.json(.string("value2")))
  try cellB.delete()
  let opsA = runtimeA.takeOutbound()
  let opsB = runtimeB.takeOutbound()
  let local = try JSON.parse(#"{"type":"local"}"#)
  let op1 = try JSON.parse(#"{"type":"op","seq":1}"#)
  let op2 = try JSON.parse(#"{"type":"op","seq":2}"#)
  let op3 = try JSON.parse(#"{"type":"op","seq":3}"#)

  try deliver(opsA[0], 1, to: runtimes)
  #expect(cellA.getAttribution() == op1)
  #expect(cellB.getAttribution() == local)

  try deliver(opsB[0], 2, to: runtimes)
  #expect(cellA.getAttribution() == op2)
  #expect(cellB.getAttribution() == op2)

  try deliver(opsB[1], 3, to: runtimes)
  #expect(cellA.getAttribution() == op3)
  #expect(cellB.getAttribution() == op3)
}

/// specs/cell.md "Wire and persisted formats": op contents in construction order.
@Test func cellOpsMatchWireFormat() throws {
  let cell = SharedCell(id: "cell")
  let runtime = MockContainerRuntime(clientId: "A", channel: cell, lastSequenceNumber: 0)
  try cell.set(.json(.number(7)))
  try cell.set(.undefined)
  try cell.set(.handle(FluidHandle(absolutePath: "/handles/a")))
  try cell.delete()
  let ops = runtime.takeOutbound().map { JSON.stringify($0.contents) }
  #expect(
    ops == [
      #"{"type":"setCell","value":{"value":7}}"#,
      #"{"type":"setCell","value":{}}"#,
      #"{"type":"setCell","value":{"value":{"type":"__fluid_handle__","url":"/handles/a"}}}"#,
      #"{"type":"deleteCell"}"#,
    ])
}
