import FluidJS

extension MergeTreeClient {
  /// Serializes text/marker insertions, ordinary removals and raw annotations.
  /// Obliterate and snapshot loading remain unimplemented.
  public func snapshot(version: JSString) throws -> JSONValue {
    guard version == "legacy" || version == "v1" else {
      throw JSONDecodingError("unsupported snapshot version")
    }
    let legacy = version == "legacy"
    var payloads: [(json: JSONValue, length: Int)] = []
    var candidate: Segment?
    var candidateOriginalIndex: Int?
    func flush() {
      if !legacy, let index = candidateOriginalIndex {
        normalizeSnapshotProperties(at: index)
      }
      if let value = candidate { payloads.append((value.toJSON(), value.length)) }
      candidate = nil
      candidateOriginalIndex = nil
    }
    for (index, original) in segments.enumerated() {
      var segment = original
      if legacy {
        segment.properties = segment.propertyManager.getAtSeq(segment.properties)
      }
      if segment.properties?.isEmpty == true { segment.properties = nil }
      let insertion = segment.insertion
      let removals = segment.removals.filter { $0.sequence != -1 }
      if insertion.sequence == -1 || removals.first.map({ $0.sequence <= minimumSequence }) == true
      {
        continue
      }
      if legacy && insertion.sequence > minimumSequence { continue }
      if legacy || (insertion.sequence <= minimumSequence && removals.isEmpty) {
        if var previous = candidate, previous.canAppend(segment),
          previous.properties == segment.properties,
          var text = previous.text, let next = segment.text
        {
          text.utf16.append(contentsOf: next.utf16)
          previous.text = text
          candidate = previous
          candidateOriginalIndex = nil
        } else {
          flush()
          candidate = segment
          candidateOriginalIndex = index
        }
      } else {
        flush()
        normalizeSnapshotProperties(at: index)
        var wrapper = JSObject<JSONValue>()
        wrapper["json"] = segment.toJSON()
        if insertion.sequence > minimumSequence {
          wrapper["seq"] = .number(Double(insertion.sequence))
          wrapper["client"] = .string(insertion.client)
        }
        if let first = removals.first {
          wrapper["removedSeq"] = .number(Double(first.sequence))
          wrapper["removedClient"] = .string(first.client)
          wrapper["removedClientIds"] = .array(removals.map { .string($0.client) })
        }
        payloads.append((.object(wrapper), segment.length))
      }
    }
    flush()
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
        ("orderedChunkMetadata", ordered), ("sequenceNumber", .number(Double(minimumSequence))),
        ("totalLength", .number(Double(total))),
        ("totalSegmentCount", .number(Double(payloads.count))),
      ])
      : object([
        ("minSequenceNumber", .number(Double(minimumSequence))),
        ("sequenceNumber", .number(Double(currentSequence))), ("orderedChunkMetadata", ordered),
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
        fields["chunkSequenceNumber"] = .number(Double(minimumSequence))
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
    return object([("type", .number(1)), ("tree", .object(tree))])
  }
}
