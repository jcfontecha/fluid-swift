import FluidJS
import FluidMergeTree

/// Ports matrix/src/permutationvector.ts PermutationSegment.
public final class PermutationSegment: BaseSegment {
  public static let unallocated = -2147483648
  public var start: Int
  private var count: Int
  public override var length: Int { count }
  public init(length: Int, start: Int = unallocated, insertion: Stamp = Stamp(sequence: 0, client: "")) {
    count = length
    self.start = start
    super.init(insertion: insertion)
  }
  public static func fromJSONObject(_ value: JSONValue, stamp: Stamp) throws -> BaseSegment {
    let spec = try value.asArray()
    guard spec.count == 2 else { throw JSONDecodingError("invalid permutation segment") }
    let length = try spec[0].asInt()
    guard length > 0 else { throw JSONDecodingError("invalid permutation length") }
    return try PermutationSegment(length: length, start: spec[1].asInt(), insertion: stamp)
  }
  public override func clonePayload() -> BaseSegment { PermutationSegment(length: count, start: start, insertion: insertion) }
  public override func splitPayload(at offset: Int, into right: BaseSegment) throws {
    guard let right = right as? PermutationSegment else { throw JSONDecodingError("invalid permutation split") }
    right.count = count - offset
    right.start = start == Self.unallocated ? start : start + offset
    count = offset
  }
  public override func canAppend(_ other: BaseSegment) -> Bool {
    guard let other = other as? PermutationSegment else { return false }
    return start == Self.unallocated ? other.start == start : other.start == start + count
  }
  public override func appendPayload(_ other: BaseSegment) { count += other.length }
  public override func toJSON() -> JSONValue { .array([.number(Double(count)), .number(Double(start))]) }
}
