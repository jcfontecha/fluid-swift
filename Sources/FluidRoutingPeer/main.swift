import FluidJS
import FluidContainerRuntime
import Foundation
import FluidTestRuntimeUtils

func obj(_ entries: [(JSString, JSONValue?)]) -> JSONValue {
  var object = JSObject<JSONValue>()
  for (key, value) in entries { object[key] = value }
  return .object(object)
}
func str(_ value: String) -> JSONValue { .string(JSString(value)) }
func run(_ scenario: JSONValue) throws -> JSONValue {
  var output: [JSONValue] = []
  func record(_ destination: JSString, _ value: JSONValue) { output.append(obj([("destination", .string(destination)), ("value", value)])) }
  let detached = try scenario.member("detached") == .bool(true)
  let pending = try scenario.member("pending") == .bool(true)
  var now = 1000.0
  var wire: [JSONValue] = []
  var handles: [BlobHandle] = []
  var storage: [JSString: [UInt8]] = [:]
  var deferred = false
  var uploads: [() throws -> Void] = []
  let uuids = try scenario.member("uuids").asArray()
  var uuidIndex = 0
  func manager(_ state: JSONValue? = nil) throws -> BlobManager {
    let manager = BlobManager()
    manager.attachState = detached ? .detached : .attached
    manager.now = { now }
    manager.upload = { bytes, completion in
      let id = JSString("s" + Data(bytes).base64EncodedString())
      storage[id] = bytes
      if deferred { uploads.append { try completion(.success(.init(id: id, minTTLInSeconds: 10))) } }
      else { try completion(.success(.init(id: id, minTTLInSeconds: 10))) }
    }
    manager.read = { id, completion in
      guard let bytes = storage[id] else { throw JSONDecodingError("missing storage") }
      try completion(.success(bytes))
    }
    manager.sendBlobAttachMessage = { wire.append($0) }
    try manager.restorePendingBlobs(state)
    return manager
  }
  var blobs = try manager()
  let runtime = try ContainerRuntime(sessionId: "10000000-0000-4000-8000-000000000001", clientId: "self", deltaManager: MockDeltaManager(), quorum: MockQuorumClients())
  runtime.extensions = ["presence"]
  runtime.channelCollection.contexts = ["a", "b", ""]
  runtime.channelCollection.deleted = ["deleted"]
  runtime.onRuntimeDispatch = { record($0, $1) }
  runtime.onEvent = { record($0, .array($1)) }
  runtime.channelCollection.onDispatch = { record($0, $1) }
  runtime.onIdAllocation = { contents, saved in record("idAllocation", .array([.array(contents), .bool(saved)])) }
  var csn = 0
  let outbox = Outbox(splitter: OpSplitter(), submitBatch: { batch in
    record("outbound", .array(batch))
    csn += batch.count
    return csn
  })
  for command in try scenario.member("commands").asArray() {
    let kind = try command.member("kind").asString()
    let value = try command.member("value")
    let v = try value.asObject()
    func index() throws -> Int { try value.member("index").asInt() }
    do {
      switch kind {
      case "batch":
        let entries = try value.member("ops").asArray().enumerated().map { index, op in
          try obj([("message", obj([("type", op.member("type")), ("contents", op.member("contents")), ("sequenceNumber", .number(100)), ("clientSequenceNumber", .number(Double(index + 1))), ("minimumSequenceNumber", .number(0)), ("referenceSequenceNumber", .number(0)), ("clientId", str("peer")), ("timestamp", .number(10))])), ("localOpMetadata", .number(Double(index)))])
        }
        try runtime.processInboundMessages(entries, batchStart: true, batchEnd: true, local: false, groupedBatch: v["grouped"] == .bool(true))
      case "outbound":
        for op in try value.member("ops").asArray() { try outbox.submit(.init(runtimeOp: op, referenceSequenceNumber: 0)) }
        try outbox.flush()
      case "compat":
        let version = try value.member("version").asString().description
        try validateRuntimeOptions(version, options: obj([("createBlobPayloadPending", v["pending"] == .bool(true) ? .bool(true) : nil)]))
        record("compat", try getMinVersionForCollabDefaults(version))
      case "reloadSummary":
        let summary = blobs.summarize()
        var snapshotBlobs = JSObject<JSONValue>()
        var table = "[]"
        for (name, entry) in try summary.member("summary").member("tree").asObject().entries {
          if try entry.member("type") == .number(4) { snapshotBlobs[name] = try entry.member("id") }
          else if name == ".redirectTable" {
            snapshotBlobs[name] = str("redirectBlob")
            table = try entry.member("content").asString().description
          }
        }
        let snapshot = obj([("trees", obj([(".blobs", obj([("blobs", .object(snapshotBlobs))]))]))])
        let info = try loadBlobManagerLoadInfo(snapshot, readBlob: { _ in table })
        blobs = try manager()
        blobs.load(ids: info.ids, redirectTable: info.redirectTable)
      case "route":
        runtime.blobManager = blobs
        let envelope = obj([("type", try value.member("type")), ("timestamp", .number(10)), ("sequenceNumber", .number(20)), ("clientId", str("peer")), ("clientSequenceNumber", .number(1)), ("minimumSequenceNumber", .number(0)), ("referenceSequenceNumber", .number(0)), ("metadata", v["metadata"])])
        let contents = try value.member("contents").asArray().enumerated().map { i, content in obj([("contents", content), ("localOpMetadata", .number(Double(i))), ("clientSequenceNumber", .number(Double(i + 1)))]) }
        try runtime.validateAndProcessRuntimeMessages(envelope, messagesContent: contents, local: v["local"] == .bool(true), savedOp: v["saved"] == .bool(true))
      case "signal":
        var envelope = obj([("address", v["address"]), ("contents", obj([("type", str("cursor")), ("content", v["payload"])]))])
        if v["target"] == nil { envelope = try runtime.signalTelemetryManager.applyTrackingToBroadcastSignalEnvelope(envelope) }
        record("signalWire", obj([("envelope", envelope), ("target", v["target"])]))
        try runtime.processSignal(obj([("clientId", v["client"] == str("server") ? .null : (v["client"] ?? str("peer"))), ("content", envelope), ("targetClientId", v["target"])]), local: v["local"] == .bool(true))
      case "create":
        guard uuidIndex < uuids.count else { throw JSONDecodingError("entropy exhausted") }
        let id = try uuids[uuidIndex].asString()
        uuidIndex += 1
        let bytes = try value.member("bytes").asArray().map { value -> UInt8 in
          guard let byte = try UInt8(exactly: value.asInt()) else { throw JSONDecodingError("invalid byte") }
          return byte
        }
        try blobs.createBlob(bytes, localId: id, payloadPending: pending) { handle in
          handles.append(handle)
          record("handle", obj([("path", .string(handle.absolutePath)), ("payloadPending", .bool(handle.payloadPending)), ("payloadState", str(handle.payloadState))]))
        }
        if !pending && !detached {
          guard let last = wire.last else { throw JSONDecodingError("no attach") }
          try blobs.processBlobAttachMessage(last)
        }
      case "defer": deferred = v["enabled"] == .bool(true)
      case "finish": if !uploads.isEmpty { try uploads.removeFirst()() }
      case "abort":
        let i = try index()
        guard i >= 0 && i < uuidIndex else { throw JSONDecodingError("bad index") }
        try blobs.abort(uuids[i].asString())
      case "share", "attach":
        let i = try index()
        if handles.indices.contains(i) {
          if kind == "share" { try handles[i].sharePayload() }
          else { try handles[i].attachGraph() }
        }
      case "ack", "resubmit":
        let i = try index()
        guard wire.indices.contains(i) else { throw JSONDecodingError("no attach") }
        if kind == "ack" { try blobs.processBlobAttachMessage(wire[i]) }
        else { try blobs.reSubmit(wire[i]) }
      case "remote": try blobs.processBlobAttachMessage(value)
      case "time": now = try value.member("now").asNumber()
      case "restore": blobs = try manager(blobs.getPendingBlobs())
      case "resume": try blobs.sharePendingBlobs()
      case "patch":
        let entries = try value.member("entries").asArray().map { value -> (JSString, JSString) in
          let pair = try value.asArray()
          guard pair.count == 2 else { throw JSONDecodingError("bad pair") }
          return try (pair[0].asString(), pair[1].asString())
        }
        try blobs.patchRedirectTable(entries)
      case "sweep": record("sweep", .array(try blobs.deleteSweepReadyNodes(value.member("routes").asArray().map { try $0.asString() }).map(JSONValue.string)))
      case "read":
        try blobs.getBlob(value.member("id").asString()) { result in record("read", .array(try result.get().map { .number(Double($0)) })) }
      default: throw JSONDecodingError("bad command")
      }
    } catch { record("error", .string(kind)) }
    record("state", obj([("wire", .array(wire.map { obj([("type", str("blobAttach")), ("metadata", $0)]) })), ("summary", blobs.summarize()), ("gc", blobs.getGCData()), ("pending", try blobs.getPendingBlobs() ?? .null), ("outstanding", .bool(blobs.hasOutstandingBlobWork)), ("handles", .array(handles.map { obj([("path", .string($0.absolutePath)), ("payloadState", str($0.payloadState)), ("failed", .bool($0.payloadShareError != nil)), ("isAttached", .bool($0.isAttached))]) }))]))
  }
  return .array(output)
}
while let line = readLine() {
  do { FileHandle.standardOutput.write(Data((JSON.stringify(try run(JSON.parse(line))) + "\n").utf8)) }
  catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
  }
}
