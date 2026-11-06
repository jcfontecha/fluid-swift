import FluidJS
import FluidMergeTree
import FluidDriverDefinitions

/// Ports intervalCollection.ts IntervalCollection: local mutations, ID indexing and slide notifications.
public final class IntervalCollection: Sequence {
  public struct Event {
    public let name: JSString
    public let interval: SequenceInterval
    public let previous: SequenceInterval?
    public let propertyDeltas: JSObject<JSONValue>
    public let local: Bool
    public let slide: Bool
  }
  public var intervalStickinessEnabled = false
  public var canSlideToEndpoint = false
  public let label: JSString
  private let client: Client
  private let localCollection = LocalIntervalCollection()
  public var event: ((Event) -> Void)?
  public var submit: ((JSString, JSONValue, IntervalLocalOpMetadata) throws -> Void)?
  private final class PendingChanges {
    var local: [IntervalLocalOpMetadata] = []
    var consensus: SequenceInterval?
    init(consensus: SequenceInterval?) { self.consensus = consensus }
  }
  private var pending = JSObject<PendingChanges>()
  public var pendingCount: Int { pending.entries.reduce(0) { $0 + $1.1.local.count } }

  private func submitDelta(_ name: JSString, _ value: JSONValue, _ metadata: IntervalLocalOpMetadata,
    consensus: SequenceInterval? = nil) throws {
    guard let submit else { return }
    let entry = pending[metadata.id] ?? PendingChanges(consensus: consensus)
    entry.local.append(metadata)
    pending[metadata.id] = entry
    try submit(name, value, metadata)
  }

  public init(client: Client, label: JSString) {
    self.client = client
    self.label = label
    localCollection.onPositionChange = { [weak self] interval, previous in
      self?.emit("changeInterval", interval, previous: previous, slide: true)
      self?.emit("changed", interval, previous: previous, slide: true)
    }
  }

  public func attachIndex(_ index: any SequenceIntervalIndex) { localCollection.attachIndex(index) }
  @discardableResult
  public func detachIndex(_ index: any SequenceIntervalIndex) -> Bool { localCollection.detachIndex(index) }

  public func getIntervalById(_ id: JSString) -> SequenceInterval? {
    localCollection.getIntervalById(id)
  }

  public func makeIterator() -> IndexingIterator<[SequenceInterval]> {
    localCollection.makeIterator()
  }

  @discardableResult
  public func add(id: JSString, start: Int, end: Int, properties: JSObject<JSONValue> = JSObject()) throws -> SequenceInterval {
    try add(id: id, start: SequencePlace(start), end: SequencePlace(end), properties: properties)
  }

  @discardableResult
  public func add(id: JSString, start: SequencePlace, end: SequencePlace, properties: JSObject<JSONValue> = JSObject()) throws -> SequenceInterval {
    guard intervalStickinessEnabled || (!start.explicitSide && !end.explicitSide) else {
      throw JSONDecodingError("interval stickiness is not enabled")
    }
    guard localCollection.getIntervalById(id) == nil else { throw JSONDecodingError("interval ID already exists") }
    let interval = try SequenceInterval(client: client, id: id, label: label, start: start, end: end,
      properties: properties, pending: submit != nil, canSlideToEndpoint: canSlideToEndpoint)
    localCollection.add(interval)
    let metadata = IntervalLocalOpMetadata(kind: .add, localSequence: client.nextLocalSequence(), id: id,
      interval: interval, changesEndpoints: true)
    try submitDelta("add", interval.serialize(), metadata)
    emit("addInterval", interval)
    return interval
  }

  @discardableResult
  public func removeIntervalById(_ id: JSString) throws -> SequenceInterval? {
    guard let interval = localCollection.getIntervalById(id) else { return nil }
    localCollection.removeExistingInterval(interval)
    let metadata = IntervalLocalOpMetadata(kind: .delete, localSequence: client.nextLocalSequence(), id: id, interval: nil)
    try submitDelta("delete", interval.serialize(), metadata, consensus: interval)
    emit("deleteInterval", interval)
    return interval
  }

