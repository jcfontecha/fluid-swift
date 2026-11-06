import FluidJS

/// Ports properties.ts matchProperties. Key order affects serialization, not property matching.
public func matchProperties(_ lhs: JSObject<JSONValue>?, _ rhs: JSObject<JSONValue>?) -> Bool {
  matchPropertyObjects(lhs.map(JSONValue.object) ?? .null, rhs.map(JSONValue.object) ?? .null)
}

private func enumerableProperties(_ value: JSONValue) -> JSObject<JSONValue> {
  switch value {
  case .object(let fields): return fields
  case .array(let items):
    var fields = JSObject<JSONValue>()
    for (index, item) in items.enumerated() { fields[JSString(String(index))] = item }
    return fields
  case .string(let text):
    var fields = JSObject<JSONValue>()
    for (index, unit) in text.utf16.enumerated() {
      fields[JSString(String(index))] = .string(JSString(utf16: ContiguousArray([unit])))
    }
    return fields
  default: return JSObject()
  }
}

private func matchPropertyObjects(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
  let left = enumerableProperties(lhs)
  let right = enumerableProperties(rhs)
  guard left.entries.count == right.entries.count else { return false }
  for (key, value) in left.entries {
    guard let other = right[key] else { return false }
    switch other {
    case .object, .array, .null:
      if !matchPropertyObjects(value, other) { return false }
    default:
      if value != other { return false }
    }
  }
  return true
}
