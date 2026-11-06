import FluidJS

/// Port of `packages/dds/map/src/localValues.ts` ILocalValue. `nil` is JS `undefined`, which is a
/// storable value distinct from an absent key.
public struct ILocalValue {
  public let value: JSONValue?
}

/// Port of `internalInterfaces.ts` ISerializedValue used during summary partitioning.
/// Only the serialized UTF-16 length is retained: callers embed `parsed`, not the JSON text.
struct ISerializedValue {
  let type: JSString
  let valueLength: Int
  let parsed: JSONValue?
}

/// `ValueType[ValueType.Plain]` (shared-object-base/src/valueType.ts).
let plainValueType: JSString = "Plain"

/// `ISerializableValue` and op member names, built once instead of on every op.
let typeMember: JSString = "type"
let valueMember: JSString = "value"

/// Port of `localValues.ts` serializeValue. Handles are already in their encoded JSON form.
func serializeValue(_ value: JSONValue?) -> ISerializedValue {
  ISerializedValue(
    type: plainValueType, valueLength: value.map { JSON.stringify($0).utf16.count } ?? 0, parsed: value)
}

/// The persisted and wire `ISerializableValue` `{type:"Plain",value}`, in that property order.
/// Undefined omits `value`, as `JSON.stringify` does.
func serializableValue(_ value: JSONValue?) -> JSONValue {
  var serializable = JSObject<JSONValue>()
  serializable[typeMember] = .string(plainValueType)
  serializable[valueMember] = value
  return .object(serializable)
}

/// Reads `ISerializableValue.value`. Legacy `Shared` values need `localValues.ts`
/// migrateIfSharedSerializable, which resolves relative handle URLs against the serializer's
/// context; that migration is not ported, so such values fail loudly instead of loading wrong.
func parseSerializableValue(_ serializable: JSONValue) throws -> JSONValue? {
  let object = try serializable.asObject()
  guard object[typeMember] == .string(plainValueType) else {
    throw JSONDecodingError("unsupported legacy map value type")
  }
  return object[valueMember]
}