  @discardableResult
  public func change(_ id: JSString, start: Int? = nil, end: Int? = nil,
    properties: JSObject<JSONValue>? = nil) throws -> SequenceInterval? {
    try changePlaces(id, start: start.map { SequencePlace($0) }, end: end.map { SequencePlace($0) }, properties: properties)
  }

  @discardableResult
  public func change(_ id: JSString, start: SequencePlace, end: SequencePlace,
    properties: JSObject<JSONValue>? = nil) throws -> SequenceInterval? {
    try changePlaces(id, start: start, end: end, properties: properties)
  }

  @discardableResult
  private func changePlaces(_ id: JSString, start: SequencePlace?, end: SequencePlace?,
    properties: JSObject<JSONValue>?) throws -> SequenceInterval? {
    guard (start == nil) == (end == nil) else { throw JSONDecodingError("both interval endpoints must be supplied") }
    guard properties?["referenceRangeLabels"] == nil else { throw JSONDecodingError("cannot change referenceRangeLabels") }
    guard let previous = localCollection.getIntervalById(id) else { return nil }
    let localSequence = client.nextLocalSequence()
    let deltas = properties.map { previous.changeProperties($0, localSequence: localSequence) } ?? JSObject()
    var current = previous
    if let start, let end {
      current = try previous.modify(start: start, end: end, pending: submit != nil, canSlideToEndpoint: canSlideToEndpoint)
      localCollection.removeExistingInterval(previous)
      localCollection.add(current)
    }
    var payload = try current.serialize().asObject()
    if start == nil {
      payload["start"] = nil
      payload["end"] = nil
      payload["startSide"] = nil
      payload["endSide"] = nil
    }
    var updates = properties ?? JSObject()
    updates["intervalId"] = .string(id)
    updates["referenceRangeLabels"] = .array([.string(label)])
    payload["properties"] = .object(updates)
    let metadata = IntervalLocalOpMetadata(kind: .change, localSequence: localSequence, id: id,
      interval: current, changesEndpoints: start != nil, properties: properties ?? JSObject())
    try submitDelta("change", .object(payload), metadata, consensus: previous)
    if properties != nil {
      emit("propertyChanged", previous, deltas: deltas)
      emit("changed", current, deltas: deltas)
    }
    if start != nil {
      emit("changeInterval", current, previous: previous)
      emit("changed", current, previous: previous)
      return current
    }
    return nil
  }

  public func applyStashedOp(_ name: JSString, value: JSONValue) throws {
    let (id, properties) = try getSerializedProperties(value)
    let fields = try value.asObject()
    switch name {
    case "add":
      try add(id: id, start: decodeSequencePlace(value.member("start"), side: fields["startSide"]), end: decodeSequencePlace(value.member("end"), side: fields["endSide"]), properties: properties)
    case "change":
      try changePlaces(id, start: fields["start"].map { try decodeSequencePlace($0, side: fields["startSide"]) }, end: fields["end"].map { try decodeSequencePlace($0, side: fields["endSide"]) }, properties: properties)
    case "delete":
      try removeIntervalById(id)
    default: throw JSONDecodingError("unknown stashed interval operation")
    }
  }

