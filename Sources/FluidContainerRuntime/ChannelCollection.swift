import FluidJS

/// Ports channelCollection.ts routing. Datastore contexts remain host-owned synchronous stubs.
public final class ChannelCollection {
  public var contexts: Set<JSString>?
  public var deleted: Set<JSString> = []
  public var onDispatch: (JSString, JSONValue) throws -> Void = { _, _ in }
  public init() {}
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
      try onDispatch(address, object([("envelope", .object(stripped)), ("messagesContent", .array(bunch)), ("local", .bool(local))]))
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
    try onDispatch(address, object([("signal", signal), ("local", .bool(local))]))
  }
}
