import FluidJS

/// Synchronous segment engine. Callers serialize access on their container executor.
public final class Client {
  public let id: JSString
  let referencesCanSlideToEndpoint: Bool
  public private(set) var currentSequence = 0
  public private(set) var minimumSequence = 0
  let mergeTree = MergeTree()
  let startOfTree = Marker(refType: 0, insertion: Stamp(sequence: 0, client: ""))
  let endOfTree = Marker(refType: 0, insertion: Stamp(sequence: 0, client: ""))
  public var segments: ContiguousArray<BaseSegment> { mergeTree.segments }
  var localSequence = 0
  var lastNormalization: (sequence: Int, localSequence: Int)?
  var pending: [SegmentGroup] = []
  var pendingHead = 0
  var pendingMessages: [Int] = []

  public init(id: JSString, referencesCanSlideToEndpoint: Bool = false) {
    self.id = id
    self.referencesCanSlideToEndpoint = referencesCanSlideToEndpoint
  }
  func loadHeader(_ segments: [BaseSegment], minimum: Int, sequence: Int) {
    mergeTree.reload(segments)
    minimumSequence = minimum
    currentSequence = sequence
  }
  func replayCatchup(_ message: JSONValue) throws {
    let sequence = try message.member("sequenceNumber").asInt()
    let sender = try message.member("clientId").asString()
    let reference = try message.member("referenceSequenceNumber").asInt()
    guard sequence > currentSequence, reference >= minimumSequence, reference < sequence else {
      throw JSONDecodingError("invalid catchup sequence window")
    }
    func replay(_ operation: JSONValue) throws {
      if try operation.member("type").asInt() == 3 {
        for child in try operation.member("ops").asArray() { try replay(child) }
      } else {
        try apply(
          operation, perspective: .prior(sequence: reference, client: sender),
          stamp: Stamp(sequence: sequence, client: sender))
        mergeTree.zamboni(minimum: minimumSequence)
      }
    }
    try replay(message.member("contents"))
    currentSequence = sequence
    try advanceMinimum(to: message.member("minimumSequenceNumber").asInt())
  }
  public var length: Int {
    mergeTree.root.localLength
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
    mergeTree.root.length(from: perspective)
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
    let group = SegmentGroup(localSequence: localSequence, operation: operation)
    try apply(operation, perspective: .local, stamp: stamp, group: group)
    pending.append(group)
    pendingMessages.append(localSequence)
    return operation
  }
  public func process(
    _ operation: JSONValue, sender: JSString, sequence: Int, referenceSequence: Int
  ) throws {
    try processOperation(
      operation, sender: sender, sequence: sequence, referenceSequence: referenceSequence)
    currentSequence = sequence
    if sender == id {
      guard !pendingMessages.isEmpty else { throw JSONDecodingError("ack without pending message") }
      pendingMessages.removeFirst()
    }
  }
  private func processOperation(
    _ operation: JSONValue, sender: JSString, sequence: Int, referenceSequence: Int
  ) throws {
    guard sequence >= currentSequence, referenceSequence >= minimumSequence,
      referenceSequence < sequence
    else { throw JSONDecodingError("invalid sequence window") }
    if try operation.member("type").asInt() == 3 {
      for child in try operation.member("ops").asArray() {
        try processOperation(
          child, sender: sender, sequence: sequence, referenceSequence: referenceSequence)
      }
      return
    }
    var removed: [BaseSegment] = []
    if sender == id {
      guard pendingHead < pending.count else {
        throw JSONDecodingError("ack without pending operation")
      }
      let group = pending[pendingHead]
      let local = group.localSequence
      pendingHead += 1
      for segment in group.segments {
        let before = segment.clone()
        group.unlink(segment)
        mergeTree.schedule(segment, sequence: sequence, current: currentSequence)
        segment.propertyManager.ack(localSequence: local)
        if segment.insertion.sequence == -1
          && segment.insertion.localSequence == local
        {
          segment.insertion = Stamp(sequence: sequence, client: sender)
        }
        for removal in segment.removals.indices
        where segment.removals[removal].sequence == -1
          && segment.removals[removal].localSequence == local
        {
          removed.append(segment)
          segment.removals[removal] = Stamp(sequence: sequence, client: sender)
        }
        segment.removals.sort()
        mergeTree.update(segment, before: before)
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
    slideReferences(on: removed)
    mergeTree.zamboni(minimum: minimumSequence)
  }
  public func advanceMinimum(to sequence: Int) throws {
    guard sequence >= minimumSequence, sequence <= currentSequence else {
      throw JSONDecodingError("invalid minimum sequence")
    }
    if sequence > minimumSequence {
      minimumSequence = sequence
      mergeTree.zamboni(minimum: sequence)
    }
  }
  private func apply(
    _ operation: JSONValue, perspective: Perspective, stamp: Stamp, group: SegmentGroup? = nil
  ) throws {
    let removed = try mergeTree.apply(
      operation, perspective: perspective, stamp: stamp, group: group,
      minimumSequence: minimumSequence, currentSequence: currentSequence)
    slideReferences(on: removed)
  }
}
