import FluidJS

/// Ports localReference.ts SlidingPreference.
public enum SlidingPreference {
  case backward
  case forward
}

/// Ports localReference.ts LocalReference. The tree owns segment lifetime; references
/// do not create ARC cycles through their segment's collection.
public final class LocalReference {
  public internal(set) weak var segment: BaseSegment?
  public internal(set) var offset: Int
  public let refType: Int
  public let slidingPreference: SlidingPreference
  public var beforeSlide: ((LocalReference) -> Void)?
  public var afterSlide: ((LocalReference) -> Void)?
  internal var bucket = 1

  public init(segment: BaseSegment?, offset: Int, refType: Int,
              slidingPreference: SlidingPreference = .forward) throws {
    guard [64, 128, 256].filter({ refType & $0 != 0 }).count <= 1 else {
      throw JSONDecodingError("Reference types can only be one of Transient, SlideOnRemove, and StayOnRemove")
    }
    self.segment = segment
    self.offset = offset
    self.refType = refType
    self.slidingPreference = slidingPreference
  }
  public func includes(_ flag: Int) -> Bool { refType & flag != 0 }
}
