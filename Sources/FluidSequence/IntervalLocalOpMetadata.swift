import FluidJS

/// Ports intervalCollection.ts IntervalMessageLocalMetadata, including pending endpoint membership.
public final class IntervalLocalOpMetadata {
  public enum Kind: String { case add, change, delete }
  public let kind: Kind
  public let localSequence: Int
  public let id: JSString
  public let interval: SequenceInterval?
  public let changesEndpoints: Bool
  let properties: JSObject<JSONValue>

  init(kind: Kind, localSequence: Int, id: JSString, interval: SequenceInterval?,
    changesEndpoints: Bool = false, properties: JSObject<JSONValue> = JSObject()) {
    self.kind = kind
    self.localSequence = localSequence
    self.id = id
    self.interval = interval
    self.changesEndpoints = changesEndpoints
    self.properties = properties
  }
}