  public func process(_ name: JSString, value: JSONValue, message: SequencedMessage,
    metadata: IntervalLocalOpMetadata?) throws {
    guard let kind = IntervalLocalOpMetadata.Kind(rawValue: name.description) else {
      throw JSONDecodingError("unknown interval operation")
    }
    let (id, properties) = try getSerializedProperties(value)
    let entry = pending[id]
    if let metadata {
      guard metadata.kind == kind, metadata.id == id, entry?.local.first === metadata else {
        throw JSONDecodingError("0xbc1: interval ack metadata mismatch")
      }
      entry?.local.removeFirst()
    }
    var consensus = metadata?.interval
    let perspective = Perspective.prior(sequence: message.referenceSequenceNumber, client: message.clientId)
    switch kind {
    case .add:
      if let metadata, let interval = metadata.interval {
        try acknowledge(interval)
      } else {
        let interval = try SequenceInterval(client: client, id: id, label: label,
          start: decodeSequencePlace(value.member("start"), side: value.asObject()["startSide"]),
          end: decodeSequencePlace(value.member("end"), side: value.asObject()["endSide"]),
          properties: properties, perspective: perspective, canSlideToEndpoint: canSlideToEndpoint)
        localCollection.add(interval)
        emit("addInterval", interval, local: false)
        consensus = interval
      }
    case .delete:
      if metadata == nil, let interval = localCollection.getIntervalById(id) {
        localCollection.removeExistingInterval(interval)
        emit("deleteInterval", interval, local: false)
      }
    case .change:
      if let metadata, let interval = metadata.interval {
        interval.ackProperties(localSequence: metadata.localSequence)
        try acknowledge(interval)
      } else if let previous = entry?.consensus ?? localCollection.getIntervalById(id) {
        let visible = localCollection.getIntervalById(id) === previous
        let deltas = previous.changeProperties(properties, localSequence: 0, sequence: message.sequenceNumber)
        var current = previous
        let fields = try value.asObject()
        if let start = fields["start"], let end = fields["end"] {
          current = try previous.modify(start: decodeSequencePlace(start, side: fields["startSide"]), end: decodeSequencePlace(end, side: fields["endSide"]), pending: false, perspective: perspective, canSlideToEndpoint: canSlideToEndpoint)
          if visible {
            localCollection.removeExistingInterval(previous)
            localCollection.add(current)
            emit("changeInterval", current, previous: previous, local: false)
            emit("changed", current, previous: previous, local: false)
          }
        }
        if visible && !deltas.isEmpty {
          emit("propertyChanged", previous, deltas: deltas, local: false)
          emit("changed", previous, deltas: deltas, local: false)
        }
        consensus = current
      }
    }
    if let entry {
      if entry.local.isEmpty { pending[id] = nil }
      else { entry.consensus = consensus }
    }
  }

  private func acknowledge(_ interval: SequenceInterval) throws {
    guard pending[interval.id]?.local.contains(where: { $0.changesEndpoints }) != true else { return }
    let previous = interval.cloneForEvent()
    let start = interval.start.segment
    let end = interval.end.segment
    let visible = localCollection.getIntervalById(interval.id) === interval
    if visible { localCollection.removeIntervalListeners(interval) }
    try interval.acknowledge()
    if visible {
      localCollection.addIntervalListeners(interval)
      if interval.start.segment !== start || interval.end.segment !== end {
        localCollection.removeExistingInterval(interval)
        localCollection.add(interval)
        emit("changeInterval", interval, previous: previous, slide: true)
        emit("changed", interval, previous: previous, slide: true)
      }
    }
  }

  func normalize(squash: Bool = false) throws {
    for (_, entry) in pending.entries {
      for metadata in entry.local where metadata.changesEndpoints {
        if let interval = metadata.interval { _ = try rebase(interval.serialize(), metadata: metadata, squash: squash) }
      }
    }
  }

  public func rebase(_ value: JSONValue, metadata: IntervalLocalOpMetadata, squash: Bool = false) throws -> JSONValue? {
    guard metadata.changesEndpoints, let interval = metadata.interval else { return value }
    guard let start = client.rebaseReference(interval.start, localSequence: metadata.localSequence, squash: squash),
      let end = client.rebaseReference(interval.end, localSequence: metadata.localSequence, squash: squash) else {
      if let current = localCollection.getIntervalById(metadata.id), current === interval || metadata.kind == .add {
        try removeIntervalById(metadata.id)
      }
      return nil
    }
    if interval.start.segment !== start.segment || interval.start.offset != start.offset
      || interval.end.segment !== end.segment || interval.end.offset != end.offset {
      let visible = localCollection.getIntervalById(metadata.id) === interval
      let previous = interval.cloneForEvent()
      if visible {
        localCollection.removeExistingInterval(interval)
      }
      try interval.moveEndpoints(start: (start.segment, start.offset), end: (end.segment, end.offset))
      if visible {
        localCollection.add(interval)
        emit("changeInterval", interval, previous: previous, slide: true)
        emit("changed", interval, previous: previous, slide: true)
      }
    }
    var fields = try value.asObject()
    let startPosition = client.referencePosition(interval.start)
    let endPosition = client.referencePosition(interval.end)
    if case .position = startPosition { fields["start"] = .number(Double(start.position)) }
    else { fields["start"] = startPosition.json }
    if case .position = endPosition { fields["end"] = .number(Double(end.position)) }
    else { fields["end"] = endPosition.json }
    fields["sequenceNumber"] = .number(Double(client.currentSequence))
    return .object(fields)
  }

