import FluidJS

/// Synchronous segment engine. Callers serialize access on their container executor.
public final class MergeTreeClient {
  public let id: JSString
  public private(set) var currentSequence = 0
  public private(set) var minimumSequence = 0
  public private(set) var segments: ContiguousArray<Segment> = []
  private var localSequence = 0
  private var pending: [Int] = []
  private var pendingHead = 0

  public init(id: JSString) { self.id = id }
  public var length: Int {
    segments.reduce(0) { $0 + (Perspective.local.contains($1) ? $1.length : 0) }
  }
  public var text: JSString {
    var units = ContiguousArray<UInt16>()
    units.reserveCapacity(length)
    for segment in segments where Perspective.local.contains(segment) {
      if let text = segment.text { units.append(contentsOf: text.utf16) }
    }
    return JSString(utf16: units)
  }
  public func length(from perspective: Perspective) -> Int {
    segments.reduce(0) { $0 + (perspective.contains($1) ? $1.length : 0) }
  }
  public func insert(at position: Int, text: JSString) throws -> JSONValue {
    try edit(
      object([("pos1", .number(Double(position))), ("seg", .string(text)), ("type", .number(0))]))
  }
  public func remove(start: Int, end: Int) throws -> JSONValue {
    try edit(
      object([
        ("pos1", .number(Double(start))), ("pos2", .number(Double(end))), ("type", .number(1)),
      ]))
  }
  public func edit(_ operation: JSONValue) throws -> JSONValue {
    let type = try operation.member("type").asInt()
    guard type == 0 || type == 1 || type == 2 else {
      throw JSONDecodingError("merge-tree operation \(type) is not implemented")
    }
    if type == 2 {
      _ = try operation.member("props").asObject()
    }
    let start = try operation.member("pos1").asInt()
    guard start >= 0, start <= length else { throw JSONDecodingError("RangeOutOfBounds") }
    if type == 1 || type == 2 {
      let end = try operation.member("pos2").asInt()
      guard start < length, end > start else { throw JSONDecodingError("RangeOutOfBounds") }
    }
    localSequence += 1
    let stamp = Stamp(sequence: -1, client: id, localSequence: localSequence)
    try apply(operation, perspective: .local, stamp: stamp)
    pending.append(localSequence)
    return operation
  }
  public func process(
    _ operation: JSONValue, sender: JSString, sequence: Int, referenceSequence: Int
  ) throws {
    guard sequence >= currentSequence, referenceSequence >= minimumSequence,
      referenceSequence < sequence
    else { throw JSONDecodingError("invalid sequence window") }
    if sender == id {
      guard pendingHead < pending.count else {
        throw JSONDecodingError("ack without pending operation")
      }
      let local = pending[pendingHead]
      pendingHead += 1
      for index in segments.indices {
        segments[index].propertyManager.ack(localSequence: local)
        if segments[index].insertion.sequence == -1
          && segments[index].insertion.localSequence == local
        {
          segments[index].insertion = Stamp(sequence: sequence, client: sender)
        }
        for removal in segments[index].removals.indices
        where segments[index].removals[removal].sequence == -1
          && segments[index].removals[removal].localSequence == local
        {
          segments[index].removals[removal] = Stamp(sequence: sequence, client: sender)
        }
        segments[index].removals.sort()
      }
      if pendingHead == pending.count {
        pending.removeAll(keepingCapacity: true)
        pendingHead = 0
      }
    } else {
      try apply(
        operation, perspective: .prior(sequence: referenceSequence, client: sender),
        stamp: Stamp(sequence: sequence, client: sender))
    }
    currentSequence = sequence
  }
  func normalizeSnapshotProperties(at index: Int) {
    if segments[index].properties?.isEmpty == true {
      segments[index].properties = nil
    }
  }
  public func advanceMinimum(to sequence: Int) throws {
    guard sequence >= minimumSequence, sequence <= currentSequence else {
      throw JSONDecodingError("invalid minimum sequence")
    }
    minimumSequence = sequence
  }
  private func splitBoundary(_ position: Int, perspective: Perspective) throws {
    var remaining = position
    for index in segments.indices where perspective.contains(segments[index]) {
      let count = segments[index].length
      if remaining > 0 && remaining < count {
        let right = try segments[index].split(at: remaining)
        segments.insert(right, at: index + 1)
        return
      }
      remaining -= count
      if remaining <= 0 { return }
    }
  }
  private func apply(_ operation: JSONValue, perspective: Perspective, stamp: Stamp) throws {
    let type = try operation.member("type").asInt()
    guard type == 0 || type == 1 || type == 2 else {
      throw JSONDecodingError("merge-tree operation \(type) is not implemented")
    }
    if type == 2 {
      _ = try operation.member("props").asObject()
    }
    let start = try operation.member("pos1").asInt()
    try splitBoundary(start, perspective: perspective)
    if type == 0 {
      let payload = try operation.member("seg")
      let segment: Segment
      switch payload {
      case .string(let text): segment = Segment(text: text, insertion: stamp)
      case .object(let fields):
        let props = try fields["props"].map { try $0.asObject() }
        if let text = fields["text"] {
          segment = Segment(text: try text.asString(), insertion: stamp, properties: props)
        } else {
          segment = Segment(
            markerType: try payload.member("marker").member("refType").asInt(), insertion: stamp,
            properties: props)
        }
      default: throw JSONDecodingError("invalid segment payload")
      }
      if segment.length == 0 { return }
      var position = start
      var destination = segments.count
      for index in segments.indices {
        let leaf = segments[index]
        if let first = leaf.removals.first, first.sequence != -1, first.sequence <= minimumSequence
        {
          continue
        }
        let count = perspective.contains(leaf) ? leaf.length : 0
        let winsTie =
          position == 0
          && (leaf.insertion < stamp
            || leaf.removals.first.map { $0.sequence != -1 && stamp < $0 } == true)
        if position < count || (position == count && winsTie) {
          destination = index
          break
        }
        position -= count
      }
      segments.insert(segment, at: destination)
    } else {
      let end = try operation.member("pos2").asInt()
      try splitBoundary(end, perspective: perspective)
      var position = 0
      for index in segments.indices where perspective.contains(segments[index]) {
        let count = segments[index].length
        if position >= start && position < end {
          if type == 2 {
            let updates = try operation.member("props").asObject()
            var properties = segments[index].properties
            segments[index].propertyManager.handleProperties(updates, properties: &properties, stamp: stamp)
            segments[index].properties = properties
          } else {
            segments[index].removals.append(stamp)
            segments[index].removals.sort()
          }
        }
        position += count
      }
    }
  }
}
