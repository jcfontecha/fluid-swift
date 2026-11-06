import FluidCell
import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase
import FluidTestRuntimeUtils

// Cell adapter, as `harness/src/dds.ts` createAdapter defines it for `cell`.

/// `editValue`: undefined, or a native handle to `/handles/a`, or plain JSON. For a handle edit the
/// TS adapter ignores the edit's own value, so this does too.
func cellEditValue(_ edit: JSONValue) throws -> FluidValue {
  let valueKind = try edit.asObject()["valueKind"]
  if valueKind == .string("undefined") {
    return .undefined
  }
  if valueKind == .string("handle") {
    return .handle(FluidHandle(absolutePath: "/handles/a"))
  }
  return .json(try edit.member("value"))
}

func cellAdapter(_ runtime: MockContainerRuntime<SharedCell>) -> RuntimeClient<SharedCell> {
  let serializer = FluidSerializer()
  let client = RuntimeClient(
    runtime,
    edit: { c, e in
      switch try e.member("kind").asString() {
      case "set":
        try c.set(cellEditValue(e))
      case "delete":
        try c.delete()
      default:
        throw PeerError(description: "invalid edit")
      }
    },
    state: { c in
      var state = JSObject<JSONValue>()
      state["empty"] = .bool(c.empty())
      state["value"] = c.empty() ? JSONValue.null : serializer.encode(c.get())
      return .object(state)
    })
  runtime.channel.valueChanged = { [weak client] value in
    client?.events.append(.array([.string("valueChanged"), serializer.encode(value)]))
  }
  runtime.channel.deleteEvent = { [weak client] in
    client?.events.append(.array([.string("delete")]))
  }
  return client
}
