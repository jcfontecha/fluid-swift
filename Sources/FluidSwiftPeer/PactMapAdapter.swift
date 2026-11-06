import FluidDriverDefinitions
import FluidJS
import FluidPactMap
import FluidTestRuntimeUtils

// PactMap adapter, as `harness/src/dds.ts` createAdapter defines it for `pact-map`.

/// The keys `state` reads, in the TS adapter's order (not sorted).
private let pactMapStateKeys: [JSString] = ["a", "b", "c", "0", "10", "constructor"]

func pactMapAdapter(_ runtime: MockContainerRuntime<PactMapClass>) -> RuntimeClient<PactMapClass> {
  let client = RuntimeClient(
    runtime,
    edit: { c, e in
      switch try e.member("kind").asString() {
      case "set":
        try c.set(e.member("key").asString(), editValue(e))
      case "delete":
        try c.delete(e.member("key").asString())
      default:
        throw PeerError(description: "invalid edit")
      }
    },
    state: { c in
      .array(pactMapStateKeys.map { key in pactMapKeyState(c, key) })
    })
  runtime.channel.pending = { [weak client] key in
    client?.events.append(.array([.string("pending"), .string(key)]))
  }
  runtime.channel.accepted = { [weak client] key in
    client?.events.append(.array([.string("accepted"), .string(key)]))
  }
  return client
}

/// `{key, value: get, details: getWithDetails, pending: isPending, proposal: getPending}`; undefined
/// members are omitted, as `JSON.stringify` does.
private func pactMapKeyState(_ c: PactMapClass, _ key: JSString) -> JSONValue {
  var state = JSObject<JSONValue>()
  state["key"] = .string(key)
  state["value"] = c.get(key)
  if let details = c.getWithDetails(key) {
    var detailsObject = JSObject<JSONValue>()
    detailsObject["value"] = details.value
    detailsObject["acceptedSequenceNumber"] = .number(Double(details.acceptedSequenceNumber))
    state["details"] = .object(detailsObject)
  }
  state["pending"] = .bool(c.isPending(key))
  state["proposal"] = c.getPending(key)
  return .object(state)
}
