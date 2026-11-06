import FluidDriverDefinitions
import FluidJS
import FluidRegisterCollection
import FluidTestRuntimeUtils
import Testing

/// One observed event, in journal order.
private struct RegisterEvent: Equatable {
  let name: String
  let key: JSString
  let value: FluidValue
  let local: Bool
}

/// A sequenced message from `clientId` with the given JSON contents, as the driver delivers it.
private func sequencedMessage(
  clientId: JSString, clientSequenceNumber: Int = 0, referenceSequenceNumber: Int,
  sequenceNumber: Int, contents: JSONValue
) throws -> SequencedMessage {
  var object = JSObject<JSONValue>()
  object["clientId"] = .string(clientId)
  object["clientSequenceNumber"] = .number(Double(clientSequenceNumber))
  object["referenceSequenceNumber"] = .number(Double(referenceSequenceNumber))
  object["sequenceNumber"] = .number(Double(sequenceNumber))
  object["minimumSequenceNumber"] = .number(0)
  object["type"] = .string("op")
  object["contents"] = contents
  return try SequencedMessage(json: .object(object))
}

/// Sequences one outbound message at `sequenceNumber` and delivers it to every runtime, in order.
private func deliver(
  _ message: UnsequencedMessage, _ sequenceNumber: Int,
  to runtimes: [MockContainerRuntime<ConsensusRegisterCollection>]
) throws {
  let sequenced = try sequencedMessage(
    clientId: message.clientId, clientSequenceNumber: message.clientSequenceNumber,
    referenceSequenceNumber: message.referenceSequenceNumber, sequenceNumber: sequenceNumber,
    contents: message.contents)
  for runtime in runtimes {
    try runtime.process(sequenced)
  }
}

/// A remote `write` op as TS `IRegisterOperationPlain` lays it out: key, type, serializedValue,
/// value, refSeq.
private func remoteWrite(
  _ key: String, _ value: String, refSeq: Int, sequenceNumber: Int, clientId: JSString
) throws -> SequencedMessage {
  var plain = JSObject<JSONValue>()
  plain["type"] = .string("Plain")
  plain["value"] = .string(JSString(value))
  var object = JSObject<JSONValue>()
  object["key"] = .string(JSString(key))
  object["type"] = .string("write")
  object["serializedValue"] = .string(JSString(JSON.stringify(.string(JSString(value)))))
  object["value"] = .object(plain)
  object["refSeq"] = .number(Double(refSeq))
  return try sequencedMessage(
    clientId: clientId, referenceSequenceNumber: refSeq, sequenceNumber: sequenceNumber,
    contents: .object(object))
}

private func op(_ text: String) throws -> JSONValue {
  try JSON.parse(text)
}

/// The `header` blob of a single-blob summary, for loading.
private func header(_ text: String) -> SummaryTree {
  .singleBlob("header", JSString(text))
}

/// consensusRegisterCollection.spec.ts "Single connected client" › API: "Can add and remove data",
/// and "Change events emit the right key/value". The write is ACKed, so nothing is visible until the
/// sequenced op returns.
@Test func registerWriteTakesEffectOnAck() throws {
  let crc = ConsensusRegisterCollection(id: "consensus-register-collection")
  let runtime = MockContainerRuntime(clientId: "A", channel: crc, lastSequenceNumber: 0)
  var winner: Bool?
  var events: [RegisterEvent] = []
  crc.atomicChanged = {
    events.append(RegisterEvent(name: "atomicChanged", key: $0, value: $1, local: $2))
  }
  crc.versionChanged = {
    events.append(RegisterEvent(name: "versionChanged", key: $0, value: $1, local: $2))
  }
  try crc.write("key1", .json(.string("val1"))) { winner = $0 }
  let beforeAck = try crc.read("key1")
  #expect(beforeAck == .undefined)
  #expect(events.isEmpty)
  try deliver(runtime.takeOutbound()[0], 1, to: [runtime])
  let afterAck = try crc.read("key1")
  #expect(afterAck == .json(.string("val1")))
  #expect(winner == true, "No concurrency expected")
  #expect(
    events == [
      RegisterEvent(name: "atomicChanged", key: "key1", value: .json(.string("val1")), local: true),
      RegisterEvent(name: "versionChanged", key: "key1", value: .json(.string("val1")), local: true),
    ])
}

