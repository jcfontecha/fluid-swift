import FluidJS

/// Ports localReference.ts LocalReferenceCollection. Ordered offset/bucket storage;
/// transient references never join, and therefore deliberately do not follow splits.
public final class LocalReferenceCollection {
  private weak var segment: BaseSegment?
  private var refs: [LocalReference] = []
  init(segment: BaseSegment) { self.segment = segment }
  public var size: Int { refs.count }
  public var empty: Bool { refs.isEmpty }
  public var references: [LocalReference] { refs }
  public func has(_ ref: LocalReference) -> Bool {
    ref.segment === segment && refs.contains { $0 === ref }
  }
  public func addLocalRef(_ ref: LocalReference, offset: Int) {
    add(ref, offset: offset, bucket: 1)
  }
  internal func add(_ ref: LocalReference, offset: Int, bucket: Int, prepend: Bool = false) {
    ref.segment?.localRefs.removeLocalRef(ref)
    ref.segment = segment
    ref.offset = offset
    ref.bucket = bucket
    if ref.includes(256) { return }
    let index = refs.firstIndex {
      $0.offset > offset || ($0.offset == offset && ($0.bucket > bucket || (prepend && $0.bucket == bucket)))
    } ?? refs.count
    refs.insert(ref, at: index)
  }
  internal func addSliding(_ ref: LocalReference, forward: Bool, preceding: LocalReference?) {
    guard let segment else { return }
    add(ref, offset: forward ? 0 : segment.length - 1, bucket: forward ? 0 : 2, prepend: forward)
    if forward, let preceding,
       let source = refs.firstIndex(where: { $0 === ref }) {
      refs.remove(at: source)
      if let index = refs.firstIndex(where: { $0 === preceding }) {
        refs.insert(ref, at: index + 1)
      }
    }
  }
  @discardableResult
  public func removeLocalRef(_ ref: LocalReference) -> LocalReference? {
    guard let index = refs.firstIndex(where: { $0 === ref }) else { return nil }
    refs.remove(at: index)
    ref.segment = nil
    ref.offset = 0
    return ref
  }
  internal func split(at offset: Int, into right: LocalReferenceCollection) {
    for ref in refs where ref.offset >= offset {
      right.add(ref, offset: ref.offset - offset, bucket: ref.bucket)
    }
  }
  public func append(_ other: LocalReferenceCollection) {
    guard let segment else { return }
    for ref in other.references {
      add(ref, offset: segment.length + ref.offset, bucket: ref.bucket)
    }
  }
}
