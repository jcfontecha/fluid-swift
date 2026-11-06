import FluidJS

/// Ports snapshotV1.ts: retained sequenced metadata and live empty-property
/// normalization. Coalesced payloads are independent clones, never live segments.
public final class SnapshotV1 {
  private let client: Client
  public init(client: Client) { self.client = client }
  public func emit() throws -> JSONValue {
    var payloads: [(json: JSONValue, length: Int)] = []
    var candidate: BaseSegment?
    var originalCandidate: BaseSegment?
    func flush() {
      if originalCandidate?.properties?.isEmpty == true { originalCandidate?.properties = nil }
      if let candidate { payloads.append((candidate.toJSON(), candidate.length)) }
      candidate = nil
      originalCandidate = nil
    }
    for original in client.segments {
      guard original.insertion.sequence != -1,
        original.removals.first.map({ $0.sequence != -1 && $0.sequence <= client.minimumSequence })
          != true
      else { continue }
      let segment = original.clone()
      if segment.properties?.isEmpty == true { segment.properties = nil }
      let removals = segment.removals.filter { $0.sequence != -1 }
      if segment.insertion.sequence <= client.minimumSequence && removals.isEmpty {
        if let previous = candidate, previous.canAppend(segment),
          previous.properties == segment.properties,
          let lhs = previous.text, let rhs = segment.text
        {
          previous.text = JSString(utf16: lhs.utf16 + rhs.utf16)
          originalCandidate = nil
        } else {
          flush()
          candidate = segment
          originalCandidate = original
        }
      } else {
        flush()
        if original.properties?.isEmpty == true { original.properties = nil }
        var wrapper = JSObject<JSONValue>()
        wrapper["json"] = segment.toJSON()
        if segment.insertion.sequence > client.minimumSequence {
          wrapper["seq"] = .number(Double(segment.insertion.sequence))
          wrapper["client"] = .string(segment.insertion.client)
        }
        if let first = removals.first {
          wrapper["removedSeq"] = .number(Double(first.sequence))
          wrapper["removedClient"] = .string(first.client)
          wrapper["removedClientIds"] = .array(segment.removals.map { .string($0.client) })
        }
        payloads.append((.object(wrapper), segment.length))
      }
    }
    flush()
    return try emitSnapshotChunks(payloads, client: client, legacy: false, catchup: [])
  }
}
