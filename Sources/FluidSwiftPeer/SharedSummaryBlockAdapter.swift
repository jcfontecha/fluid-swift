import FluidDriverDefinitions
import FluidJS
import FluidSharedSummaryBlock
import FluidTestRuntimeUtils

// shared-summary-block adapter, as `harness/src/dds.ts` createAdapter defines it.

/// The keys `state` reads, in the TS adapter's order (not sorted).
private let summaryBlockStateKeys: [JSString] = ["a", "b", "c", "0", "10", "constructor"]

func sharedSummaryBlockAdapter(
  _ runtime: MockContainerRuntime<SharedSummaryBlockClass>
) -> RuntimeClient<SharedSummaryBlockClass> {
  RuntimeClient(
    runtime,
    edit: { c, e in
      switch try e.member("kind").asString() {
      case "set":
        let key = try e.member("key").asString()
        c.set(key, try e.member("value"))
      default:
        throw PeerError(description: "invalid edit")
      }
    },
    state: { c in
      var entries: [JSONValue] = []
      for key in summaryBlockStateKeys {
        // JSON.stringify writes an absent (undefined) array element as null.
        let value = c.get(key) ?? JSONValue.null
        entries.append(.array([.string(key), value]))
      }
      return .array(entries)
    })
}
