import FluidJS

/// Ports snapshotlegacy.ts: minimum-sequence materialization and catchup blobs.
public final class SnapshotLegacy {
  private let client: Client
  public init(client: Client) { self.client = client }
  public func emit(catchup: [JSONValue] = []) throws -> JSONValue {
    var payloads: [(json: JSONValue, length: Int)] = []
    var candidate: BaseSegment?
    func flush() {
      if let candidate { payloads.append((candidate.toJSON(), candidate.length)) }
      candidate = nil
    }
    for original in client.segments {
      guard original.insertion.sequence != -1,
        original.insertion.sequence <= client.minimumSequence,
        original.removals.first.map({ $0.sequence != -1 && $0.sequence <= client.minimumSequence })
          != true
      else { continue }
      let segment = original.clone()
      segment.properties = segment.propertyManager.getAtSeq(segment.properties)
      if segment.properties?.isEmpty == true { segment.properties = nil }
      if let previous = candidate, previous.canAppend(segment),
        matchProperties(previous.properties, segment.properties)
      {
        previous.appendPayload(segment)
      } else {
        flush()
        candidate = segment
      }
    }
    flush()
    return try emitSnapshotChunks(payloads, client: client, legacy: true, catchup: catchup)
  }
}
