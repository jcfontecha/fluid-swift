import FluidJS

func object(_ entries: [(JSString, JSONValue?)]) -> JSONValue {
  var value = JSObject<JSONValue>()
  for (key, entry) in entries {
    value[key] = entry
  }
  return .object(value)
}
func string(_ value: String) -> JSONValue { .string(JSString(value)) }
func number(_ value: Int) -> JSONValue { .number(Double(value)) }
func field(_ value: JSONValue, _ key: JSString) throws -> JSONValue? { try value.asObject()[key] }
func require(_ condition: Bool, _ message: String) throws {
  guard condition else {
    throw JSONDecodingError(message)
  }
}
