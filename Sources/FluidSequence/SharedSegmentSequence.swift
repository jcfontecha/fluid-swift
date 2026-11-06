import FluidJS
import FluidMergeTree
import FluidSharedObjectBase
import FluidDriverDefinitions

/// Ports packages/dds/sequence/src/sequence.ts SharedSegmentSequence.
/// Positions are merge-tree UTF-16 offsets, including positions occupied by markers.
open class SharedSegmentSequence: SharedObject<SequenceLocalOpMetadata> {
  public override class var type: JSString { "https://graph.microsoft.com/types/mergeTree" }
  public private(set) var client: Client
  public private(set) var intervalCollections: IntervalCollectionMap
  /// "createIntervalCollection" (label).
  public let createIntervalCollection = EventEmitter<JSString>()
  /// "maintenance" (event).
  public let sequenceMaintenance = EventEmitter<SequenceMaintenanceEvent>()
  private var processingMessage: SequencedMessage?
  /// "sequenceDelta" (event).
  public let sequenceDelta = EventEmitter<SequenceDeltaEvent>()

  public var intervalSerializationFormat: IntervalSerializationFormat = .v2
  public var intervalStickinessEnabled = false {
    didSet { intervalCollections.intervalStickinessEnabled = intervalStickinessEnabled }
  }
  public var referencesCanSlideToEndpoint = false {
    didSet {
      client.referencesCanSlideToEndpoint = referencesCanSlideToEndpoint
      intervalCollections.canSlideToEndpoint = referencesCanSlideToEndpoint
    }
  }
  public var newMergeTreeSnapshotFormat = false
  private var catchup: [JSONValue] = []
  private var transformed: [JSONValue]? = nil
  private var editing = false
  public var preventReentrancy = true
  private var inFlight: [(metadata: SequenceLocalOpMetadata, reference: Int)] = []
  private var regenerated: [JSONValue] = []
  private var resubmitReference: Int?
  private var resubmitsRemaining = 0

  public required init(id: JSString) {
    client = Client(id: id, collaborating: false)
    intervalCollections = IntervalCollectionMap(client: client)
    super.init(id: id)
    installDeltaHandler()
    installIntervalHandler()
  }

  private func installDeltaHandler() {
    client.maintenance = { [weak self] type, segments, operation in
      guard let self, !self.sequenceMaintenance.isEmpty else { return }
      let args = operation.map { SequenceOperationArgs(operation: $0, sequencedMessage: self.processingMessage, rollback: false) }
      self.sequenceMaintenance.emit(SequenceMaintenanceEvent(client: self.client, operation: type.rawValue, segments: segments,
        local: operation == nil, opArgs: args))
    }
    client.delta = { [weak self] operation, segments, local in
      guard let self else { return }
      if local && self.isAttached && !self.client.rollingBack {
        try self.submitSequenceMessage(operation, .segment(localSequence: self.client.latestLocalSequence))
      }
      let event = SequenceDeltaEvent(client: self.client, operation: try operation.member("type").asInt(), segments: segments, local: local, opArgs: SequenceOperationArgs(operation: operation, sequencedMessage: local ? nil : self.processingMessage, rollback: self.client.rollingBack))
      self.sequenceDelta.emit(event)
      if self.transformed != nil { self.transformed?.append(contentsOf: try event.createOps()) }
    }
  }

  private func submitSequenceMessage(_ operation: JSONValue, _ metadata: SequenceLocalOpMetadata) throws {
    inFlight.append((metadata, resubmitReference ?? runtime?.deltaManager.lastSequenceNumber ?? client.currentSequence))
    try submitLocalMessage(operation, metadata)
  }

  private func installIntervalHandler() {
    client.beforeNormalize = { [weak self] in
      guard let self else { return }
      for label in self.intervalCollections.labels { try self.intervalCollections.get(label).normalize(squash: self.client.normalizingSquashed) }
    }
    intervalCollections.intervalStickinessEnabled = intervalStickinessEnabled
    intervalCollections.canSlideToEndpoint = referencesCanSlideToEndpoint
    client.referencesCanSlideToEndpoint = referencesCanSlideToEndpoint
    intervalCollections.created = { [weak self] collection in
      guard let self else { return }
      self.connectCollection(collection)
      self.createIntervalCollection.emit(collection.label)
    }
    for label in intervalCollections.labels { connectCollection(intervalCollections.get(label)) }
  }

  private func connectCollection(_ collection: IntervalCollection) {
    guard isAttached else { return }
    collection.submit = { [weak self, weak collection] name, value, metadata in
      guard let self, let collection else { return }
      let operation = sequenceObject([
        ("key", .string(collection.label)), ("type", .string("act")),
        ("value", sequenceObject([("opName", .string(name)), ("value", value)])),
      ])
      try self.submitSequenceMessage(operation, .interval(label: collection.label, metadata: metadata))
    }
  }

