import FluidJS

/// Ports types/persisted-types/0.0.1.ts.
public struct IdCreationRange {
  public let sessionId: String
  public let ids: IDs?
  public struct IDs {
    public let firstGenCount: Double
    public let count: Double
    public let requestedClusterSize: Double
    public let localIdRanges: [[Double]]
    public init(
      firstGenCount: Double, count: Double, requestedClusterSize: Double, localIdRanges: [[Double]]
    ) {
      self.firstGenCount = firstGenCount
      self.count = count
      self.requestedClusterSize = requestedClusterSize
      self.localIdRanges = localIdRanges
    }
  }
  public init(sessionId: String, ids: IDs? = nil) {
    self.sessionId = sessionId
    self.ids = ids
  }
}
extension IdCreationRange {
  public var json: JSONValue {
    var range = JSObject<JSONValue>()
    range["sessionId"] = .string(JSString(sessionId))
    if let ids {
      var data = JSObject<JSONValue>()
      data["firstGenCount"] = .number(ids.firstGenCount)
      data["count"] = .number(ids.count)
      data["requestedClusterSize"] = .number(ids.requestedClusterSize)
      data["localIdRanges"] = .array(ids.localIdRanges.map { .array($0.map(JSONValue.number)) })
      range["ids"] = .object(data)
    }
    return .object(range)
  }
  public init(json: JSONValue) throws {
    let sessionId = try json.member("sessionId").asString().description
    let ids: IDs?
    if let data = try json.asObject()["ids"] {
      let ranges = try data.member("localIdRanges").asArray().map { pair in
        let values = try pair.asArray()
        try require(values.count == 2, "Malformed local ID range")
        return try values.map { try $0.asNumber() }
      }
      ids = try IDs(
        firstGenCount: data.member("firstGenCount").asNumber(),
        count: data.member("count").asNumber(),
        requestedClusterSize: data.member("requestedClusterSize").asNumber(), localIdRanges: ranges)
    } else {
      ids = nil
    }
    self.init(sessionId: sessionId, ids: ids)
  }
}
