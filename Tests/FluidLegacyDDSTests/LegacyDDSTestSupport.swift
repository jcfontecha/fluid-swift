import FluidDriverDefinitions
import FluidJS
import FluidLegacyDDS
import FluidSharedObjectBase
import FluidTestRuntimeUtils

/// A JS number as a SharedArray value.
func number(_ value: Double) -> FluidValue {
  .json(.number(value))
}

/// A JS string as a SharedArray value.
func text(_ value: JSString) -> FluidValue {
  .json(.string(value))
}

/// The numbers `get()` returns, as `verifyEntries` compares them.
func numbers(_ array: SharedArrayClass) -> [Double] {
  array.get().compactMap { value in
    guard case .json(.number(let number)) = value else {
      return nil
    }
    return number
  }
}

/// The strings `get()` returns.
func strings(_ array: SharedArrayClass) -> [JSString] {
  array.get().compactMap { value in
    guard case .json(.string(let string)) = value else {
      return nil
    }
    return string
  }
}

/// `fillEntries` (legacy-dds/src/test/utilities.ts): inserts each entry at the next index.
func fillEntries(_ array: SharedArrayClass, _ entries: [Double]) throws {
  for (index, entry) in entries.enumerated() {
    try array.insert(index, number(entry))
  }
}

/// Entry IDs `u1`, `u2`, ... in the order they are drawn, as the spec's examples abbreviate UUIDs.
final class EntryIds {
  private var count = 0

  func next() -> JSString {
    count += 1
    return JSString("u\(count)")
  }
}

/// A SharedArray that draws its entry IDs from `ids`.
func makeArray(_ id: JSString, ids: EntryIds = EntryIds()) -> SharedArrayClass {
  let array = SharedArrayClass(id: id)
  array.generateEntryId = ids.next
  return array
}

/// One valueChanged event, as legacy-dds tests record it.
struct ValueChange {
  let op: ISharedArrayOperation
  let isLocal: Bool
}

/// Records every valueChanged event of `array`.
final class ValueChanges {
  private(set) var events: [ValueChange] = []

  init(_ array: SharedArrayClass) {
    array.valueChanged = { [self] op, isLocal, _ in
      events.append(ValueChange(op: op, isLocal: isLocal))
    }
  }
}

/// A connected client of a `MockContainerRuntimeFactory`.
struct ArrayClient {
  let array: SharedArrayClass
  let runtime: MockContainerRuntime<SharedArrayClass>
}

/// Creates a connected SharedArray with deterministic entry IDs prefixed by `prefix`.
func connectedArray(
  _ factory: MockContainerRuntimeFactory<SharedArrayClass>, _ clientId: JSString,
  flushMode: FlushMode = .immediate
) -> ArrayClient {
  let ids = PrefixedEntryIds(clientId)
  let array = SharedArrayClass(id: "array")
  array.generateEntryId = ids.next
  let runtime = factory.createContainerRuntime(
    clientId: clientId, channel: array, flushMode: flushMode)
  return ArrayClient(array: array, runtime: runtime)
}

/// Entry IDs `A-1`, `A-2`, ... so two clients never draw the same ID.
final class PrefixedEntryIds {
  private let prefix: JSString
  private var count = 0

  init(_ prefix: JSString) {
    self.prefix = prefix
  }

  func next() -> JSString {
    count += 1
    return JSString("\(prefix)-\(count)")
  }
}

/// The wire contents of every message `runtime` has sent since the last call, as JSON text.
func sentContents(_ runtime: MockContainerRuntime<SharedArrayClass>) -> [String] {
  runtime.takeOutbound().map { JSON.stringify($0.contents) }
}
