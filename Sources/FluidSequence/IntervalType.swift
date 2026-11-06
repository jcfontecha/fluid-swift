import FluidJS

/// Ports intervals/intervalUtils.ts persisted IntervalType values.
public enum IntervalType: Int { case simple = 0, slideOnRemove = 2, transient = 4 }

/// Ports intervals/sequenceInterval.ts getSerializedProperties, including pre-ID snapshots.
func getSerializedProperties(_ value: JSONValue) throws -> (id: JSString, properties: JSObject<JSONValue>) {
  let fields = try value.asObject()
  var properties = try fields["properties"].map { try $0.asObject() } ?? JSObject()
  let id: JSString
  if let identity = properties["intervalId"] { id = try identity.asString() }
  else {
    func text(_ value: JSONValue?) -> JSString {
      guard let value else { return "undefined" }
      if case .string(let string) = value { return string }
      return JSString(JSON.stringify(value))
    }
    id = JSString(utf16: JSString("legacy").utf16 + text(fields["start"]).utf16 + JSString("-").utf16 + text(fields["end"]).utf16)
  }
  properties["intervalId"] = nil
  properties["referenceRangeLabels"] = nil
  return (id, properties)
}