  public func resubmit(_ value: JSONValue, metadata: IntervalLocalOpMetadata, squash: Bool = false) throws {
    guard let entry = pending[metadata.id], let index = entry.local.firstIndex(where: { $0 === metadata }) else {
      throw JSONDecodingError("0xbbe: missing interval resubmit metadata")
    }
    entry.local.remove(at: index)
    if let rebased = try rebase(value, metadata: metadata, squash: squash) {
      try submitDelta(JSString(metadata.kind.rawValue), rebased, metadata)
    }
    if entry.local.isEmpty { pending[metadata.id] = nil }
  }

  public func rollback(_ metadata: IntervalLocalOpMetadata) throws {
    guard let entry = pending[metadata.id], entry.local.last === metadata else {
      throw JSONDecodingError("interval rollback must be LIFO")
    }
    entry.local.removeLast()
    let previous = entry.local.last?.interval ?? entry.consensus
    switch metadata.kind {
    case .add:
      if let interval = metadata.interval {
        localCollection.removeExistingInterval(interval)
        emit("deleteInterval", interval)
        interval.dispose()
      }
    case .delete:
      if let previous {
        localCollection.add(previous)
        emit("addInterval", previous)
      }
    case .change:
      if let interval = metadata.interval {
        let deltas = interval.rollbackProperties(localSequence: metadata.localSequence, updates: metadata.properties)
        if metadata.changesEndpoints, let previous {
          localCollection.removeExistingInterval(interval)
          localCollection.add(previous)
          emit("changeInterval", previous, previous: interval, slide: true)
          emit("changed", previous, previous: interval, slide: true)
        }
        if !metadata.properties.isEmpty, let previous {
          emit("propertyChanged", previous, deltas: deltas)
        }
        if metadata.changesEndpoints && previous !== interval { interval.dispose() }
      }
    }
    if entry.local.isEmpty { pending[metadata.id] = nil }
  }

  func restoreInterval(id: JSString, start: SequencePlace, end: SequencePlace,
    properties: JSObject<JSONValue>, intervalType: IntervalType = .slideOnRemove) throws {
    let interval = try SequenceInterval(client: client, id: id, label: label, start: start, end: end,
      properties: properties, canSlideToEndpoint: canSlideToEndpoint, intervalType: intervalType)
    localCollection.add(interval)
  }

  public func serialize(version: IntervalSerializationFormat = .v2) -> JSONValue {
    if version == .v1 { return .array(localCollection.map { $0.serialize() }) }
    let intervals = localCollection.map { interval -> JSONValue in
      var props = interval.properties
      props["intervalId"] = .string(interval.id)
      var fields: [JSONValue] = [
        client.referencePosition(interval.start).json,
        client.referencePosition(interval.end).json,
        .number(Double(client.currentSequence)), .number(Double(interval.intervalType.rawValue)), .object(props),
      ]
      if interval.stickiness != 2 { fields.append(.number(Double(interval.stickiness))) }
      return .array(fields)
    }
    return sequenceObject([("label", .string(label)), ("intervals", .array(intervals)), ("version", .number(2))])
  }

  private func emit(_ name: JSString, _ interval: SequenceInterval, previous: SequenceInterval? = nil,
    deltas: JSObject<JSONValue> = JSObject(), local: Bool = true, slide: Bool = false) {
    event?(Event(name: name, interval: interval, previous: previous, propertyDeltas: deltas, local: local, slide: slide))
  }

}
