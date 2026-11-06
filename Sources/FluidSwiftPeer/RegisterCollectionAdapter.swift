import FluidDriverDefinitions
import FluidJS
import FluidRegisterCollection
import FluidTestRuntimeUtils

// Register-collection adapter, as `harness/src/dds.ts` createAdapter defines it for `register-collection`.

/// `state`: sorted `[key, read(Atomic), read(LWW), readVersions]` rows. JS default sort compares UTF-16
/// code units, and an absent `readVersions` is `undefined`, which JSON writes as null.
private func registerState(
  _ c: ConsensusRegisterCollection, _ serializer: FluidSerializer
) throws -> JSONValue {
  var rows: [JSONValue] = []
  for key in c.keys().sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
    let atomic = try c.read(key, .atomic)
    let lww = try c.read(key, .lww)
    let versions: JSONValue
    if let list = c.readVersions(key) {
      versions = .array(list.map { serializer.encode($0) })
    } else {
      versions = .null
    }
    rows.append(.array([.string(key), serializer.encode(atomic), serializer.encode(lww), versions]))
  }
  return .array(rows)
}

/// `queries`: `{keys}` in the DDS's own order, which the harness compares against its twin.
private func registerQueries(_ c: ConsensusRegisterCollection) -> JSONValue {
  var object = JSObject<JSONValue>()
  object["keys"] = .array(c.keys().map(JSONValue.string))
  return .object(object)
}

func registerCollectionAdapter(
  _ runtime: MockContainerRuntime<ConsensusRegisterCollection>
) -> RuntimeClient<ConsensusRegisterCollection> {
  let serializer = FluidSerializer()
  let client = RuntimeClient(
    runtime,
    edit: { c, e in
      guard try e.member("kind").asString() == "set" else {
        throw PeerError(description: "invalid edit")
      }
      try c.write(e.member("key").asString(), .json(e.member("value")))
    },
    state: { c in try registerState(c, serializer) },
    queries: { c in registerQueries(c) })
  runtime.channel.atomicChanged = { [weak client] key, value, local in
    client?.events.append(
      .array([.string("atomicChanged"), .string(key), serializer.encode(value), .bool(local)]))
  }
  runtime.channel.versionChanged = { [weak client] key, value, local in
    client?.events.append(
      .array([.string("versionChanged"), .string(key), serializer.encode(value), .bool(local)]))
  }
  return client
}
