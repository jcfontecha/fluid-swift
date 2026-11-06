import FluidJS

/// Ports snapshotLoader.ts and snapshotChunks.ts legacy/V1 decoding.
/// Uses FluidJS for every snapshot byte; decoded counters remain checked integers.
public final class SnapshotLoader {
  public init() {}

  public func load(_ summary: JSONValue, id: JSString) throws -> Client {
    let blobs = try summary.member("tree").asObject()
    func chunk(_ name: JSString) throws -> JSONValue {
      guard let blob = blobs[name] else { throw JSONDecodingError("missing snapshot chunk") }
      let value = try JSON.parse(blob.member("content").asString().description)
      if let version = try value.asObject()["version"], version != .string("1") {
        throw JSONDecodingError("unsupported snapshot version")
      }
      return value
    }
    let header = try chunk("header")
    let fields = try header.asObject()
    let legacy = fields["version"] == nil
    let metadata: JSONValue
    if let existing = fields["headerMetadata"] {
      metadata = existing
    } else if legacy {
      var names: [JSONValue] = [object([("id", .string("header"))])]
      if try header.member("chunkLengthChars").asInt() < header.member("totalLengthChars").asInt() {
        names.append(object([("id", .string("body"))]))
      }
      var values = JSObject<JSONValue>()
      values["orderedChunkMetadata"] = .array(names)
      values["sequenceNumber"] = try header.member("chunkSequenceNumber")
      values["minSequenceNumber"] = fields["chunkMinSequenceNumber"]
      values["totalLength"] = try header.member("totalLengthChars")
      values["totalSegmentCount"] = try header.member("totalSegmentCount")
      metadata = .object(values)
    } else {
      throw JSONDecodingError("header metadata not available")
    }
    let sequence = try metadata.member("sequenceNumber").asInt()
    let minimum = try metadata.asObject()["minSequenceNumber"].map { try $0.asInt() } ?? sequence
    guard minimum >= 0, sequence >= minimum else {
      throw JSONDecodingError("invalid snapshot window")
    }
    let names = try metadata.member("orderedChunkMetadata").asArray().map {
      try $0.member("id").asString()
    }
    guard names.first == "header", Set(names).count == names.count else {
      throw JSONDecodingError("invalid snapshot chunks")
    }
    let client = Client(id: id)
    var totalLength = 0
    var totalCount = 0
    for (index, name) in names.enumerated() {
      let value = index == 0 ? header : try chunk(name)
      let values = try value.asObject()
      guard values["attribution"] == nil else {
        throw JSONDecodingError("snapshot attribution requires a policy")
      }
      let old = values["version"] == nil
      let specs = try value.member(old ? "segmentTexts" : "segments").asArray()
      let segments = try specs.map { try decodeSegment($0) }
      let declaredCount = try value.member(old ? "chunkSegmentCount" : "segmentCount").asInt()
      let declaredLength = try value.member(old ? "chunkLengthChars" : "length").asInt()
      guard declaredCount == segments.count,
        declaredLength == segments.reduce(0, { $0 + $1.length })
      else {
        throw JSONDecodingError("snapshot chunk totals mismatch")
      }
      totalLength += declaredLength
      totalCount += declaredCount
      if index == 0 {
        client.loadHeader(segments, minimum: minimum, sequence: sequence)
      } else {
        for segment in segments { client.mergeTree.insert(segment, before: nil) }
      }
    }
    guard totalLength == (try metadata.member("totalLength").asInt()),
      totalCount == (try metadata.member("totalSegmentCount").asInt())
    else {
      throw JSONDecodingError("snapshot totals mismatch")
    }
    let extra = blobs.entries.map(\.0).filter { !names.contains($0) }
    guard extra.count <= 1 else { throw JSONDecodingError("unexpected snapshot blobs") }
    if let name = extra.first, let blob = blobs[name] {
      let messages = try JSON.parse(blob.member("content").asString().description).asArray()
      for message in messages { try client.replayCatchup(message) }
    }
    return client
  }

  private func decodeSegment(_ spec: JSONValue) throws -> BaseSegment {
    let wrapper: JSObject<JSONValue>?
    if case .object(let fields) = spec, fields["json"] != nil {
      wrapper = fields
    } else {
      wrapper = nil
    }
    let payload = wrapper?["json"] ?? spec
    let sequence = try wrapper?["seq"].map { try $0.asInt() } ?? 0
    let sender = try wrapper?["client"].map { try $0.asString() } ?? ""
    let stamp = Stamp(sequence: sequence, client: sender)
    let segment: BaseSegment
    if case .string(let text) = payload {
      segment = TextSegment(text: text, insertion: stamp)
    } else {
      let fields = try payload.asObject()
      let properties = try fields["props"].map { try $0.asObject() }
      if let text = fields["text"] {
        segment = TextSegment(text: try text.asString(), insertion: stamp, properties: properties)
      } else {
        segment = Marker(
          refType: try payload.member("marker").member("refType").asInt(),
          insertion: stamp, properties: properties)
      }
    }
    if let removal = wrapper?["removedSeq"] {
      let ids: [JSONValue]
      if let multiple = wrapper?["removedClientIds"] {
        ids = try multiple.asArray()
      } else if let single = wrapper?["removedClient"] {
        ids = [single]
      } else {
        throw JSONDecodingError("missing removal clients")
      }
      for value in ids {
        segment.removals.append(Stamp(sequence: try removal.asInt(), client: try value.asString()))
      }
    }
    if wrapper?["movedSeq"] != nil {
      throw JSONDecodingError("obliterate snapshot metadata is not implemented")
    }
    segment.removals.sort()
    return segment
  }
}
