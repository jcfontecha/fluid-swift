import FluidJS
import FluidMergeTree

/// Ports sequenceDeltaEvent.ts SequenceDeltaEvent. Ranges resolve live segment positions lazily.
public final class SequenceDeltaEvent: SequenceEventClass {
  /// Ports SharedSegmentSequence.createOpsFromDelta for legacy catchup normalization.
  func createOps() throws -> [JSONValue] {
    var ops: [JSONValue] = []
    for range in ranges {
      let position = range.position
      let end = position + range.segment.length
      if deltaOperation == 0 {
        ops.append(sequenceObject([("pos1", .number(Double(position))), ("seg", range.segment.clone().toJSON()), ("type", .number(0))]))
        continue
      }
      var props = JSObject<JSONValue>()
      for (key, _) in range.propertyDeltas.entries {
        props[key] = range.segment.properties?[key] ?? .null
      }
      if let previous = ops.last {
        var fields = try previous.asObject()
        let matches = try deltaOperation == 1
          ? fields["pos1"] == .number(Double(position))
          : fields["pos2"] == .number(Double(position)) && matchProperties(try fields["props"].map { try $0.asObject() }, props)
        if matches {
          let oldEnd = try previous.member("pos2").asInt()
          fields["pos2"] = .number(Double(oldEnd + range.segment.length))
          ops[ops.count - 1] = .object(fields)
          continue
        }
      }
      var fields = JSObject<JSONValue>()
      fields["pos1"] = .number(Double(position))
      fields["pos2"] = .number(Double(end))
      if deltaOperation == 2 { fields["props"] = .object(props) }
      fields["type"] = .number(Double(deltaOperation))
      ops.append(.object(fields))
    }
    return ops
  }

}
