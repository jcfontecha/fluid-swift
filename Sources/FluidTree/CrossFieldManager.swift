/// feature-libraries/modular-schema/crossFieldQueries.ts.
public enum CrossFieldTarget: Hashable {
    case source
    case destination
}

/// util/rangeMap.ts: first homogeneous range returned by a cross-field query.
public struct CrossFieldRange<Value> {
    public let length: Int
    public let value: Value?
    public init(length: Int, value: Value?) {
        self.length = length
        self.value = value
    }
}

/// feature-libraries/modular-schema/crossFieldQueries.ts.
/// The modular owner records dependencies and schedules invalidated fields again.
public protocol CrossFieldManager: AnyObject {
    associatedtype Value
    func get(_ target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int, addDependency: Bool) -> CrossFieldRange<Value>
    func set(_ target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int, value: Value, invalidateDependents: Bool) throws
    func onMoveIn(_ id: ChangeAtomId)
    func moveKey(_ target: CrossFieldTarget, revision: RevisionTag?, id: Double, count: Int) throws
}
