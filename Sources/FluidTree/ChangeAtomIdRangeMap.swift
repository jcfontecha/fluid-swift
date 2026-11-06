/// core/rebase/types.ts: ChangeAtomIdRangeMap aliases the generic RangeMap.
public typealias ChangeAtomIdRangeMap<Value> = RangeMap<ChangeAtomId, Value>

extension RangeMap where Key == ChangeAtomId {
    public convenience init(offsetValue: @escaping (Value, Int) -> Value = { value, _ in value }, context: BTreeStorageContext = BTreeStorageContext()) {
        self.init(offsetKey: { $0.offset($1) }, subtractKeys: subtractChangeAtomIds, offsetValue: offsetValue, context: context)
    }
}

/// core/rebase/types.ts: undefined < string(root) < number.
public func comparePartialRevisions(_ first: RevisionTag?, _ second: RevisionTag?) -> Int {
    switch (first, second) {
    case (nil, nil), (.root, .root): return 0
    case (nil, _): return -1
    case (_, nil): return 1
    case (.root, _): return -1
    case (_, .root): return 1
    case (.compressed(let a), .compressed(let b)): return a < b ? -1 : a > b ? 1 : 0
    }
}
public func subtractChangeAtomIds(_ first: ChangeAtomId, _ second: ChangeAtomId) -> Double {
    let revisions = comparePartialRevisions(first.revision, second.revision)
    return revisions == 0 ? first.localId - second.localId : Double(revisions) * .infinity
}
