import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidSharedObjectBase

/// Port of `@fluidframework/shared-summary-block` `SharedSummaryBlockClass` (sharedSummaryBlock.ts).
///
/// State that is distributed only by summaries. It never generates ops, so it is a `SharedObject`
/// with `Never` as its local-op metadata: no local op can exist to carry metadata. The factory
/// (sharedSummaryBlockFactory.ts) has no Swift counterpart; `type` and loading come from `Channel`,
/// as they do for `SharedCounter`.
public final class SharedSummaryBlockClass: SharedObject<Never> {
  public override class var type: JSString {
    "https://graph.microsoft.com/types/shared-summary-block"
  }

  private static let snapshotFileName: JSString = "header"

  /// Insertion-ordered, like the TS `Map`. A nil value is an explicit undefined entry: it keeps its
  /// position, and `summarize()` omits it, as `JSON.stringify` omits undefined members.
  private var data = JSMap<JSString, JSONValue?>()

  /// TS `get`: the stored value, or nil when the key is absent or was set to undefined.
  public func get(_ key: JSString) -> JSONValue? {
    guard let stored = data.get(key) else {
      return nil
    }
    return stored
  }

  /// TS `set`. The TS `dirty()` call has no counterpart: `summarize()` always writes the full state.
  public func set(_ key: JSString, _ value: JSONValue?) {
    data.set(key, value)
  }

  public override func loadCore(_ summary: SummaryTree) throws {
    let contents = try summary.readAndParse(Self.snapshotFileName).asObject()
    for (key, value) in contents.entries {
      data.set(key, value)
    }
  }

  public override func summarize() -> SummaryTree {
    var contents = JSObject<JSONValue>()
    for (key, value) in data.entries {
      guard let value else {
        continue
      }
      // summarizeCore assigns with `contentsBlob[key] = value`. For "__proto__" that sets the
      // prototype (object values) or is ignored (primitives), so it never becomes an own property.
      guard key != "__proto__" else {
        continue
      }
      contents[key] = value
    }
    let text = JSString(JSON.stringify(.object(contents)))
    return .singleBlob(Self.snapshotFileName, text)
  }

  /// Every invocation throws: this DDS never receives ops, so any delivered message is a bug.
  public override func processMessagesCore(_ contents: [Content], local: Bool) throws {
    throw SharedObjectError("shared summary block should not generate any ops.")
  }

  public override func applyStashedOp(_ content: JSONValue) throws {
    throw SharedObjectError("not implemented")
  }
}
