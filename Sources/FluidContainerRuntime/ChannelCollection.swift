import FluidJS
import FluidDatastore

/// Ports channelCollection.ts routing to real datastore contexts or the H4 observation seam.
public final class ChannelCollection {
  public var contexts: Set<JSString>?
  public var deleted: Set<JSString> = []
  public var onDispatch: (JSString, JSONValue) throws -> Void = { _, _ in }
  var datastores: [JSString: FluidDataStoreRuntime] = [:]
  var datastoreOrder: [JSString] = []
  public var onSubmitDatastoreSignal: (JSString, JSString, JSONValue, JSString?) throws -> Void = { _, _, _, _ in }
  var datastoreOutbound: [(JSString, DatastoreMessage)] = []
  var datastoreMetadata: [Int: any ChannelOpMetadata] = [:]
  var nextDatastoreMetadata = 0
  public init() {}
  private func dispatch(_ address: JSString, _ value: JSONValue) throws {
    guard let runtime = datastores[address] else {
      try onDispatch(address, value)
      return
    }
    if let signal = try field(value, "signal") {
      runtime.processSignal(signal, local: try value.member("local") == .bool(true))
      return
    }
    let local = try value.member("local") == .bool(true)
    let messages = try value.member("messagesContent").asArray().map { entry in
      let metadata = try field(entry, "localOpMetadata")
      let token = try metadata.map { try $0.asInt() }
      let md = token.flatMap { datastoreMetadata[$0] }
      if let token { datastoreMetadata.removeValue(forKey: token) }
      return ChannelMessage(contents: try entry.member("contents"), metadata: md, clientSequenceNumber: try field(entry, "clientSequenceNumber")?.asInt() ?? 0)
    }
    try runtime.processMessages(envelope: value.member("envelope"), messages: messages, local: local)
  }
  public func processMessages(envelope: JSONValue, messagesContent: [JSONValue], local: Bool) throws {
    let type = try envelope.member("type").asString()
    guard type == "component" else {
      try onDispatch("channels", object([("envelope", envelope), ("messagesContent", .array(messagesContent)), ("local", .bool(local))]))
      return
    }
    var address: JSString?
    var contextType: JSString?
    var bunch: [JSONValue] = []
    func flush() throws {
      guard let address, let contextType else { return }
      var stripped = try envelope.asObject()
      stripped["type"] = .string(contextType)
      try dispatch(address, object([("envelope", .object(stripped)), ("messagesContent", .array(bunch)), ("local", .bool(local))]))
      bunch.removeAll(keepingCapacity: true)
    }
    for entry in messagesContent {
      let contents = try entry.member("contents")
      let nextAddress = try contents.member("address").asString()
      if deleted.contains(nextAddress) { continue }
      try require((contexts?.contains(nextAddress) ?? true), "No context for op")
      let payload = try contents.member("contents")
      let nextType = try payload.member("type").asString()
      if nextAddress != address || nextType != contextType { try flush() }
      var stripped = JSObject<JSONValue>()
      stripped["contents"] = try field(payload, "content")
      for (key, value) in try entry.asObject().entries where key != "contents" { stripped[key] = value }
      bunch.append(.object(stripped))
      address = nextAddress
      contextType = nextType
    }
    try flush()
  }
  public func processSignal(address: JSString, signal: JSONValue, local: Bool) throws {
    if deleted.contains(address) { return }
    guard (contexts?.contains(address) ?? true) else {
      try require(!local, "0x163")
      return
    }
    try dispatch(address, object([("signal", signal), ("local", .bool(local))]))
  }
}
