import FluidJS

/// Ports sequencePlace.ts Side and SequencePlace, preserving UTF-16 positions and endpoint sentinels.
public enum Side: Int, Sendable { case before = 0, after = 1 }

public enum SequencePosition: Equatable, Sendable {
  case position(Int)
  case start
  case end

  public init(json: JSONValue) throws {
    switch json {
    case .string("start"): self = .start
    case .string("end"): self = .end
    default: self = .position(try json.asInt())
    }
  }

  public var json: JSONValue {
    switch self {
    case .position(let value): .number(Double(value))
    case .start: .string("start")
    case .end: .string("end")
    }
  }
}

public struct SequencePlace: Sendable {
  public let position: SequencePosition
  public let side: Side
  public let explicitSide: Bool
  public init(_ position: Int) {
    self.position = .position(position)
    side = .before
    explicitSide = false
  }
  public init(_ position: Int, side: Side) {
    self.position = .position(position)
    self.side = side
    explicitSide = true
  }
  public init(position: SequencePosition, side: Side = .before) {
    self.position = position
    self.side = side
    explicitSide = true
  }
  public static var start: SequencePlace { SequencePlace(position: .start) }
  public static var end: SequencePlace { SequencePlace(position: .end) }
}
