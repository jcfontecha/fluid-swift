import FluidJS

/// Ports segmentPropertiesManager.ts: production raw-property histories and pending overlays.
/// Adjust operations are feature-gated off in the production client.
public struct PropertiesManager: Sendable {
  private struct Change: Sendable {
    var localSequence: Int
    var value: JSONValue
  }
  private struct History: Sendable {
    var consensus: JSONValue
    var local: [Change] = []
  }
  private var changes = JSObject<History>()

  public init() {}

  public mutating func handleProperties(
    _ updates: JSObject<JSONValue>, properties: inout JSObject<JSONValue>?, stamp: Stamp
  ) {
    var values = properties ?? JSObject<JSONValue>()
    for (key, value) in updates.entries {
      var history = changes[key] ?? History(consensus: values[key] ?? .null)
      if stamp.sequence == -1 {
        history.local.append(Change(localSequence: stamp.localSequence ?? 0, value: value))
      } else {
        // TS folds raw remote writes immediately when there are no adjustment records,
        // even above MSN. getAtSeq deliberately preserves this upstream behavior.
        history.consensus = value
      }
      let current = history.local.last?.value ?? history.consensus
      values[key] = current == .null ? nil : current
      changes[key] = history.local.isEmpty ? nil : history
    }
    properties = values
  }

  public mutating func ack(localSequence: Int) {
    for (key, var history) in changes.entries {
      guard let first = history.local.first, first.localSequence == localSequence else { continue }
      history.consensus = first.value
      history.local.removeFirst()
      changes[key] = history.local.isEmpty ? nil : history
    }
  }

  public mutating func rollback(localSequence: Int, properties: inout JSObject<JSONValue>?) {
    var values = properties ?? JSObject<JSONValue>()
    for (key, var history) in changes.entries {
      guard history.local.last?.localSequence == localSequence else { continue }
      history.local.removeLast()
      let value = history.local.last?.value ?? history.consensus
      values[key] = value == .null ? nil : value
      changes[key] = history.local.isEmpty ? nil : history
    }
    properties = values
  }

  public func getAtSeq(_ properties: JSObject<JSONValue>?) -> JSObject<JSONValue> {
    var values = properties ?? JSObject<JSONValue>()
    for (key, history) in changes.entries {
      values[key] = history.consensus == .null ? nil : history.consensus
    }
    return values
  }
}
