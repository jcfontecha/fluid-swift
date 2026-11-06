import FluidDriverDefinitions
import FluidJS
import FluidSequence
import FluidMergeTree
import FluidTestRuntimeUtils

private func sharedStringPlace(_ value: JSONValue) throws -> SequencePlace {
  if case .object = value {
    let raw = try value.member("side").asInt()
    guard let side = Side(rawValue: raw) else { throw PeerError(description: "invalid sequence side") }
    return try SequencePlace(value.member("pos").asInt(), side: side)
  }
  let position = try SequencePosition(json: value)
  if case .position(let number) = position { return SequencePlace(number) }
  return SequencePlace(position: position)
}

private func sequenceRecord(_ entries: [(JSString, JSONValue)]) -> JSONValue {
  var fields = JSObject<JSONValue>()
  for (key, value) in entries { fields[key] = value }
  return .object(fields)
}

private func sequenceProperties(_ properties: JSObject<JSONValue>?) -> JSONValue {
  var result = JSObject<JSONValue>()
  for (key, value) in (properties?.entries ?? []).sorted(by: { $0.0.utf16.lexicographicallyPrecedes($1.0.utf16) }) {
    result[key] = value
  }
  return .object(result)
}

private func sequenceInterval(_ interval: SequenceInterval) -> JSONValue {
  sequenceRecord([
    ("id", .string(interval.id)),
    ("start", .number(Double(interval.client.localReferencePositionToPosition(interval.start)))),
    ("end", .number(Double(interval.client.localReferencePositionToPosition(interval.end)))),
    ("properties", sequenceProperties(interval.properties)),
  ])
}

private func sequenceCollections(_ channel: SharedString) -> JSONValue {
  .array(channel.getIntervalCollectionLabels().sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.map { label in
    let intervals = channel.getIntervalCollection(label).sorted { $0.id.utf16.lexicographicallyPrecedes($1.id.utf16) }
    return sequenceRecord([("label", .string(label)), ("intervals", .array(intervals.map(sequenceInterval)))])
  })
}

/// Ports harness/src/sequence.ts sharedStringAdapter; no normalization of summary or wire data.
func sharedStringAdapter(_ runtime: MockContainerRuntime<SharedString>) -> RuntimeClient<SharedString> {
  runtime.mockDeltaManager.minimumSequenceNumber = runtime.channel.client.minimumSequence
  runtime.channel.intervalStickinessEnabled = true
  let peer = RuntimeClient(runtime, edit: { channel, edit in
    let fields = try edit.asObject()
    let props = try fields["props"].map { try $0.asObject() }
    switch try edit.member("kind").asString() {
    case "insertText":
      try channel.insertText(edit.member("position").asInt(), edit.member("text").asString(), properties: props)
    case "insertMarker":
      try channel.insertMarker(edit.member("position").asInt(), refType: 1, properties: props)
    case "removeRange":
      try channel.removeRange(edit.member("start").asInt(), edit.member("end").asInt())
    case "annotateRange":
      try channel.annotateRange(edit.member("start").asInt(), edit.member("end").asInt(), props ?? JSObject())
    case "addInterval":
      try channel.getIntervalCollection(edit.member("collection").asString()).add(id: edit.member("id").asString(),
        start: sharedStringPlace(edit.member("start")), end: sharedStringPlace(edit.member("end")), properties: props ?? JSObject())
    case "changeInterval":
      let collection = try channel.getIntervalCollection(edit.member("collection").asString())
      let id = try edit.member("id").asString()
      if let start = fields["start"], let end = fields["end"] {
        try collection.change(id, start: sharedStringPlace(start), end: sharedStringPlace(end), properties: props)
      } else if fields["start"] == nil && fields["end"] == nil {
        try collection.change(id, properties: props)
      } else { throw PeerError(description: "both interval endpoints are required") }
    case "deleteInterval":
      try channel.getIntervalCollection(edit.member("collection").asString()).removeIntervalById(edit.member("id").asString())
    default: throw PeerError(description: "invalid SharedString edit")
    }
  }, state: { channel in
    let positions = (0..<channel.getLength()).map { position -> JSONValue in
      let segment = channel.getContainingSegment(position)?.segment
      return sequenceRecord([
        ("properties", sequenceProperties(channel.getPropertiesAtPosition(position))),
        ("marker", segment?.text == nil ? segment?.toJSON() ?? .null : .null),
      ])
    }
    return sequenceRecord([
      ("text", .array(channel.getText().utf16.map { .number(Double($0)) })),
      ("positions", .array(positions)), ("collections", sequenceCollections(channel)),
    ])
  }, queries: { channel in
    sequenceRecord([("length", .number(Double(channel.getLength()))), ("collections", sequenceCollections(channel))])
  })
  let subscribe: (JSString) -> Void = { [weak channel = runtime.channel, weak peer] label in
    guard let channel else { return }
    channel.getIntervalCollection(label).event = { [weak peer] event in
      var values: [JSONValue] = [.string(event.name), .string(label), sequenceInterval(event.interval)]
      switch event.name {
      case "addInterval", "deleteInterval": values.append(.bool(event.local))
      case "changeInterval":
        values.append(event.previous.map(sequenceInterval) ?? .null)
        values.append(.bool(event.local))
        values.append(.bool(event.slide))
      case "propertyChanged":
        values.append(sequenceProperties(event.propertyDeltas))
        values.append(.bool(event.local))
      default: return
      }
      peer?.events.append(.array(values))
    }
  }
  for label in runtime.channel.getIntervalCollectionLabels() { subscribe(label) }
  runtime.channel.createIntervalCollection.on { [weak peer] label in
    peer?.events.append(.array([.string("createIntervalCollection"), .string(label)]))
    subscribe(label)
  }
  runtime.channel.sequenceMaintenance.on { [weak peer] event in
    peer?.events.append(.array([
      .string("maintenance"), .number(Double(event.deltaOperation)), .bool(event.isLocal),
      .array(event.ranges.map { range in
        sequenceRecord([("position", .number(Double(range.position))), ("segment", range.segment.toJSON()), ("propertyDeltas", .object(range.propertyDeltas))])
      }),
    ]))
  }
  runtime.channel.sequenceDelta.on { [weak peer] event in
    peer?.events.append(.array([
      .string("sequenceDelta"), .number(Double(event.deltaOperation)), .bool(event.isLocal),
      .array(event.ranges.map { range in
        sequenceRecord([("position", .number(Double(range.position))), ("segment", range.segment.toJSON()), ("propertyDeltas", .object(range.propertyDeltas))])
      }),
    ]))
  }
  return peer
}
