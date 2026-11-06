import Darwin
import FluidJS
import FluidMergeTree

func object(_ fields: [(JSString, JSONValue)]) -> JSONValue {
  var result = JSObject<JSONValue>()
  for (key, value) in fields { result[key] = value }
  return .object(result)
}
var clients: [JSString: MergeTreeClient] = [:]
while let line = readLine() {
  var requestID: JSONValue = .null
  do {
    let request = try JSON.parse(line)
    requestID = try request.member("id")
    let method = try request.member("method").asString()
    let params = try request.member("params")
    var result: JSONValue = .null
    if method == "reset" {
      clients.removeAll()
    } else if method == "create" {
      let id = try params.member("client").asString()
      clients[id] = MergeTreeClient(id: id)
    } else {
      let id = try params.member("client").asString()
      guard let client = clients[id] else { throw JSONDecodingError("unknown client") }
      switch method {
      case "edit":
        let edit = try params.member("edit")
        switch try edit.member("kind").asString() {
        case "insert":
          result = try client.insert(
            at: edit.member("pos").asInt(), text: edit.member("text").asString())
        case "marker":
          result = try client.edit(
            object([
              ("pos1", edit.member("pos")),
              ("seg", object([("marker", object([("refType", .number(0))]))])),
              ("type", .number(0)),
            ]))
        case "annotate":
          result = try client.edit(
            object([
              ("pos1", edit.member("start")),
              ("pos2", edit.member("end")),
              ("props", edit.member("props")),
              ("type", .number(2)),
            ]))
        case "remove":
          result = try client.remove(
            start: edit.member("start").asInt(), end: edit.member("end").asInt())
        default:
          throw JSONDecodingError(
            "merge-tree edit is not implemented: \(try edit.member("kind").asString())")
        }
      case "process":
        let message = try params.member("message")
        try client.process(
          message.member("contents"), sender: message.member("clientId").asString(),
          sequence: message.member("sequenceNumber").asInt(),
          referenceSequence: message.member("referenceSequenceNumber").asInt())
        try client.advanceMinimum(to: message.member("minimumSequenceNumber").asInt())
      case "minSeq": try client.advanceMinimum(to: params.member("seq").asInt())
      case "snapshot": result = try client.snapshot(version: params.member("version").asString())
      case "state":
        var lengths: [JSONValue] = []
        for sequence in client.minimumSequence...client.currentSequence {
          for name: JSString in ["A", "B", "C"] {
            lengths.append(
              .number(
                Double(
                  name == id
                    ? client.length : client.length(from: .prior(sequence: sequence, client: name)))
              ))
          }
        }
        result = object([
          ("text", .array(client.text.utf16.map { .number(Double($0)) })),
          ("length", .number(Double(client.length))),
          (
            "segments",
            .array(client.segments.filter { Perspective.local.contains($0) }.map { $0.toJSON() })
          ), ("references", object([])), ("lengths", .array(lengths)),
        ])
      default: throw JSONDecodingError("merge-tree method is not implemented: \(method)")
      }
    }
    print(
      JSON.stringify(object([("jsonrpc", .string("2.0")), ("id", requestID), ("result", result)])))
    fflush(nil)
  } catch {
    print(
      JSON.stringify(
        object([
          ("jsonrpc", .string("2.0")), ("id", requestID),
          (
            "error",
            object([
              ("code", .number(-32000)), ("message", .string(JSString(String(describing: error)))),
            ])
          ),
        ])))
    fflush(nil)
  }
}