  public func getIntervalCollection(_ label: JSString) -> IntervalCollection { intervalCollections.get(label) }
  public func getIntervalCollectionLabels() -> [JSString] { intervalCollections.labels }

  public override func didAttach() {
    client.startOrUpdateCollaboration(runtime?.clientId ?? "attached")
    for label in intervalCollections.labels { connectCollection(intervalCollections.get(label)) }
  }

  public override func onConnect() {
    client.startOrUpdateCollaboration(runtime?.clientId ?? "attached")
    regenerated = []
    resubmitsRemaining = 0
  }

  @discardableResult
  private func edit(_ operation: JSONValue) throws -> JSONValue {
    try verifyOpen()
    guard !editing || !preventReentrancy else { throw SharedObjectError("reentrant sequence mutation") }
    let previous = editing
    editing = true
    defer { editing = previous }
    let op = try client.edit(operation)
    return op
  }

  public override func processMessagesCore(_ contents: [Content], local: Bool) throws {
    for content in contents {
      let message = content.message
      processingMessage = message
      defer { processingMessage = nil }
      guard message.type == MessageType.operation else {
        throw SharedObjectError("0x073: sequence requires an operation")
      }
      if local {
        guard let first = inFlight.first, first.metadata.localSequence == content.metadata?.localSequence else {
          throw SharedObjectError("0x8bc: missing in-flight sequence metadata")
        }
      }
      if local { inFlight.removeFirst() }
      if try message.contents.member("type") == .string("act") {
        let label = try message.contents.member("key").asString()
        let op = try message.contents.member("value")
        let metadata: IntervalLocalOpMetadata?
        if local, case .interval(let expected, let pending) = content.metadata, expected == label {
          metadata = pending
        } else if local {
          throw SharedObjectError("interval metadata missing")
        } else { metadata = nil }
        try intervalCollections.get(label).process(op.member("opName").asString(), value: op.member("value"), message: message, metadata: metadata)
        continue
      }
      let needsTransformation = !newMergeTreeSnapshotFormat && message.referenceSequenceNumber != message.sequenceNumber - 1
      transformed = needsTransformation ? [] : nil
      defer { transformed = nil }
      try client.process(message.contents, sender: local ? client.id : message.clientId,
        sequence: message.sequenceNumber, referenceSequence: message.referenceSequenceNumber)
      try client.advanceMinimum(to: min(message.minimumSequenceNumber, inFlight.first?.reference ?? message.minimumSequenceNumber))
      if !newMergeTreeSnapshotFormat {
        var stored = try message.json.asObject()
        if let ops = transformed {
          stored["referenceSequenceNumber"] = .number(Double(message.sequenceNumber - 1))
          stored["contents"] = ops.count == 1 ? ops[0] : sequenceObject([("ops", .array(ops)), ("type", .number(3))])
        }
        catchup.append(.object(stored))
      }
    }
  }

  public override func reSubmitCore(_ content: JSONValue, localOpMetadata: SequenceLocalOpMetadata) throws {
    try resubmit(content, metadata: localOpMetadata, squash: false)
  }

  public func reSubmitSquashed(_ content: JSONValue, localOpMetadata: SequenceLocalOpMetadata) throws {
    try resubmit(content, metadata: localOpMetadata, squash: true)
  }

  private func resubmit(_ content: JSONValue, metadata localOpMetadata: SequenceLocalOpMetadata, squash: Bool) throws {
    guard let first = inFlight.first, first.metadata.localSequence == localOpMetadata.localSequence else {
      throw SharedObjectError("0x8bb: missing resubmit reference sequence")
    }
    resubmitReference = first.reference
    defer { resubmitReference = nil }
    if resubmitsRemaining == 0 {
      let count = inFlight.count
      regenerated = try client.regeneratePendingOps(squash: squash)
      resubmitsRemaining = count
    }
    defer { resubmitsRemaining -= 1 }
    inFlight.removeFirst()
    switch localOpMetadata {
    case .segment:
      guard !regenerated.isEmpty else { throw SharedObjectError("missing regenerated merge-tree operation") }
      try submitSequenceMessage(regenerated.removeFirst(), localOpMetadata)
    case .interval(let label, let metadata):
      try intervalCollections.get(label).resubmit(content.member("value").member("value"), metadata: metadata, squash: squash)
    }
  }

  public override func rollback(_ content: JSONValue, localOpMetadata: SequenceLocalOpMetadata) throws {
    guard inFlight.last?.metadata.localSequence == localOpMetadata.localSequence else {
      throw SharedObjectError("sequence rollback must be LIFO")
    }
    switch localOpMetadata {
    case .segment: try client.rollbackPendingOp()
    case .interval(let label, let metadata): try intervalCollections.get(label).rollback(metadata)
    }
    inFlight.removeLast()
  }

