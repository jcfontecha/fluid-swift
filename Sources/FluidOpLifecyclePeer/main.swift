import FluidContainerRuntime
import FluidJS
import Foundation

while let line = readLine() {
  do {
    let request = try JSON.parse(line)
    let result: JSONValue
    if try request.member("method").asString() == "outbound" {
      result = try outbound(request.member("value"))
    } else {
      result = try inbound(request.member("value"))
    }
    FileHandle.standardOutput.write(Data((JSON.stringify(result) + "\n").utf8))
  } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
  }
}
// Harness adapter: JSON scenario generation belongs to the test peer, not runtime APIs.
func outbound(_ scenario: JSONValue) throws -> JSONValue {
  let config = OutboxConfig(
    compressionOptions: .init(minimumBatchSizeInBytes: try scenario.member("threshold").asInt()),
    maxBatchSizeInBytes: 10_000_000)
  let groupingManager = OpGroupingManager(
    config: .init(groupedBatchingEnabled: try scenario.member("grouped") == .bool(true)))
  var wire: [JSONValue] = []
  var csn = 0
  func submit(_ messages: [JSONValue]) -> Int {
    wire.append(.array(messages))
    csn += messages.count
    return csn
  }
  let splitter = OpSplitter(
    chunkSizeInBytes: try scenario.member("chunkSize").asInt(),
    maxBatchSizeInBytes: config.maxBatchSizeInBytes, submitBatchFn: submit)
  let outbox = Outbox(
    config: config, groupingManager: groupingManager, splitter: splitter, submitBatch: submit)
  for (ref, batch) in try scenario.member("batches").asArray().enumerated() {
    let allocation = try batch.member("allocation") == .bool(true)
    outbox.generateIdAllocation = {
      guard allocation else {
        return nil
      }
      return LocalBatchMessage(
        runtimeOp: try JSON.parse(
          #"{"type":"idAllocation","contents":{"sessionId":"00000000-0000-4000-8000-000000000001","ids":{"firstGenCount":\#(ref + 1),"count":1,"requestedClusterSize":512,"localIdRanges":[[\#(ref + 1),1]]}}}"#
        ), referenceSequenceNumber: ref)
    }
    for op in try batch.member("ops").asArray() {
      var inner = JSObject<JSONValue>()
      inner["address"] = .string("dds")
      var data = JSObject<JSONValue>()
      data["type"] = .string("op")
      data["content"] = op
      inner["contents"] = .object(data)
      var envelope = JSObject<JSONValue>()
      envelope["type"] = .string("component")
      envelope["contents"] = .object(inner)
      try outbox.submit(
        LocalBatchMessage(runtimeOp: .object(envelope), referenceSequenceNumber: ref),
        clientSequenceNumber: 0)
    }
    let id = try batch.asObject()["batchId"]?.asString().description
    try outbox.flush(batchId: id, referenceSequenceNumber: ref)
  }
  return .array(wire)
}
func inbound(_ wire: JSONValue) throws -> JSONValue {
  let processor = RemoteMessageProcessor()
  var seq = 0
  var results: [JSONValue] = []
  for batch in try wire.asArray() {
    for entry in try batch.asArray() {
      seq += 1
      var m = try entry.asObject()
      m["type"] = .string("op")
      m["clientId"] = .string("sender")
      m["clientSequenceNumber"] = .number(Double(seq))
      m["sequenceNumber"] = .number(Double(seq + 100))
      m["minimumSequenceNumber"] = .number(0)
      m["timestamp"] = .number(1234)
      results.append(try processor.process(.object(m)) ?? .null)
    }
  }
  return .array(results)
}
