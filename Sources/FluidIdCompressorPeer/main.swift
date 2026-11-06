import FluidIdCompressor
import FluidJS
import Foundation

func run(_ scenario: JSONValue) throws -> JSONValue {
  let version = try scenario.member("version").asInt()
  var clients = try scenario.member("sessions").asArray().map {
    try IdCompressor($0.asString().description, writeVersion: version)
  }
  var results: [JSONValue] = []
  for command in try scenario.member("commands").asArray() {
    let index = try command.member("client").asInt()
    guard clients.indices.contains(index) else { throw JSONDecodingError("Missing client") }
    let a = clients[index]
    var value = JSONValue.null
    switch try command.member("kind").asString().description {
    case "load":
      clients[index] = try IdCompressor.deserialize(
        command.member("serialized").asString().description)
    case "generate":
      var ids: [JSONValue] = []
      let count = try command.member("count").asInt()
      guard count >= 0 else { throw JSONDecodingError("Invalid generate count") }
      for _ in 0..<count {
        let id = try a.generateCompressedId()
        let stable = try a.decompress(id)
        ids.append(
          .array([
            .number(id), .number(try a.normalizeToOpSpace(id)), .string(JSString(stable)),
            .number(try a.recompress(stable)),
          ]))
      }
      value = .array(ids)
    case "take":
      value = try a.takeNextCreationRange().json
    case "reset":
      try a.resetUnfinalizedCreationRange()
    case "capacity":
      a.nextRequestedClusterSize = try command.member("size").asNumber()
    case "finalize":
      try a.finalizeCreationRange(IdCreationRange(json: command.member("range")))
    case "query":
      let id = try command.member("id").asNumber()
      let normalized = try a.normalizeToSessionSpace(
        id, originSessionId: command.member("origin").asString().description)
      value = .array([
        .number(normalized), .number(try a.normalizeToOpSpace(normalized)),
        .string(JSString(try a.decompress(normalized))),
        .number(try a.recompress(command.member("stable").asString().description)),
        try a.tryNormalizeToSessionSpaceWithoutSession(id).map(JSONValue.number) ?? .null,
      ])
    case "restore":
      let local = try command.member("local") == .bool(true)
      clients[index] = try IdCompressor.deserialize(
        a.serialize(local),
        newSessionId: local ? nil : command.member("newSession").asString().description,
        requestedWriteVersion: command.member("version").asInt())
    default:
      throw JSONDecodingError("Unknown command")
    }
    var result = JSObject<JSONValue>()
    result["value"] = value
    result["local"] = .string(JSString(try clients[index].serialize(true)))
    result["summary"] = .string(JSString(try clients[index].serialize(false)))
    results.append(.object(result))
  }
  return .array(results)
}
while let line = readLine() {
  do {
    let result = try run(JSON.parse(line))
    FileHandle.standardOutput.write(Data((JSON.stringify(result) + "\n").utf8))
  } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
  }
}
