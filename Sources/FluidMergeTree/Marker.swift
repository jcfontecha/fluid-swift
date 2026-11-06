import FluidJS

/// Ports mergeTreeNodes.ts Marker: a one-position non-text segment.
public final class Marker: BaseSegment {
  public let refType: Int
  public override var markerType: Int? { refType }
  public init(refType: Int, insertion: Stamp, properties: JSObject<JSONValue>? = nil) {
    self.refType = refType
    super.init(insertion: insertion, properties: properties)
  }
  override func clonePayload() -> BaseSegment {
    Marker(refType: refType, insertion: insertion, properties: properties)
  }
  public override func toJSON() -> JSONValue {
    var result = JSObject<JSONValue>()
    result["marker"] = object([("refType", .number(Double(refType)))])
    if let properties { result["props"] = .object(properties) }
    return .object(result)
  }
}