  public override func applyStashedOp(_ content: JSONValue) throws {
    if try content.member("type") == .string("act") {
      let op = try content.member("value")
      try intervalCollections.get(content.member("key").asString()).applyStashedOp(op.member("opName").asString(), value: op.member("value"))
      return
    }
    if try content.member("type").asInt() == 3 {
      for op in try content.member("ops").asArray() { try applyStashedOp(op) }
    } else {
      try edit(content)
    }
  }

  public override func summarize() -> SummaryTree {
    do {
      return try summarizeSequence()
    } catch {
      preconditionFailure("Invalid internally generated sequence summary: \(error)")
    }
  }

  public func summarizeSequence() throws -> SummaryTree {
    // The interval header is serialized before Client.summarize advances its collaboration window.
    let intervalHeader = intervalCollections.count > 0 ? JSString(JSON.stringify(intervalCollections.serialize(version: intervalSerializationFormat))) : nil
    try client.updateSequenceNumbers(minimum: runtime?.deltaManager.minimumSequenceNumber ?? client.minimumSequence, sequence: runtime?.deltaManager.lastSequenceNumber ?? client.currentSequence)
    catchup = try catchup.filter { try $0.member("sequenceNumber").asInt() > client.minimumSequence }
    let messages = try catchup.map { message in
      var fields = try message.asObject()
      fields["minimumSequenceNumber"] = .number(Double(client.minimumSequence))
      return JSONValue.object(fields)
    }
    let content = try client.snapshot(version: newMergeTreeSnapshotFormat ? "v1" : "legacy", catchup: newMergeTreeSnapshotFormat ? [] : messages)
    var tree = JSObject<JSONValue>()
    if let intervalHeader {
      tree["header"] = sequenceObject([("type", .number(2)), ("content", .string(intervalHeader))])
    }
    tree["content"] = content
    return try SummaryTree(json: sequenceObject([("type", .number(1)), ("tree", .object(tree))]))
  }

  public override func loadCore(_ summary: SummaryTree) throws {
    let content = try summary.json.member("tree").member("content")
    let header = try JSON.parse(content.member("tree").member("header").member("content").asString().description)
    newMergeTreeSnapshotFormat = try header.asObject()["version"] == .string("1")
    client = try SnapshotLoader().load(content, id: id)
    intervalCollections = IntervalCollectionMap(client: client)
    if let header = try summary.json.member("tree").asObject()["header"] {
      try intervalCollections.populate(JSON.parse(header.member("content").asString().description))
    }
    installDeltaHandler()
    installIntervalHandler()
    if let blob = try content.member("tree").asObject()["catchupOps"] {
      catchup = try JSON.parse(blob.member("content").asString().description).asArray()
    }
  }

  public func getLength() -> Int { client.length }

  @discardableResult
  public func removeRange(_ start: Int, _ end: Int) throws -> JSONValue {
    try edit(sequenceObject([
      ("pos1", .number(Double(start))),
      ("pos2", .number(Double(end))),
      ("type", .number(1)),
    ]))
  }

  @discardableResult
  public func annotateRange(_ start: Int, _ end: Int, _ properties: JSObject<JSONValue>) throws -> JSONValue {
    try edit(sequenceObject([
      ("pos1", .number(Double(start))),
      ("pos2", .number(Double(end))),
      ("props", .object(properties)),
      ("type", .number(2)),
    ]))
  }

  public func getPropertiesAtPosition(_ position: Int) -> JSObject<JSONValue>? {
    getContainingSegment(position)?.segment.properties
  }

  public func getContainingSegment(_ position: Int) -> (segment: BaseSegment, offset: Int)? {
    guard position >= 0 else { return nil }
    var start = 0
    for segment in client.segments where Perspective.local.contains(segment) {
      if position < start + segment.length { return (segment, position - start) }
      start += segment.length
    }
    return nil
  }

  @discardableResult
  public func insertMarker(_ position: Int, refType: Int, properties: JSObject<JSONValue>? = nil) throws -> JSONValue {
    var marker = JSObject<JSONValue>()
    marker["marker"] = sequenceObject([("refType", .number(Double(refType)))])
    marker["props"] = properties.map(JSONValue.object)
    return try insertSegment(position, .object(marker))
  }

  @discardableResult
  func insertSegment(_ position: Int, _ segment: JSONValue) throws -> JSONValue {
    var payload = segment
    if case .object(var fields) = segment, let properties = fields["props"] {
      var props = try properties.asObject()
      for (key, value) in props.entries where value == .null { props[key] = nil }
      fields["props"] = .object(props)
      payload = .object(fields)
    }
    return try edit(sequenceObject([
      ("pos1", .number(Double(position))),
      ("seg", payload),
      ("type", .number(0)),
    ]))
  }
}

func sequenceObject(_ entries: [(JSString, JSONValue)]) -> JSONValue {
  var object = JSObject<JSONValue>()
  for (key, value) in entries { object[key] = value }
  return .object(object)
}
