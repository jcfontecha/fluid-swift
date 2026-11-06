import FluidJS
import FluidMergeTree

/// Ports sequence/src/intervals/sequenceInterval.ts SequenceInterval.
public final class SequenceInterval: BaseSequenceInterval {
  public let client: Client
  public let label: JSString
  private final class PropertyState {
    var values = JSObject<JSONValue>()
    var manager = PropertiesManager()
  }
  private var propertyState = PropertyState()
  public override var properties: JSObject<JSONValue> {
    get { propertyState.values }
    set { propertyState.values = newValue }
  }

  public convenience init(client: Client, id: JSString, label: JSString, start: Int, end: Int,
    properties: JSObject<JSONValue> = JSObject(), pending: Bool = false, perspective: Perspective = .local) throws {
    try self.init(client: client, id: id, label: label, start: SequencePlace(start), end: SequencePlace(end),
      properties: properties, pending: pending, perspective: perspective)
  }

  public init(client: Client, id: JSString, label: JSString, start: SequencePlace, end: SequencePlace,
    properties: JSObject<JSONValue> = JSObject(), pending: Bool = false, perspective: Perspective = .local,
    canSlideToEndpoint: Bool = false, intervalType: IntervalType = .slideOnRemove) throws {
    self.client = client
    self.label = label
    let startSticky = start.side == .after || start.position == .start
    let endSticky = end.side == .before || end.position == .end
    let slideToEndpoint = canSlideToEndpoint && (startSticky || endSticky)
    let startReference = try client.createLocalReferencePosition(at: start.position, refType: intervalType == .transient ? 256 : (pending ? 128 : 64) | 16,
      slidingPreference: startSticky ? .backward : .forward, canSlideToEndpoint: slideToEndpoint, perspective: perspective)
    let endReference = try client.createLocalReferencePosition(at: end.position, refType: intervalType == .transient ? 256 : (pending ? 128 : 64) | 32,
      slidingPreference: endSticky ? .forward : .backward, canSlideToEndpoint: slideToEndpoint, perspective: perspective)
    super.init(id: id, intervalType: intervalType, start: startReference, end: endReference, startSide: start.side, endSide: end.side)
    self.properties = properties
    for (key, value) in self.properties.entries where value == .null || key == "intervalId" || key == "referenceRangeLabels" {
      self.properties[key] = nil
    }
  }

  private init(client: Client, id: JSString, intervalType: IntervalType, label: JSString, start: LocalReference, end: LocalReference, startSide: Side, endSide: Side, properties: JSObject<JSONValue>) {
    self.client = client
    self.label = label
    super.init(id: id, intervalType: intervalType, start: start, end: end, startSide: startSide, endSide: endSide)
    self.properties = properties
  }

  public func overlapsPos(_ start: Int, _ end: Int) -> Bool {
    client.localReferencePositionToPosition(self.end) > start && client.localReferencePositionToPosition(self.start) < end
  }

  public func clone() -> SequenceInterval {
    SequenceInterval(client: client, id: id, intervalType: intervalType, label: label, start: start, end: end,
      startSide: startSide, endSide: endSide, properties: properties)
  }

  func cloneForEvent() -> SequenceInterval {
    SequenceInterval(client: client, id: id, intervalType: intervalType, label: label, start: start.transientClone(), end: end.transientClone(),
      startSide: startSide, endSide: endSide, properties: properties)
  }

  public func modify(start: Int, end: Int, pending: Bool, perspective: Perspective = .local) throws -> SequenceInterval {
    try modify(start: SequencePlace(start), end: SequencePlace(end), pending: pending, perspective: perspective)
  }

  public func modify(start: SequencePlace, end: SequencePlace, pending: Bool, perspective: Perspective = .local,
    canSlideToEndpoint: Bool = false) throws -> SequenceInterval {
    let result = try SequenceInterval(client: client, id: id, label: label, start: start, end: end,
      pending: pending, perspective: perspective, canSlideToEndpoint: canSlideToEndpoint, intervalType: intervalType)
    result.propertyState = propertyState
    return result
  }

