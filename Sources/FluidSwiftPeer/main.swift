import FluidCell
import FluidCounter
import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidMap
import FluidTestRuntimeUtils
import Foundation

/// Swift peer for the differential harness: JSON-RPC 2.0 over stdio, one JSON object per line
/// (harness/PROTOCOL.md).
struct PeerError: Error, CustomStringConvertible {
  let description: String
}

protocol PeerClient: AnyObject {
  func takeEvents() -> [JSONValue]
  func takeOutbound() -> [UnsequencedMessage]
  func process(_ message: SequencedMessage) throws
  func edit(_ value: JSONValue) throws
  func state() throws -> JSONValue
  func summarize() -> SummaryTree
  func disconnect()
  func flush()
  func rollback() throws
  func stash(_ contents: JSONValue) throws
  func reconnect(_ id: JSString) throws
}
final class RuntimeClient<C: Channel>: PeerClient {
  let runtime: MockContainerRuntime<C>
  let editChannel: (C, JSONValue) throws -> Void
  let stateChannel: (C) throws -> JSONValue
  var events: [JSONValue] = []
  func takeEvents() -> [JSONValue] {
    defer { events.removeAll() }
    return events
  }
  init(
    _ runtime: MockContainerRuntime<C>, edit: @escaping (C, JSONValue) throws -> Void,
    state: @escaping (C) throws -> JSONValue
  ) {
    self.runtime = runtime
    editChannel = edit
    stateChannel = state
  }
  func flush() { runtime.flush() }
  func rollback() throws { try runtime.rollback() }
  func stash(_ contents: JSONValue) throws { try runtime.channel.applyStashedOp(contents) }
  func disconnect() { runtime.disconnect() }
  func reconnect(_ id: JSString) throws {
    try runtime.reconnect(clientId: id)
  }
  func takeOutbound() -> [UnsequencedMessage] { runtime.takeOutbound() }
  func process(_ message: SequencedMessage) throws { try runtime.process(message) }
  func edit(_ value: JSONValue) throws { try editChannel(runtime.channel, value) }
  func state() throws -> JSONValue { try stateChannel(runtime.channel) }
  func summarize() -> SummaryTree { runtime.channel.summarize() }
}
final class Peer {
  private var clients: [JSString: any PeerClient] = [:]
  private let ddsTypes: [JSString] = [
    SharedCounter.type, SharedMap.type,
    SharedDirectory.type, "https://graph.microsoft.com/types/cell",
    "https://graph.microsoft.com/types/task-manager",
    "https://graph.microsoft.com/types/consensus-register-collection",
    "https://graph.microsoft.com/types/consensus-queue",
    "https://graph.microsoft.com/types/pact-map",
    "https://graph.microsoft.com/types/shared-summary-block",
    "https://graph.microsoft.com/types/SharedArray",
    "https://graph.microsoft.com/types/signal",
  ]
  private func client(_ params: JSONValue) throws -> any PeerClient {
    let id = try params.member("clientId").asString()
    guard let client = clients[id] else { throw PeerError(description: "unknown client \(id)") }
    return client
  }
  private func result(_ key: JSString, _ value: JSONValue) -> JSONValue {
    var object = JSObject<JSONValue>()
    object[key] = value
    return .object(object)
  }
  func handle(_ method: JSString, _ params: JSONValue) throws -> JSONValue {
    switch method {
    case "reset":
      clients.removeAll()
      return .object(JSObject())
    case "hello":
      var result = JSObject<JSONValue>()
      result["implementation"] = .string("swift")
      result["ddsTypes"] = .array(ddsTypes.map(JSONValue.string))
      return .object(result)
    case "createClient":
      let id = try params.member("clientId").asString()
      guard clients[id] == nil else { throw PeerError(description: "duplicate client") }
      let type = try params.member("ddsType").asString()
      let channelId = try params.member("channelId").asString()
      let summary = try params.member("summary")
      let seq = try params.member("sequenceNumber").asInt()
      let mode: FlushMode =
        try params.asObject()["flushMode"] == .string("turnBased") ? .turnBased : .immediate
      if type == SharedCounter.type {
        let c =
          summary == .null
          ? SharedCounter(id: channelId)
          : try SharedCounter.load(id: channelId, summary: SummaryTree(json: summary))
        let client = RuntimeClient(
          MockContainerRuntime(clientId: id, channel: c, lastSequenceNumber: seq, flushMode: mode),
          edit: { c, e in
            guard try e.member("kind").asString() == "increment" else {
              throw PeerError(description: "invalid counter edit")
            }
            try c.increment(e.member("amount").asNumber())
          },
          state: { c in
            var value = JSObject<JSONValue>()
            value["value"] = .number(c.value)
            return .object(value)
          })
        c.incremented = { [weak client] amount, value in
          client?.events.append(.array([.string("incremented"), .number(amount), .number(value)]))
        }
        clients[id] = client
      } else if type == SharedMap.type {
        let c =
          summary == .null
          ? SharedMap(id: channelId)
          : try SharedMap.load(id: channelId, summary: SummaryTree(json: summary))
        clients[id] = mapAdapter(
          MockContainerRuntime(clientId: id, channel: c, lastSequenceNumber: seq, flushMode: mode))
      } else if type == SharedDirectory.type {
        let c =
          summary == .null
          ? SharedDirectory(id: channelId)
          : try SharedDirectory.load(id: channelId, summary: SummaryTree(json: summary))
        clients[id] = directoryAdapter(
          MockContainerRuntime(clientId: id, channel: c, lastSequenceNumber: seq, flushMode: mode))
      } else if type == SharedCell.type {
        let c =
          summary == .null
          ? SharedCell(id: channelId)
          : try SharedCell.load(id: channelId, summary: SummaryTree(json: summary))
        clients[id] = cellAdapter(
          MockContainerRuntime(clientId: id, channel: c, lastSequenceNumber: seq, flushMode: mode))
      } else {
        throw PeerError(description: "not implemented: \(type)")
      }
      return .object(JSObject())
    case "edit":
      let c = try client(params)
      try c.edit(params.member("edit"))
      return result("outbound", .array(c.takeOutbound().map(\.json)))
    case "process":
      let c = try client(params)
      try c.process(SequencedMessage(json: params.member("message")))
      return result("outbound", .array(c.takeOutbound().map(\.json)))
    case "queries": return result("queries", .object(JSObject()))
    case "events": return result("events", .array(try client(params).takeEvents()))
    case "state": return result("state", try client(params).state())
    case "summarize": return result("summary", try client(params).summarize().json)
    case "flush", "rollback", "stash":
      let c = try client(params)
      if method == "flush" {
        c.flush()
      } else if method == "rollback" {
        try c.rollback()
      } else {
        try c.stash(params.member("contents"))
      }
      return result("outbound", .array(c.takeOutbound().map(\.json)))
    case "disconnect":
      let c = try client(params)
      c.disconnect()
      return result("outbound", .array(c.takeOutbound().map(\.json)))
    case "reconnect":
      let c = try client(params)
      let id = try params.member("newClientId").asString()
      try c.reconnect(id)
      var r = JSObject<JSONValue>()
      r["clientId"] = .string(id)
      r["outbound"] = .array(c.takeOutbound().map(\.json))
      return .object(r)
    case "membership":
      return result("outbound", .array(try client(params).takeOutbound().map(\.json)))
    case "disposeClient":
      clients[try params.member("clientId").asString()] = nil
      return .object(JSObject())
    default: throw PeerError(description: "unknown method \(method)")
    }
  }
}

func respond(id: JSONValue, _ outcome: Result<JSONValue, any Error>) {
  var response = JSObject<JSONValue>()
  response["jsonrpc"] = .string("2.0")
  response["id"] = id
  switch outcome {
  case .success(let result):
    response["result"] = result
  case .failure(let error):
    var errorObject = JSObject<JSONValue>()
    errorObject["code"] = .number(-32000)
    errorObject["message"] = .string(JSString(String(describing: error)))
    response["error"] = .object(errorObject)
  }
  FileHandle.standardOutput.write(Data((JSON.stringify(.object(response)) + "\n").utf8))
}

let peer = Peer()

while let line = readLine() {
  let request: JSONValue
  do {
    request = try JSON.parse(line)
  } catch {
    respond(id: .null, .failure(error))
    continue
  }
  let id: JSONValue
  if case .object(let object) = request { id = object["id"] ?? .null } else { id = .null }
  respond(
    id: id,
    Result {
      try peer.handle(request.member("method").asString(), request.member("params"))
    })
}
