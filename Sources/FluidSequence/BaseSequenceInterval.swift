import FluidJS
import FluidMergeTree

/// Ports intervals/sequenceInterval.ts BaseSequenceInterval, the client-independent query interval.
open class BaseSequenceInterval {
  public let intervalType: IntervalType
  public let id: JSString
  public internal(set) var start: LocalReference
  public internal(set) var end: LocalReference
  public let startSide: Side
  public let endSide: Side
  open var properties: JSObject<JSONValue> { JSObject() }
  public var stickiness: Int {
    let startSticky = startSide == .after || start.segment?.endpointType == .start
    let endSticky = endSide == .before || end.segment?.endpointType == .end
    return (startSticky ? 1 : 0) | (endSticky ? 2 : 0)
  }

  public init(id: JSString, intervalType: IntervalType = .slideOnRemove, start: LocalReference, end: LocalReference, startSide: Side = .before, endSide: Side = .before) {
    self.intervalType = intervalType
    self.id = id
    self.start = start
    self.end = end
    self.startSide = startSide
    self.endSide = endSide
  }

  public func compareStart(_ other: BaseSequenceInterval) -> Int {
    let comparison = compareReferencePositions(start, other.start)
    return comparison == 0 ? other.startSide.rawValue - startSide.rawValue : comparison
  }

  public func compareEnd(_ other: BaseSequenceInterval) -> Int {
    let comparison = compareReferencePositions(end, other.end)
    return comparison == 0 ? endSide.rawValue - other.endSide.rawValue : comparison
  }

  public func compare(_ other: BaseSequenceInterval) -> Int {
    let start = compareStart(other)
    if start != 0 { return start }
    let end = compareEnd(other)
    if end != 0 { return end }
    if id.length == 0 || other.id.length == 0 || id == other.id { return 0 }
    return id.utf16.lexicographicallyPrecedes(other.id.utf16) ? -1 : 1
  }

  public func overlaps(_ other: BaseSequenceInterval) -> Bool {
    compareReferencePositions(start, other.end) <= 0 && compareReferencePositions(end, other.start) >= 0
  }
}