  func changeProperties(_ updates: JSObject<JSONValue>, localSequence: Int, sequence: Int? = nil) -> JSObject<JSONValue> {
    var values: JSObject<JSONValue>? = properties
    let stamp = Stamp(sequence: sequence ?? (client.collaborating ? -1 : 0), client: client.id, localSequence: localSequence)
    let deltas = propertyState.manager.handleProperties(updates, properties: &values, stamp: stamp)
    properties = values ?? JSObject()
    return deltas
  }

  func ackProperties(localSequence: Int) { propertyState.manager.ack(localSequence: localSequence) }

  func rollbackProperties(localSequence: Int, updates: JSObject<JSONValue>) -> JSObject<JSONValue> {
    var deltas = JSObject<JSONValue>()
    for (key, _) in updates.entries { deltas[key] = properties[key] ?? .null }
    var values: JSObject<JSONValue>? = properties
    propertyState.manager.rollback(localSequence: localSequence, properties: &values)
    properties = values ?? JSObject()
    return deltas
  }

  func moveEndpoints(start startPosition: (segment: BaseSegment, offset: Int), end endPosition: (segment: BaseSegment, offset: Int)) throws {
    let newStart = try client.cloneReference(start, at: startPosition.segment, offset: startPosition.offset)
    let newEnd = try client.cloneReference(end, at: endPosition.segment, offset: endPosition.offset)
    _ = client.removeLocalReferencePosition(start)
    _ = client.removeLocalReferencePosition(end)
    start = newStart
    end = newEnd
  }

  public func acknowledge() throws {
    let startDestination = client.slideReferenceDestination(start)
    let endDestination = client.slideReferenceDestination(end)
    try start.setReferenceType((start.refType & ~128) | 64)
    try end.setReferenceType((end.refType & ~128) | 64)
    func replace(_ reference: LocalReference, _ destination: (segment: BaseSegment, offset: Int)?) throws -> LocalReference {
      if reference.segment === destination?.segment { return reference }
      let result: LocalReference
      if let destination {
        result = try client.cloneReference(reference, at: destination.segment, offset: destination.offset)
      } else {
        result = try LocalReference(segment: nil, offset: 0, refType: reference.refType,
          slidingPreference: reference.slidingPreference, canSlideToEndpoint: reference.canSlideToEndpoint)
      }
      _ = client.removeLocalReferencePosition(reference)
      return result
    }
    start = try replace(start, startDestination)
    end = try replace(end, endDestination)
  }

  public func dispose() {
    _ = client.removeLocalReferencePosition(start)
    _ = client.removeLocalReferencePosition(end)
  }

  public func serialize() -> JSONValue {
    var props = properties
    props["intervalId"] = .string(id)
    props["referenceRangeLabels"] = .array([.string(label)])
    return sequenceObject([
      ("end", client.referencePosition(end).json),
      ("intervalType", .number(Double(intervalType.rawValue))),
      ("sequenceNumber", .number(Double(client.currentSequence))),
      ("start", client.referencePosition(start).json),
      ("stickiness", .number(Double(stickiness))),
      ("startSide", .number(Double(startSide.rawValue))),
      ("endSide", .number(Double(endSide.rawValue))),
      ("properties", .object(props)),
    ])
  }
}

func decodeSequencePlace(_ value: JSONValue, side: JSONValue?) throws -> SequencePlace {
  let position = try SequencePosition(json: value)
  if position == .start || position == .end { return SequencePlace(position: position) }
  let rawSide = try side?.asInt() ?? 0
  guard let side = Side(rawValue: rawSide) else { throw JSONDecodingError("invalid endpoint side") }
  if case .position(let number) = position, side == .before { return SequencePlace(number) }
  return SequencePlace(position: position, side: side)
}
