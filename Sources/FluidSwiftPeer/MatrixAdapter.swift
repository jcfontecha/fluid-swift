import FluidMatrix
import FluidJS
import FluidTestRuntimeUtils

func matrixAdapter(_ runtime: MockContainerRuntime<SharedMatrix>) -> RuntimeClient<SharedMatrix> {
  runtime.mockDeltaManager.minimumSequenceNumber = runtime.channel.rows.client.minimumSequence
  let peer = RuntimeClient(runtime, edit: { channel, edit in
    switch try edit.member("kind").asString() {
    case "insertRows": try channel.insertRows(edit.member("start").asInt(), edit.member("count").asInt())
    case "removeRows": try channel.removeRows(edit.member("start").asInt(), edit.member("count").asInt())
    case "insertCols": try channel.insertCols(edit.member("start").asInt(), edit.member("count").asInt())
    case "removeCols": try channel.removeCols(edit.member("start").asInt(), edit.member("count").asInt())
    case "switchSetCellPolicy": channel.switchSetCellPolicy()
    case "setCell":
      let kind = try edit.asObject()["valueKind"]
      let value: JSONValue?
      if kind == .string("undefined") { value = nil }
      else if kind == .string("handle") { value = matrixRecord([("type", .string("__fluid_handle__")), ("url", .string("/handles/a"))]) }
      else { value = try edit.member("value") }
      try channel.setCell(edit.member("row").asInt(), edit.member("col").asInt(), value)
    default: throw PeerError(description: "invalid matrix edit")
    }
  }, state: { channel in
    matrixRecord([
      ("rowCount", .number(Double(channel.rowCount))),
      ("colCount", .number(Double(channel.colCount))),
      ("cells", .array(try (0..<channel.rowCount).map { row in
        .array(try (0..<channel.colCount).map { col in
          try channel.getCell(row, col) ?? matrixRecord([("$fluid", .string("undefined"))])
        })
      })),
    ])
  }, queries: { channel in
    matrixRecord([("rowCount", .number(Double(channel.rowCount))), ("colCount", .number(Double(channel.colCount))), ("fww", .bool(channel.isSetCellConflictResolutionPolicyFWW()))])
  })
  runtime.channel.event = { [weak peer] event in peer?.events.append(event) }
  return peer
}
private func matrixRecord(_ entries: [(JSString, JSONValue)]) -> JSONValue {
  var object = JSObject<JSONValue>()
  for (key, value) in entries { object[key] = value }
  return .object(object)
}
