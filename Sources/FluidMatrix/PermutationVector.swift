import FluidJS
import FluidMergeTree

/// Ports matrix/src/permutationvector.ts. Client owns ordering; handles own local storage identity.
public final class PermutationVector {
  public private(set) var client: Client
  private var table = HandleTable()
  public let handleCache = HandleCache()
  public var changed: ((Int, Int, Int) -> Void)?
  public var recycled: (([Int]) -> Void)?
  public init(id: JSString) {
    client = Client(id: id, collaborating: false)
    install()
  }
  private func install() {
    client.segmentFactory = PermutationSegment.fromJSONObject
    client.delta = { [weak self] op, changes, _ in
      guard let self else { return }
      let insert = try op.member("type").asInt() == 0
      let ranges = changes.map { ($0.segment, self.client.getPosition($0.segment)) }.sorted { $0.1 < $1.1 }
      if insert && !self.client.rollingBack {
        for (segment, _) in ranges {
          guard let segment = segment as? PermutationSegment else { throw JSONDecodingError("expected permutation segment") }
          segment.start = PermutationSegment.unallocated
        }
      }
      for (_, position) in ranges { self.handleCache.itemsChanged(position) }
      for (segment, position) in ranges { self.changed?(position, insert ? 0 : segment.length, insert ? segment.length : 0) }
    }
    client.maintenance = { [weak self] type, changes, _ in
      guard let self, type == .unlink else { return }
      var handles: [Int] = []
      for change in changes {
        if let segment = change.segment as? PermutationSegment, segment.start >= 1 {
          handles.append(contentsOf: segment.start..<(segment.start + segment.length))
        }
      }
      self.recycled?(handles)
      for handle in handles { self.table.free(handle) }
    }
  }
  public var length: Int { client.length }
  public func maybeHandle(_ position: Int) throws -> Int {
    try handleCache.getHandle(position, client: client)
  }
  public func allocatedHandle(_ position: Int, perspective: Perspective = .local) throws -> Int {
    guard let found = client.getContainingSegment(position, perspective: perspective), let segment = found.segment as? PermutationSegment else { throw JSONDecodingError("matrix position out of bounds") }
    if segment.start >= 1 { return segment.start + found.offset }
    guard let isolated = try client.isolateSegment(position, perspective: perspective) as? PermutationSegment else { throw JSONDecodingError("expected permutation segment") }
    isolated.start = table.allocate()
    if Perspective.local.contains(isolated) { handleCache.addHandle(client.getPosition(isolated), isolated.start) }
    return isolated.start
  }
  public func adjust(_ position: Int, sequence: Int, sender: JSString) throws -> (handle: Int, position: Int?) {
    let perspective = Perspective.prior(sequence: sequence, client: sender)
    // Upstream adjustPosition returns the removed span's start, not start + offset.
    if let found = client.getContainingSegment(position, perspective: perspective),
      !Perspective.local.contains(found.segment), let segment = found.segment as? PermutationSegment, segment.start >= 1 {
      return (segment.start, nil)
    }
    let handle = try allocatedHandle(position, perspective: perspective)
    guard let found = client.getContainingSegment(position, perspective: perspective) else { throw JSONDecodingError("missing adjusted segment") }
    return (handle, Perspective.local.contains(found.segment) ? client.getPosition(found.segment) + found.offset : nil)
  }
  public func snapshot(minimum: Int, sequence: Int, wireId: JSString?) throws -> JSONValue {
    try client.updateSequenceNumbers(minimum: minimum, sequence: sequence)
    var snapshot = try client.snapshot(version: "v1")
    // TS stamps retain short-client identity; summaries resolve it to the current long ID.
    if let wireId, wireId != client.id {
      var snapshotFields = try snapshot.asObject()
      var blobs = try snapshot.member("tree").asObject()
      for (name, blob) in blobs.entries {
        var fields = try blob.asObject()
        var chunk = try JSON.parse(blob.member("content").asString().description).asObject()
        if case .array(let segments) = chunk["segments"] {
          chunk["segments"] = .array(segments.map { segment in
            guard case .object(var wrapper) = segment else { return segment }
            for key: JSString in ["client", "removedClient"] where wrapper[key] == .string(self.client.id) { wrapper[key] = .string(wireId) }
            if case .array(let ids) = wrapper["removedClientIds"] { wrapper["removedClientIds"] = .array(ids.map { $0 == .string(self.client.id) ? .string(wireId) : $0 }) }
            return .object(wrapper)
          })
        }
        fields["content"] = .string(JSString(JSON.stringify(.object(chunk))))
        blobs[name] = .object(fields)
      }
      snapshotFields["tree"] = .object(blobs)
      snapshot = .object(snapshotFields)
    }
    return matrixObject([("type", .number(1)), ("tree", matrixObject([
      ("segments", snapshot),
      ("handleTable", matrixBlob(.array(table.summary.map { .number(Double($0)) }))),
    ]))])
  }
  public func load(_ summary: JSONValue) throws {
    table = try HandleTable(JSON.parse(summary.member("tree").member("handleTable").member("content").asString().description).asArray().map { try $0.asInt() })
    client = try SnapshotLoader(segmentFactory: PermutationSegment.fromJSONObject).load(summary.member("tree").member("segments"), id: client.id)
    handleCache.itemsChanged(0)
    install()
  }
}

func matrixObject(_ entries: [(JSString, JSONValue)]) -> JSONValue {
  var result = JSObject<JSONValue>()
  for (key, value) in entries { result[key] = value }
  return .object(result)
}
func matrixBlob(_ value: JSONValue) -> JSONValue { matrixObject([("type", .number(2)), ("content", .string(JSString(JSON.stringify(value))))]) }
