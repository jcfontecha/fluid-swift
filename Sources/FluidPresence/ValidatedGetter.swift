import FluidJS

/// `StateSchemaValidator<T>` (presence-definitions/src/validatableTypes.ts): returns the value if
/// valid, otherwise `nil` (`undefined`).
public typealias StateSchemaValidator = (_ rawData: JSONValue) -> JSONValue?

/// `KeySchemaValidator<K>`: whether a received map key is valid.
public typealias KeySchemaValidator = (_ unvalidatedKey: JSString) -> Bool

/// A lazy validating getter (`() => validated | undefined`) over one received state. The first
/// call runs the validator and caches the result on the state, including `undefined`; later calls
/// return the cache. The cache is dropped by full-state sends (`stripValidationMetadata`).
public final class ValidatedGetter {
  private let clientState: ValueState
  private let validator: StateSchemaValidator

  init(clientState: ValueState, validator: @escaping StateSchemaValidator) {
    self.clientState = clientState
    self.validator = validator
  }

  public func callAsFunction() -> JSONValue? {
    if clientState.validated == nil {
      // A required state always has a value; `null` stands in for an absent one.
      clientState.validated = ValidationSlot(
        value: validator(clientState.value ?? .null), precedesValue: clientState.value == nil)
    }
    return clientState.validated?.value
  }
}

/// `ValueAccessor<T>`: a remote value, directly or through a validating getter.
public enum ValueAccessor {
  case value(JSONValue?)
  case validated(ValidatedGetter)

  /// The value an application reads: calls the getter for a validated value.
  public func resolve() -> JSONValue? {
    switch self {
    case .value(let value): return value
    case .validated(let getter): return getter()
    }
  }
}

/// Ports `createValidatedGetter` of presence-runtime/src/states/validatedGetter.ts: the raw value
/// without a validator, otherwise a getter that validates on first access.
func createValidatedGetter(clientState: ValueState, validator: StateSchemaValidator?)
  -> ValueAccessor
{
  guard let validator else {
    return .value(clientState.value)
  }
  return .validated(ValidatedGetter(clientState: clientState, validator: validator))
}