/// consensusRegisterCollection.spec.ts "Can add and remove a handle".
@Test func registerHandleValueRoundTripsOnAck() throws {
  let crc = ConsensusRegisterCollection(id: "consensus-register-collection")
  let runtime = MockContainerRuntime(clientId: "A", channel: crc, lastSequenceNumber: 0)
  let handle = FluidHandle(absolutePath: "/handles/a")
  try crc.write("key1", .handle(handle))
  try deliver(runtime.takeOutbound()[0], 1, to: [runtime])
  let value = try crc.read("key1")
  #expect(value == .handle(handle))
}

/// consensusRegisterCollection.spec.ts "Summary" › "summarize": byte-exact header blob.
@Test func registerSummaryIsTsByteExact() throws {
  let crc = ConsensusRegisterCollection(id: "consensus-register-collection")
  let runtime = MockContainerRuntime(clientId: "A", channel: crc, lastSequenceNumber: 0)
  try crc.write("key1", .json(.string("val1.1")))
  try deliver(runtime.takeOutbound()[0], 1, to: [runtime])
  let expected =
    #"{"key1":{"atomic":{"sequenceNumber":1,"value":{"type":"Plain","value":"val1.1"}},"versions":[{"sequenceNumber":1,"value":{"type":"Plain","value":"val1.1"}}]}}"#
  #expect(crc.summarize() == header(expected))
}

/// consensusRegisterCollection.spec.ts "Summary" › "load".
@Test func registerLoadsSummaryWithoutEvents() throws {
  let expected =
    #"{"key1":{"atomic":{"sequenceNumber":1,"value":{"type":"Plain","value":"val1.1"}},"versions":[{"sequenceNumber":1,"value":{"type":"Plain","value":"val1.1"}}]}}"#
  let loaded = try ConsensusRegisterCollection.load(
    id: "consensus-register-collection", summary: header(expected))
  let value = try loaded.read("key1")
  #expect(value == .json(.string("val1.1")))
  #expect(loaded.readVersions("key1") == [.json(.string("val1.1"))])
}

/// consensusRegisterCollection.spec.ts "Summary" › "load with SharedObject not supported" (0x06d).
/// The same shape with a Plain value must load, so the rejection is the value type and not the load.
@Test func registerRejectsSharedValuesOnLoad() throws {
  let plain =
    #"{"key1":{"atomic":{"sequenceNumber":1,"value":{"type":"Plain","value":"sharedObjId"}},"versions":[{"sequenceNumber":1,"value":{"type":"Plain","value":"sharedObjId"}}]}}"#
  let legacy =
    #"{"key1":{"atomic":{"sequenceNumber":1,"value":{"type":"Shared","value":"sharedObjId"}},"versions":[{"sequenceNumber":1,"value":{"type":"Shared","value":"sharedObjId"}}]}}"#
  let valid = try ConsensusRegisterCollection.load(
    id: "consensus-register-collection", summary: header(plain))
  let validValue = try valid.read("key1")
  #expect(validValue == .json(.string("sharedObjId")))
  #expect(throws: SharedObjectError.self) {
    _ = try ConsensusRegisterCollection.load(id: "consensus-register-collection", summary: header(legacy))
  }
}

/// consensusRegisterCollection.spec.ts "Multiple Clients" › "Local state": a detached write is
/// applied immediately, resolves true, and submits nothing.
@Test func registerDetachedWriteResolvesTrueWithoutOps() throws {
  let crc = ConsensusRegisterCollection(id: "collection1")
  var winner: Bool?
  var events: [RegisterEvent] = []
  crc.atomicChanged = {
    events.append(RegisterEvent(name: "atomicChanged", key: $0, value: $1, local: $2))
  }
  crc.versionChanged = {
    events.append(RegisterEvent(name: "versionChanged", key: $0, value: $1, local: $2))
  }
  try crc.write("key", .json(.string("testValue"))) { winner = $0 }
  #expect(winner == true)
  let value = try crc.read("key")
  #expect(value == .json(.string("testValue")))
  #expect(
    events == [
      RegisterEvent(name: "atomicChanged", key: "key", value: .json(.string("testValue")), local: true),
      RegisterEvent(name: "versionChanged", key: "key", value: .json(.string("testValue")), local: true),
    ])
}

