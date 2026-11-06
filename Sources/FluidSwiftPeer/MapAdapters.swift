import FluidDriverDefinitions
import FluidJS
import FluidMap
import FluidTestRuntimeUtils

// Map and Directory adapters, as `harness/src/dds.ts` createAdapter defines them.

/// `canonicalValue`: undefined gets an explicit marker so it never collapses into null.
func canonicalValue(_ value: JSONValue?) -> JSONValue {
  guard let value else {
    var marker = JSObject<JSONValue>()
    marker["$fluid"] = .string("undefined")
    return .object(marker)
  }
  return value
}

/// Sorted `[key, canonicalValue]` pairs; JS `<` on strings compares UTF-16 code units.
func canonicalEntries(_ entries: [(JSString, JSONValue?)]) -> JSONValue {
  let sorted = entries.sorted { $0.0.utf16.lexicographicallyPrecedes($1.0.utf16) }
  return .array(sorted.map { .array([.string($0.0), canonicalValue($0.1)]) })
}

/// The edit's value: undefined, a handle (already in its encoded form), or plain JSON.
func editValue(_ edit: JSONValue) throws -> JSONValue? {
  if try edit.asObject()["valueKind"] == .string("undefined") {
    return nil
  }
  return try edit.member("value")
}

func valueChangedJSON(_ changed: IValueChanged) -> JSONValue {
  var object = JSObject<JSONValue>()
  object["key"] = .string(changed.key)
  object["previousValue"] = changed.previousValue
  return .object(object)
}

func mapAdapter(_ runtime: MockContainerRuntime<SharedMap>) -> RuntimeClient<SharedMap> {
  let client = RuntimeClient(
    runtime,
    edit: { c, e in
      switch try e.member("kind").asString() {
      case "set":
        try c.set(e.member("key").asString(), editValue(e))
      case "delete":
        try c.delete(e.member("key").asString())
      case "clear":
        try c.clear()
      default:
        throw PeerError(description: "invalid edit")
      }
    },
    state: { c in canonicalEntries(c.entries()) })
  runtime.channel.valueChanged = { [weak client] changed, local in
    client?.events.append(.array([.string("valueChanged"), valueChangedJSON(changed), .bool(local)]))
  }
  runtime.channel.clearEvent = { [weak client] local in
    client?.events.append(.array([.string("clear"), .bool(local)]))
  }
  return client
}

/// `directoryState`: sorted entries and children in the directory's own child order.
func directoryState(_ directory: SubDirectory) throws -> JSONValue {
  var state = JSObject<JSONValue>()
  state["entries"] = canonicalEntries(try directory.entries())
  var children: [JSONValue] = []
  for (name, child) in try directory.subdirectories() {
    children.append(.array([.string(name), try directoryState(child)]))
  }
  state["children"] = .array(children)
  return .object(state)
}

func directoryAdapter(
  _ runtime: MockContainerRuntime<SharedDirectory>
) -> RuntimeClient<SharedDirectory> {
  let client = RuntimeClient(
    runtime,
    edit: { c, e in
      let path = try e.asObject()["path"]?.asString() ?? "/"
      let directory = try c.getWorkingDirectory(path)
      switch try e.member("kind").asString() {
      case "set":
        try directory?.set(e.member("key").asString(), editValue(e))
      case "delete":
        try directory?.delete(e.member("key").asString())
      case "clear":
        try directory?.clear()
      case "createSubDirectory":
        try directory?.createSubDirectory(e.member("name").asString())
      case "deleteSubDirectory":
        try directory?.deleteSubDirectory(e.member("name").asString())
      default:
        throw PeerError(description: "invalid edit")
      }
    },
    state: { c in try directoryState(c.root) })
  let channel = runtime.channel
  channel.valueChanged = { [weak client] changed, local in
    var object = JSObject<JSONValue>()
    object["key"] = .string(changed.key)
    object["path"] = .string(changed.path)
    object["previousValue"] = changed.previousValue
    client?.events.append(.array([.string("valueChanged"), .object(object), .bool(local)]))
  }
  channel.clearEvent = { [weak client] local in
    client?.events.append(.array([.string("clear"), .bool(local)]))
  }
  channel.cleared = { [weak client] path, local in
    client?.events.append(.array([.string("cleared"), .string(path), .bool(local)]))
  }
  channel.containedValueChanged = { [weak client] changed, local in
    client?.events.append(
      .array([.string("containedValueChanged"), valueChangedJSON(changed), .bool(local)]))
  }
  channel.subDirectoryCreated = { [weak client] path, local in
    client?.events.append(.array([.string("subDirectoryCreated"), .string(path), .bool(local)]))
  }
  channel.subDirectoryDeleted = { [weak client] path, local in
    client?.events.append(.array([.string("subDirectoryDeleted"), .string(path), .bool(local)]))
  }
  return client
}
