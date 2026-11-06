import FluidJS

/// Stamps use sequencing order, never lexical client IDs. Pending edits sort last.
public struct Stamp: Equatable, Sendable, Comparable {
  public var sequence: Int
  public var client: JSString
  public var localSequence: Int?
  public init(sequence: Int, client: JSString, localSequence: Int? = nil) {
    self.sequence = sequence
    self.client = client
    self.localSequence = localSequence
  }
  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.sequence == -1 {
      return rhs.sequence == -1 && (lhs.localSequence ?? 0) < (rhs.localSequence ?? 0)
    }
    return rhs.sequence == -1 || lhs.sequence < rhs.sequence
  }
}

public enum Perspective: Sendable {
  case local
  case prior(sequence: Int, client: JSString)
  case reconnecting(sequence: Int, localSequence: Int)

  public func hasOccurred(_ stamp: Stamp) -> Bool {
    switch self {
    case .local: return true
    case .prior(let sequence, let client):
      return (stamp.sequence != -1 && stamp.sequence <= sequence) || stamp.client == client
    case .reconnecting(let sequence, let localSequence):
      return (stamp.sequence != -1 && stamp.sequence <= sequence)
        || stamp.localSequence.map { $0 <= localSequence } == true
    }
  }
  public func contains(_ segment: Segment) -> Bool {
    hasOccurred(segment.insertion) && !segment.removals.contains(where: hasOccurred)
  }
}

/// Payload and provenance are values; splitting copies only segment metadata and UTF-16 buffers.
/// Markers occupy one position, but never contribute a character to text extraction.
public struct Segment: Sendable {
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
  public mutating func split(at offset: Int) throws -> Segment {
    guard let text, offset > 0, offset < text.length else {
      throw JSONDecodingError("invalid segment split")
    }
    var right = self
    right.text = JSString(utf16: ContiguousArray(text.utf16[offset...]))
    self.text = JSString(utf16: ContiguousArray(text.utf16[..<offset]))
    return right
  }
  public func canAppend(_ other: Segment) -> Bool {
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

func object(_ entries: [(JSString, JSONValue)]) -> JSONValue {
  var result = JSObject<JSONValue>()
  for (key, value) in entries { result[key] = value }
  return .object(result)
}