/// consensusRegisterCollection.spec.ts "Reconnection" › "can resend unacked ops on reconnection".
@Test func registerResendsUnackedOpOnReconnection() throws {
  let collection1 = ConsensusRegisterCollection(id: "collection1")
  let runtime1 = MockContainerRuntime(clientId: "A", channel: collection1, lastSequenceNumber: 0)
  let collection2 = ConsensusRegisterCollection(id: "collection2")
  let runtime2 = MockContainerRuntime(clientId: "B", channel: collection2, lastSequenceNumber: 0)
  var events: [RegisterEvent] = []
  collection2.atomicChanged = {
    events.append(RegisterEvent(name: "atomicChanged", key: $0, value: $1, local: $2))
  }
  var winner: Bool?
  try collection1.write("testKey", .json(.string("testValue"))) { winner = $0 }
  runtime1.disconnect()
  try runtime1.reconnect(clientId: "A-2")
  let outbound = runtime1.takeOutbound()
  #expect(outbound.count == 1)
  try deliver(outbound[0], 1, to: [runtime1, runtime2])
  #expect(winner == true, "Write was not successful")
  #expect(
    events == [
      RegisterEvent(name: "atomicChanged", key: "testKey", value: .json(.string("testValue")), local: false)
    ])
}

/// consensusRegisterCollection.spec.ts "Reconnection" › "can store ops in disconnected state and
/// resend them on reconnection".
@Test func registerStoresDisconnectedOpAndResendsOnReconnection() throws {
  let collection1 = ConsensusRegisterCollection(id: "collection1")
  let runtime1 = MockContainerRuntime(clientId: "A", channel: collection1, lastSequenceNumber: 0)
  let collection2 = ConsensusRegisterCollection(id: "collection2")
  let runtime2 = MockContainerRuntime(clientId: "B", channel: collection2, lastSequenceNumber: 0)
  var events: [RegisterEvent] = []
  collection2.atomicChanged = {
    events.append(RegisterEvent(name: "atomicChanged", key: $0, value: $1, local: $2))
  }
  runtime1.disconnect()
  var winner: Bool?
  try collection1.write("testKey", .json(.string("testValue"))) { winner = $0 }
  #expect(runtime1.takeOutbound().isEmpty)
  try runtime1.reconnect(clientId: "A-2")
  let outbound = runtime1.takeOutbound()
  #expect(outbound.count == 1)
  try deliver(outbound[0], 1, to: [runtime1, runtime2])
  #expect(winner == true, "Write was not successful")
  #expect(
    events == [
      RegisterEvent(name: "atomicChanged", key: "testKey", value: .json(.string("testValue")), local: false)
    ])
}

/// consensusRegisterCollection.spec.ts "applyStashedOp": "can apply stashed write op and have it
/// reach remote client".
@Test func registerStashedWriteReachesRemoteClient() throws {
  let collection1 = ConsensusRegisterCollection(id: "collection1")
  let runtime1 = MockContainerRuntime(clientId: "A", channel: collection1, lastSequenceNumber: 0)
  let collection2 = ConsensusRegisterCollection(id: "collection2")
  let runtime2 = MockContainerRuntime(clientId: "B", channel: collection2, lastSequenceNumber: 0)
  let stashed = try op(
    #"{"key":"testKey","type":"write","value":{"type":"Plain","value":"testValue"},"serializedValue":"\"testValue\"","refSeq":0}"#
  )
  try collection1.applyStashedOp(stashed)
  let outbound = runtime1.takeOutbound()
  #expect(outbound.count == 1)
  try deliver(outbound[0], 1, to: [runtime1, runtime2])
  let local = try collection1.read("testKey")
  let remote = try collection2.read("testKey")
  #expect(local == .json(.string("testValue")), "Local collection should have the value")
  #expect(remote == .json(.string("testValue")), "Remote collection should have the value")
}

/// consensusRegisterCollection.spec.ts "applyStashedOp": "can apply stashed write op with handle
/// value". The stash holds only `serializedValue`, which decodes the handle as TS `parse` does.
@Test func registerStashedSerializedHandleWriteDecodesHandle() throws {
  let collection1 = ConsensusRegisterCollection(id: "collection1")
  let runtime1 = MockContainerRuntime(clientId: "A", channel: collection1, lastSequenceNumber: 0)
  let stashed = try op(
    #"{"key":"handleKey","type":"write","serializedValue":"{\"type\":\"__fluid_handle__\",\"url\":\"/handles/a\"}","refSeq":0}"#
  )
  try collection1.applyStashedOp(stashed)
  try deliver(runtime1.takeOutbound()[0], 1, to: [runtime1])
  let value = try collection1.read("handleKey")
  #expect(value == .handle(FluidHandle(absolutePath: "/handles/a")))
}

