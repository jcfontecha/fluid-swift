import FluidJS

// Ports snapshot chunk serialization shared by SnapshotLegacy and SnapshotV1.
func emitSnapshotChunks(
  _ payloads: [(json: JSONValue, length: Int)], client: Client,
  legacy: Bool, catchup: [JSONValue]
) throws -> JSONValue {
  var chunks: [[(json: JSONValue, length: Int)]] = [[]]
  var chunkLength = 0
  for item in payloads {
    if chunkLength >= 10_000 && (!legacy || chunks.count == 1) {
      chunks.append([])
      chunkLength = 0
    }
    chunks[chunks.count - 1].append(item)
    chunkLength += item.length
  }
  let total = payloads.reduce(0) { $0 + $1.length }
  let names = chunks.indices.map { index in
    index == 0 ? "header" : legacy ? "body" : "body_\(index - 1)"
  }
  let ordered = JSONValue.array(names.map { object([("id", .string(JSString($0)))]) })
  let metadata =
    legacy
    ? object([
      ("orderedChunkMetadata", ordered),
      ("sequenceNumber", .number(Double(client.minimumSequence))),
      ("totalLength", .number(Double(total))),
      ("totalSegmentCount", .number(Double(payloads.count))),
    ])
    : object([
      ("minSequenceNumber", .number(Double(client.minimumSequence))),
      ("sequenceNumber", .number(Double(client.currentSequence))),
      ("orderedChunkMetadata", ordered),
      ("totalLength", .number(Double(total))),
      ("totalSegmentCount", .number(Double(payloads.count))),
    ])
  var tree = JSObject<JSONValue>()
  var start = 0
  for (index, chunk) in chunks.enumerated() {
    var fields = JSObject<JSONValue>()
    let length = chunk.reduce(0) { $0 + $1.length }
    if legacy {
      fields["chunkStartSegmentIndex"] = .number(Double(start))
      fields["chunkSegmentCount"] = .number(Double(chunk.count))
      fields["chunkLengthChars"] = .number(Double(length))
      fields["totalLengthChars"] = .number(Double(total))
      fields["totalSegmentCount"] = .number(Double(payloads.count))
      fields["chunkSequenceNumber"] = .number(Double(client.minimumSequence))
      fields["segmentTexts"] = .array(chunk.map(\.json))
    } else {
      fields["version"] = .string("1")
      fields["segmentCount"] = .number(Double(chunk.count))
      fields["length"] = .number(Double(length))
      fields["segments"] = .array(chunk.map(\.json))
      fields["startIndex"] = .number(Double(start))
    }
    if index == 0 { fields["headerMetadata"] = metadata }
    tree[JSString(names[index])] = object([
      ("type", .number(2)), ("content", .string(JSString(JSON.stringify(.object(fields))))),
    ])
    start += chunk.count
  }
  if !catchup.isEmpty {
    guard legacy else { throw JSONDecodingError("V1 does not support catchup operations") }
    let messages = try catchup.map { message in
      var fields = try message.asObject()
      fields["term"] = nil
      return JSONValue.object(fields)
    }
    tree["catchupOps"] = object([
      ("type", .number(2)),
      ("content", .string(JSString(JSON.stringify(.array(messages))))),
    ])
  }
  return object([("type", .number(1)), ("tree", .object(tree))])
}
