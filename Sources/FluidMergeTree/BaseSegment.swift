import FluidJS

/// Ports mergeTreeNodes.ts BaseSegment: stable identity, stamps, properties and split metadata.
/// Snapshot clones intentionally do not share local reference collections.
/// Markers occupy one position, but never contribute a character to text extraction.
public final class BaseSegment {
  public lazy var localRefs = LocalReferenceCollection(segment: self)
  public var text: JSString?
  public var markerType: Int?
  public var properties: JSObject<JSONValue>?
  public var propertyManager = PropertiesManager()
  public var insertion: Stamp
  public var removals: [Stamp]
  public var length: Int { text?.length ?? 1 }

  public init(
    text: JSString, insertion: Stamp, removals: [Stamp] = [], properties: JSObject<JSONValue>? = nil
  ) {
    self.text = text
    self.insertion = insertion
    self.removals = removals
    self.properties = properties
  }
  public init(markerType: Int, insertion: Stamp, properties: JSObject<JSONValue>? = nil) {
    self.markerType = markerType
    self.insertion = insertion
    self.removals = []
    self.properties = properties
  }
  public func clone() -> BaseSegment {
    let copy: BaseSegment
    if let text {
      copy = BaseSegment(text: text, insertion: insertion, removals: removals, properties: properties)
    } else {
      copy = BaseSegment(markerType: markerType ?? 0, insertion: insertion, properties: properties)
      copy.removals = removals
    }
    copy.propertyManager = propertyManager
    return copy
  }
  public func split(at offset: Int) throws -> BaseSegment {
    guard let text, offset > 0, offset < text.length else {
      throw JSONDecodingError("invalid segment split")
    }
    let right = clone()
    right.text = JSString(utf16: ContiguousArray(text.utf16[offset...]))
    self.text = JSString(utf16: ContiguousArray(text.utf16[..<offset]))
    localRefs.split(at: offset, into: right.localRefs)
    return right
  }
  public func canAppend(_ other: BaseSegment) -> Bool {
    guard let text, let rhs = other.text else { return false }
    return text.utf16.last != 10 && (text.length <= 256 || rhs.length <= 256)
  }
  public func toJSON() -> JSONValue {
    if let text {
      guard let properties else { return .string(text) }
      return object([("text", .string(text)), ("props", .object(properties))])
    }
    var result = JSObject<JSONValue>()
    result["marker"] = object([("refType", .number(Double(markerType ?? 0)))])
    if let properties { result["props"] = .object(properties) }
    return .object(result)
  }
}