/// consensusRegisterCollection.spec.ts "applyStashedOp": "preserves refSeq from stashed op for
/// correct FWW semantics". A stashed op keeps the refSeq it was created with, so it loses.
@Test func registerStashedWriteKeepsOriginalRefSeqForFirstWriteWins() throws {
  let collection1 = ConsensusRegisterCollection(id: "collection1")
  let runtime1 = MockContainerRuntime(clientId: "A", channel: collection1, lastSequenceNumber: 0)
  let collection2 = ConsensusRegisterCollection(id: "collection2")
  let runtime2 = MockContainerRuntime(clientId: "B", channel: collection2, lastSequenceNumber: 0)
  try collection1.write("fwwKey", .json(.string("firstValue")))
  try deliver(runtime1.takeOutbound()[0], 1, to: [runtime1, runtime2])
  let first = try collection1.read("fwwKey")
  #expect(first == .json(.string("firstValue")), "First value should be written")
  let stashed = try op(
    #"{"key":"fwwKey","type":"write","value":{"type":"Plain","value":"stashedValue"},"serializedValue":"\"stashedValue\"","refSeq":0}"#
  )
  try collection1.applyStashedOp(stashed)
  try deliver(runtime1.takeOutbound()[0], 2, to: [runtime1, runtime2])
  let atomic = try collection1.read("fwwKey")
  #expect(atomic == .json(.string("firstValue")), "Atomic value should remain first value due to FWW")
  #expect(
    collection1.readVersions("fwwKey")
      == [.json(.string("firstValue")), .json(.string("stashedValue"))])
}

/// Spec §5 example: concurrent A(seq 11, ref 10) then B(seq 12, ref 10) leaves atomic A and versions
/// [A, B]; a causally later C(seq 13, ref 12) takes atomic and removes both earlier versions.
@Test func registerAtomicWinnerAndVersionListFollowRefSeq() throws {
  let crc = ConsensusRegisterCollection(id: "crc")
  let runtime = MockContainerRuntime(clientId: "A", channel: crc, lastSequenceNumber: 0)
  try runtime.process(try remoteWrite("a", "A", refSeq: 10, sequenceNumber: 11, clientId: "B"))
  #expect(try crc.read("a", .atomic) == .json(.string("A")))
  #expect(try crc.read("a", .lww) == .json(.string("A")))
  #expect(crc.readVersions("a") == [.json(.string("A"))])
  try runtime.process(try remoteWrite("a", "B", refSeq: 10, sequenceNumber: 12, clientId: "C"))
  #expect(try crc.read("a", .atomic) == .json(.string("A")))
  #expect(try crc.read("a", .lww) == .json(.string("B")))
  #expect(crc.readVersions("a") == [.json(.string("A")), .json(.string("B"))])
  try runtime.process(try remoteWrite("a", "C", refSeq: 12, sequenceNumber: 13, clientId: "B"))
  #expect(try crc.read("a", .atomic) == .json(.string("C")))
  #expect(crc.readVersions("a") == [.json(.string("C"))])
}

/// Two clients write the same key from the same ref. The first sequenced write wins atomic and the
/// second loses: its write resolves false, yet it still joins the version list.
@Test func registerConcurrentLoserResolvesFalseAndKeepsVersion() throws {
  let crcA = ConsensusRegisterCollection(id: "crc")
  let runtimeA = MockContainerRuntime(clientId: "A", channel: crcA, lastSequenceNumber: 0)
  let crcB = ConsensusRegisterCollection(id: "crc")
  let runtimeB = MockContainerRuntime(clientId: "B", channel: crcB, lastSequenceNumber: 0)
  var winnerA: Bool?
  var winnerB: Bool?
  try crcA.write("k", .json(.string("fromA"))) { winnerA = $0 }
  try crcB.write("k", .json(.string("fromB"))) { winnerB = $0 }
  try deliver(runtimeA.takeOutbound()[0], 1, to: [runtimeA, runtimeB])
  try deliver(runtimeB.takeOutbound()[0], 2, to: [runtimeA, runtimeB])
  #expect(winnerA == true)
  #expect(winnerB == false)
  #expect(try crcA.read("k", .atomic) == .json(.string("fromA")))
  #expect(try crcB.read("k", .atomic) == .json(.string("fromA")))
  #expect(try crcA.read("k", .lww) == .json(.string("fromB")))
  #expect(crcB.readVersions("k") == [.json(.string("fromA")), .json(.string("fromB"))])
}

