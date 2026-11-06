import FluidJS
import FluidContainerRuntime

private func object(_ entries: [(JSString, JSONValue?)]) -> JSONValue {
  var value = JSObject<JSONValue>()
  for (key, entry) in entries { value[key] = entry }
  return .object(value)
}
private func string(_ value: String) -> JSONValue { .string(JSString(value)) }
private func number(_ value: Int) -> JSONValue { .number(Double(value)) }

func runRuntime(_ scenario: JSONValue) throws -> JSONValue {
  var output: [JSONValue] = []
  var queue: [[JSONValue]] = []
  var sequence = 0
  var uuidIndex = 0
  let uuids = try scenario.member("uuids").asArray().map { try $0.asString().description }
  var clients: [ContainerRuntime] = []
  var generations = [0, 0, 0]
  func configure(_ client: ContainerRuntime) {
    client.pendingStateManager.generateUUID = {
      precondition(uuidIndex < uuids.count, "scenario entropy exhausted")
      defer { uuidIndex += 1 }
      return uuids[uuidIndex]
    }
    client.applyStashedOp = { content in object([("applied", string(content))]) }
    client.onSubmit = { batch, clientId, csn in
      output.append(object([("wire", .array(batch)), ("clientId", string(clientId))]))
      queue.append(try batch.enumerated().map { index, message in
        let fields = try message.asObject()
        return try object([
          ("type", string("op")), ("contents", JSON.parse(message.member("contents").asString().description)),
          ("metadata", fields["metadata"]), ("compression", fields["compression"]),
          ("referenceSequenceNumber", fields["referenceSequenceNumber"] ?? number(0)),
          ("clientId", string(clientId)), ("clientSequenceNumber", number(csn + index + 1)),
          ("sequenceNumber", number(0)), ("minimumSequenceNumber", number(0)), ("timestamp", number(0)),
        ])
      })
    }
  }
  for index in 0..<3 {
    let client = try ContainerRuntime(sessionId: "\(index + 1)0000000-0000-4000-8000-000000000001", clientId: "client\(index)-0")
    configure(client)
    clients.append(client)
  }
  var last: [JSONValue] = []
  for command in try scenario.member("commands").asArray() {
    let index = try command.member("client").asInt()
    guard clients.indices.contains(index) else { throw JSONDecodingError("client") }
    let client = clients[index]
    switch try command.member("kind").asString().description {
    case "submit":
      var ids: [JSONValue] = []
      let count = try command.member("ids").asInt()
      guard count >= 0 else { throw JSONDecodingError("negative count") }
      for _ in 0..<count {
        let id = try client.idCompressor.generateCompressedId()
        ids.append(object([("id", .number(id)), ("stable", string(try client.idCompressor.decompress(id)))]))
      }
      output.append(object([("ids", .array(ids))]))
      let ops = try command.member("count").asInt()
      guard ops >= 0 else { throw JSONDecodingError("negative count") }
      for offset in 0..<ops {
        try client.submit(object([
          ("type", string("component")),
          ("contents", object([("address", string("dds")), ("contents", object([
            ("type", string("op")), ("content", number(offset + (try command.member("rebase").asInt()))),
          ]))])),
        ]))
      }
      try client.flush()
    case "disconnect": client.connected = false
    case "connect":
      generations[index] += 1
      let rebase = try command.member("rebase").asInt()
      client.reSubmit = { op in
        guard rebase != 0, try op.member("type") == string("component") else { return op }
        var fields = try op.asObject()
        var contents = try op.member("contents").asObject()
        contents["contents"] = object([("type", string("op")), ("content", number(rebase))])
        fields["contents"] = .object(contents)
        return .object(fields)
      }
      try client.reconnect(clientId: "client\(index)-\(generations[index])")
    case "drop": queue.removeAll()
    case "reload":
      let state = try client.getLocalState(snapshotSequenceNumber: client.referenceSequenceNumber)
      output.append(object([("stash", state)]))
      let loaded = try ContainerRuntime(sessionId: client.idCompressor.localSessionId, clientId: client.clientId, stash: state)
      configure(loaded)
      loaded.referenceSequenceNumber = client.referenceSequenceNumber
      loaded.connected = false
      try loaded.applyStashedOpsAt()
      clients[index] = loaded
    case "deliver", "duplicate":
      let duplicate = try command.member("kind") == string("duplicate")
      var batches = duplicate ? [last] : queue
      if !duplicate {
        queue.removeAll()
        for batchIndex in batches.indices {
          for messageIndex in batches[batchIndex].indices {
            sequence += 1
            var message = try batches[batchIndex][messageIndex].asObject()
            message["sequenceNumber"] = number(sequence)
            batches[batchIndex][messageIndex] = .object(message)
          }
        }
      }
      for batch in batches {
        if !duplicate { last = batch }
        for (receiverIndex, receiver) in clients.enumerated() {
          for message in batch {
            if let result = try receiver.process(message) {
              var entry = JSObject<JSONValue>()
              entry["client"] = number(receiverIndex)
              for (key, value) in try result.asObject().entries { entry[key] = value }
              output.append(.object(entry))
            }
          }
        }
      }
    default: throw JSONDecodingError("unknown runtime command")
    }
    output.append(.array(try clients.map { client in
      try object([
        ("count", number(client.pendingStateManager.pendingMessagesCount)),
        ("dirty", .bool(client.pendingStateManager.hasPendingUserChanges())),
        ("state", client.pendingStateManager.getLocalState()),
        ("compressor", string(client.idCompressor.serialize(true))),
      ])
    }))
  }
  return .array(output)
}
