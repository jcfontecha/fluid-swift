import FluidJS

/// Port of `packages/dds/map/src/localValues.ts` ILocalValue. `nil` is JS `undefined`, which is a
/// storable value distinct from an absent key.
public struct ILocalValue {
  public let value: JSONValue?
}

/// Port of `internalInterfaces.ts` ISerializedValue: `value` is the JSON text, absent for undefined.
/// `parsed` is `JSON.parse(value)`, which summaries embed; it is the serialized JSON value itself.
struct ISerializedValue {
  let type: JSString
  let value: JSString?
  let parsed: JSONValue?
}

/// `ValueType[ValueType.Plain]` (shared-object-base/src/valueType.ts).
let plainValueType: JSString = "Plain"

/// Port of `localValues.ts` serializeValue. Handles are already in their encoded JSON form.
func serializeValue(_ value: JSONValue?) -> ISerializedValue {
  ISerializedValue(
    type: plainValueType, value: value.map { JSString(JSON.stringify($0)) }, parsed: value)
}

/// The persisted and wire `ISerializableValue` `{type:"Plain",value}`, in that property order.
/// Undefined omits `value`, as `JSON.stringify` does.
func serializableValue(_ value: JSONValue?) -> JSONValue {
  var serializable = JSObject<JSONValue>()
  serializable["type"] = .string(plainValueType)
  serializable["value"] = value
  return .object(serializable)
}

/// Reads `ISerializableValue.value`. Legacy `Shared` values need `localValues.ts`
/// migrateIfSharedSerializable, which resolves relative handle URLs against the serializer's
/// context; that migration is not ported, so such values fail loudly instead of loading wrong.
func parseSerializableValue(_ serializable: JSONValue) throws -> JSONValue? {
  let object = try serializable.asObject()
  guard object["type"] == .string(plainValueType) else {
    throw JSONDecodingError("unsupported legacy map value type")
  }
  return object["value"]
}
