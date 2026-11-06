import FluidJS

/// Ports textSegment.ts: UTF-16 text payload, text serialization and append policy.
public final class TextSegment: BaseSegment {
  private var units: JSString
  public override var text: JSString? {
    get { units }
    set {
      guard let newValue else { preconditionFailure("text payload cannot be absent") }
      units = newValue
    }
  }
  public init(
    text: JSString, insertion: Stamp, removals: [Stamp] = [], properties: JSObject<JSONValue>? = nil
  ) {
    units = text
    super.init(insertion: insertion, removals: removals, properties: properties)
  }
  override func clonePayload() -> BaseSegment {
    TextSegment(text: units, insertion: insertion, properties: properties)
  }
  public override func canAppend(_ other: BaseSegment) -> Bool {
    guard let text = other.text else { return false }
    return units.utf16.last != 10 && (units.length <= 256 || text.length <= 256)
  }
  public override func toJSON() -> JSONValue {
    guard let properties else { return .string(units) }
    return object([("text", .string(units)), ("props", .object(properties))])
  }
}
