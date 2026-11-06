import FluidJS
import FluidMergeTree

/// Ports packages/dds/sequence/src/sharedString.ts SharedString.
public final class SharedString: SharedSegmentSequence {
  public func getText(_ start: Int = 0, _ end: Int? = nil) -> JSString {
    var units = ContiguousArray<UInt16>()
    var position = 0
    let limit = end ?? getLength()
    for segment in client.segments where Perspective.local.contains(segment) {
      defer { position += segment.length }
      let lower = max(0, start - position)
      let upper = min(segment.length, limit - position)
      if lower < upper, let text = segment.text {
        units.append(contentsOf: text.utf16[lower..<upper])
      }
    }
    return JSString(utf16: units)
  }

  @discardableResult
  public func insertText(_ position: Int, _ text: JSString, properties: JSObject<JSONValue>? = nil) throws -> JSONValue? {
    guard text.length > 0 else { return nil }
    let segment = properties.map {
      sequenceObject([("text", .string(text)), ("props", .object($0))])
    } ?? .string(text)
    return try insertSegment(position, segment)
  }

  public func replaceText(_ start: Int, _ end: Int, _ text: JSString, properties: JSObject<JSONValue>? = nil) throws {
    // sequence.ts replaceRange inserts at max first; empty insertion does not remove.
    if try insertText(max(start, end), text, properties: properties) != nil, start < end {
      try removeRange(start, end)
    }
  }

  public func removeText(_ start: Int, _ end: Int) throws {
    try removeRange(start, end)
  }
}
