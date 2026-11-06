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
  public func contains(_ segment: BaseSegment) -> Bool {
    hasOccurred(segment.insertion) && !segment.removals.contains(where: hasOccurred)
  }
}


func object(_ entries: [(JSString, JSONValue)]) -> JSONValue {
  var result = JSObject<JSONValue>()
  for (key, value) in entries { result[key] = value }
  return .object(result)
}
