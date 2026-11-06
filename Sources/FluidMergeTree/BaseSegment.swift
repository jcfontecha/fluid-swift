import FluidJS

/// Ports mergeTreeNodes.ts BaseSegment: stable identity, stamps, properties and split metadata.
/// Snapshot clones intentionally do not share local reference collections.
/// Markers occupy one position, but never contribute a character to text extraction.
public class BaseSegment {
  public internal(set) var endpointType: SequencePosition?
  var detachedOrdinal: [Int]?
  weak var parent: MergeBlock?
  private struct PendingLink { weak var group: SegmentGroup? }
  private var pendingLinks: [PendingLink] = []
  var pendingGroups: [SegmentGroup] {
    get { pendingLinks.compactMap(\.group) }
    set { pendingLinks = newValue.map { PendingLink(group: $0) } }
  }
  public let trackingCollection = TrackingGroupCollection()
  public lazy var localRefs = LocalReferenceCollection(segment: self)
  public var text: JSString? {
    get { nil }
    set { preconditionFailure("only text segments have text") }
  }
  public var markerType: Int? { nil }
  public var properties: JSObject<JSONValue>?
  public var propertyManager = PropertiesManager()
  public var insertion: Stamp
  public var removals: [Stamp]
  public var length: Int { text?.length ?? 1 }

  init(insertion: Stamp, removals: [Stamp] = [], properties: JSObject<JSONValue>? = nil) {
    self.insertion = insertion
    self.removals = removals
    self.properties = properties
  }
  func clonePayload() -> BaseSegment { preconditionFailure("abstract segment") }
  public func clone() -> BaseSegment {
    let copy = clonePayload()
    copy.removals = removals
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
    for group in pendingGroups { group.link(right) }
    for group in trackingCollection.groups { group.link(right) }
    localRefs.split(at: offset, into: right.localRefs)
    return right
  }
  public func canAppend(_ other: BaseSegment) -> Bool { false }
  public func toJSON() -> JSONValue { preconditionFailure("abstract segment") }
}
