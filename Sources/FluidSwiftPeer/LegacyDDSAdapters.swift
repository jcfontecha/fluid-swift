import FluidDriverDefinitions
import FluidJS
import FluidLegacyDDS
import FluidSharedObjectBase
import FluidTestRuntimeUtils

// shared-array and shared-signal adapters, as `harness/src/dds.ts` createAdapter defines them.

/// The entry-ID bookkeeping of `legacy-dds/src/test/array/fuzzUtils.ts`, driven by `valueChanged`. The generator
/// chooses toggle and toggleMove targets from it, so it must evolve exactly as the TS adapter's three Maps do,
/// including their insertion order and the `undefined` values a missing lookup stores.
private final class ArrayEntryBookkeeping {
  private var insertIds = JSMap<JSString, FluidValue>()
  private var deleteIds = JSMap<JSString, FluidValue>()
  private var moveIds = JSMap<JSString, JSString>()

  /// The `valueChanged` handler of the TS adapter, after its event is journaled.
  func apply(_ op: ISharedArrayOperation) {
    switch op {
    case .insert(let insert):
      insertIds.set(insert.entryId, insert.value)
      _ = deleteIds.delete(insert.entryId)
    case .delete(let delete):
      deleteIds.set(delete.entryId, insertIds.get(delete.entryId) ?? .undefined)
      _ = insertIds.delete(delete.entryId)
      _ = moveIds.delete(delete.entryId)
    case .move(let move):
      if insertIds.has(move.entryId) {
        insertIds.set(move.changedToEntryId, insertIds.get(move.entryId) ?? .undefined)
        _ = insertIds.delete(move.entryId)
        moveIds.set(move.entryId, move.changedToEntryId)
      }
    case .toggle(let toggle):
      if insertIds.has(toggle.entryId) {
        deleteIds.set(toggle.entryId, insertIds.get(toggle.entryId) ?? .undefined)
        _ = insertIds.delete(toggle.entryId)
        _ = moveIds.delete(toggle.entryId)
      } else {
        insertIds.set(toggle.entryId, deleteIds.get(toggle.entryId) ?? .undefined)
        _ = deleteIds.delete(toggle.entryId)
      }
    case .toggleMove(let toggleMove):
      insertIds.set(
        toggleMove.entryId, insertIds.get(toggleMove.changedToEntryId) ?? .undefined)
      _ = insertIds.delete(toggleMove.changedToEntryId)
      _ = moveIds.delete(toggleMove.changedToEntryId)
      moveIds.set(toggleMove.changedToEntryId, toggleMove.entryId)
    }
  }

  func queries(_ array: SharedArrayClass, _ serializer: FluidSerializer) -> JSONValue {
    var queries = JSObject<JSONValue>()
    let values = array.get()
    queries["length"] = .number(Double(values.count))
    queries["values"] = .array(values.map { serializer.encode($0) })
    queries["insertIds"] = .array(insertIds.keys.map(JSONValue.string))
    queries["deleteIds"] = .array(deleteIds.keys.map(JSONValue.string))
    queries["moveIds"] = .array(
      moveIds.entries.map { .array([.string($0.key), .string($0.value)]) })
    return .object(queries)
  }
}

/// `z.string().parse`: the harness only inserts strings.
private func arrayString(_ value: JSONValue) throws -> FluidValue {
  .json(.string(try value.asString()))
}

/// An edit's integer member, or 0 when absent, as TS `e.index ?? 0`.
private func indexOrZero(_ edit: JSONValue) throws -> Int {
  try edit.asObject()["index"]?.asInt() ?? 0
}

func sharedArrayAdapter(
  _ runtime: MockContainerRuntime<SharedArrayClass>, clientId: JSString
) -> RuntimeClient<SharedArrayClass> {
  let serializer = FluidSerializer()
  let bookkeeping = ArrayEntryBookkeeping()
  let entropy = HarnessEntropy(clientId: clientId)
  runtime.channel.generateEntryId = entropy.nextUUID
  let client = RuntimeClient(
    runtime,
    edit: { c, e in
      // Entry IDs are drawn from this edit's entropy context, as TS `uuid()` is.
      entropy.beginEdit()
      switch try e.member("kind").asString() {
      case "insert":
        try c.insert(indexOrZero(e), arrayString(e.member("value")))
      case "delete":
        try c.delete(indexOrZero(e))
      case "move":
        try c.move(e.member("oldIndex").asInt(), e.member("newIndex").asInt())
      case "toggle":
        try c.toggle(e.member("entryId").asString())
      case "toggleMove":
        try c.toggleMove(e.member("oldEntryId").asString(), e.member("newEntryId").asString())
      case "insertBulkAfter":
        let ref = try e.asObject()["ref"].map(arrayString)
        try c.insertBulkAfter(ref, e.member("values").asArray().map(arrayString))
      default:
        throw PeerError(description: "invalid edit")
      }
    },
    state: { c in
      .array(c.get().map { serializer.encode($0) })
    },
    queries: { c in
      bookkeeping.queries(c, serializer)
    })
  runtime.channel.valueChanged = { [weak client] op, isLocal, _ in
    client?.events.append(.array([.string("valueChanged"), op.json(serializer), .bool(isLocal)]))
    bookkeeping.apply(op)
  }
  return client
}

func sharedSignalAdapter(
  _ runtime: MockContainerRuntime<SharedSignalClass>
) -> RuntimeClient<SharedSignalClass> {
  let serializer = FluidSerializer()
  let client = RuntimeClient(
    runtime,
    edit: { c, e in
      switch try e.member("kind").asString() {
      case "notify":
        try c.notify(.json(e.member("value")))
      default:
        throw PeerError(description: "invalid edit")
      }
    },
    state: { _ in
      var state = JSObject<JSONValue>()
      state["persistent"] = .bool(false)
      return .object(state)
    })
  runtime.channel.notifyEvent = { [weak client] metadata, isLocal in
    client?.events.append(.array([.string("notify"), serializer.encode(metadata), .bool(isLocal)]))
  }
  return client
}
