import FluidJS

/// Ports localReference.ts SlidingPreference.
public enum SlidingPreference {
  case backward
  case forward
}

/// Ports localReference.ts LocalReference. The tree owns segment lifetime; references
/// do not create ARC cycles through their segment's collection.
public final class LocalReference {
  private weak var weakSegment: BaseSegment?
  private var retainedSegment: BaseSegment?
  public internal(set) var segment: BaseSegment? {
    get { retainedSegment ?? weakSegment }
    set {
      weakSegment = newValue
      retainedSegment = includes(256) ? newValue : nil
    }
  }
  func retainDetachedSegment() { retainedSegment = weakSegment }
  public internal(set) var offset: Int
  public let trackingCollection = TrackingGroupCollection()
  public private(set) var refType: Int
  public let slidingPreference: SlidingPreference
  public let canSlideToEndpoint: Bool
  public var properties: JSObject<JSONValue>?
  public var beforeSlide: ((LocalReference) -> Void)?
  public var afterSlide: ((LocalReference) -> Void)?
  internal var bucket = 1

  public init(
    segment: BaseSegment?, offset: Int, refType: Int,
    slidingPreference: SlidingPreference = .forward, canSlideToEndpoint: Bool = false
  ) throws {
    guard [64, 128, 256].filter({ refType & $0 != 0 }).count <= 1 else {
      throw JSONDecodingError(
        "Reference types can only be one of Transient, SlideOnRemove, and StayOnRemove")
    }
    self.offset = offset
    self.refType = refType
    self.slidingPreference = slidingPreference
    self.canSlideToEndpoint = canSlideToEndpoint
    self.segment = segment
  }
  private init(transient reference: LocalReference) {
    offset = reference.offset
    refType = (reference.refType & ~(64 | 128)) | 256
    slidingPreference = reference.slidingPreference
    canSlideToEndpoint = reference.canSlideToEndpoint
    properties = reference.properties
    segment = reference.segment
  }

  public func transientClone() -> LocalReference { LocalReference(transient: self) }

  public func setReferenceType(_ value: Int) throws {
    guard [64, 128, 256].filter({ value & $0 != 0 }).count <= 1 else {
      throw JSONDecodingError("Reference types can only be one of Transient, SlideOnRemove, and StayOnRemove")
    }
    let current = segment
    refType = value
    retainedSegment = includes(256) ? current : nil
  }

  public func includes(_ flag: Int) -> Bool { refType & flag != 0 }
}
