import FluidJS

/// Ports mergeTreeDeltaCallback.ts IMergeTreeSegmentDelta: live identity and previous properties.
public struct MergeTreeDeltaSegment {
  public let segment: BaseSegment
  public let propertyDeltas: JSObject<JSONValue>

  public init(segment: BaseSegment, propertyDeltas: JSObject<JSONValue> = JSObject()) {
    self.segment = segment
    self.propertyDeltas = propertyDeltas
  }
}