/// Spec "Wire and persisted formats": the write op is key, type, serializedValue, value, refSeq.
@Test func registerWriteOpIsTsByteExact() throws {
  let crc = ConsensusRegisterCollection(id: "crc")
  let runtime = MockContainerRuntime(clientId: "A", channel: crc, lastSequenceNumber: 10)
  try crc.write("a", .json(.number(7)))
  let outbound = runtime.takeOutbound()
  #expect(outbound.count == 1)
  #expect(
    JSON.stringify(outbound[0].contents)
      == #"{"key":"a","type":"write","serializedValue":"7","value":{"type":"Plain","value":7},"refSeq":10}"#
  )
}

/// Spec: an undefined value omits the inner value and the serializedValue member.
@Test func registerUndefinedWriteOmitsSerializedValue() throws {
  let crc = ConsensusRegisterCollection(id: "crc")
  let runtime = MockContainerRuntime(clientId: "A", channel: crc, lastSequenceNumber: 0)
  try crc.write("a", .undefined)
  let outbound = runtime.takeOutbound()
  #expect(
    JSON.stringify(outbound[0].contents)
      == #"{"key":"a","type":"write","value":{"type":"Plain"},"refSeq":0}"#
  )
  try deliver(outbound[0], 1, to: [runtime])
  let value = try crc.read("a")
  #expect(value == .undefined)
  #expect(crc.readVersions("a") == [.undefined])
}

/// Spec: a legacy write with only serializedValue is accepted, and its missing refSeq is filled from
/// the envelope's reference sequence number.
@Test func registerLegacyWriteWithoutValueAndRefSeqIsAccepted() throws {
  let crc = ConsensusRegisterCollection(id: "crc")
  let runtime = MockContainerRuntime(clientId: "A", channel: crc, lastSequenceNumber: 0)
  let legacy = try sequencedMessage(
    clientId: "B", referenceSequenceNumber: 0, sequenceNumber: 1,
    contents: try op(#"{"key":"a","type":"write","serializedValue":"7"}"#))
  try runtime.process(legacy)
  let value = try crc.read("a")
  #expect(value == .json(.number(7)))
}

/// consensusRegisterCollection.ts rollback: a rolled-back write leaves state unchanged and its
/// Promise resolves false.
@Test func registerRollbackResolvesFalseAndLeavesState() throws {
  let crc = ConsensusRegisterCollection(id: "crc")
  let runtime = MockContainerRuntime(
    clientId: "A", channel: crc, lastSequenceNumber: 0, flushMode: .turnBased)
  var winner: Bool?
  try crc.write("key", .json(.string("v"))) { winner = $0 }
  try runtime.rollback()
  #expect(winner == false)
  #expect(try crc.read("key") == .undefined)
  #expect(runtime.takeOutbound().isEmpty)
}

/// keys() is live Map insertion order, while a loaded replica enumerates index keys first.
@Test func registerKeysFollowLiveAndLoadedOrder() throws {
  let crc = ConsensusRegisterCollection(id: "crc")
  let runtime = MockContainerRuntime(clientId: "A", channel: crc, lastSequenceNumber: 0)
  for (index, key) in ["b", "10", "a", "0"].enumerated() {
    try crc.write(JSString(key), .json(.string("v")))
    try deliver(runtime.takeOutbound()[0], index + 1, to: [runtime])
  }
  #expect(crc.keys() == ["b", "10", "a", "0"])
  let loaded = try ConsensusRegisterCollection.load(id: "crc2", summary: crc.summarize())
  #expect(loaded.keys() == ["0", "10", "b", "a"])
}

/// consensusRegisterCollection.ts summarizeCore: a plain-object assignment drops `__proto__`.
@Test func registerSummaryDropsProtoKeyAsTsObjectAssignmentDoes() throws {
  let crc = ConsensusRegisterCollection(id: "crc")
  let runtime = MockContainerRuntime(clientId: "A", channel: crc, lastSequenceNumber: 0)
  try crc.write("__proto__", .json(.string("v")))
  try deliver(runtime.takeOutbound()[0], 1, to: [runtime])
  #expect(crc.keys() == ["__proto__"])
  #expect(crc.summarize() == header("{}"))
}

/// consensusRegisterCollection.ts read(): LWW on a loaded register whose versions are empty
/// asserts 0x06c, while the atomic read still returns the stored value.
@Test func registerLwwReadOfEmptyVersionsThrows() throws {
  let summary =
    #"{"a":{"atomic":{"sequenceNumber":1,"value":{"type":"Plain","value":"x"}},"versions":[]}}"#
  let loaded = try ConsensusRegisterCollection.load(id: "crc", summary: header(summary))
  #expect(try loaded.read("a", .atomic) == .json(.string("x")))
  #expect(throws: SharedObjectError.self) {
    _ = try loaded.read("a", .lww)
  }
}
