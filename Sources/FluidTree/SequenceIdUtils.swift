/// shared-tree-core/editManagerFormatCommons.ts: SequenceId.
/// `indexInBatch` is a JS number: search bounds use `Number.POSITIVE_INFINITY`, so it is a Double.
public struct SequenceId: Equatable, Sendable {
    public var sequenceNumber: Int
    public var indexInBatch: Double?
    public init(sequenceNumber: Int, indexInBatch: Double? = nil) {
        self.sequenceNumber = sequenceNumber
        self.indexInBatch = indexInBatch
    }
}

/// shared-tree-core/sequenceIdUtils.ts: sequenceIdComparator.
/// An absent `indexInBatch` compares equal to 0; equal values (including two infinities) compare 0.
public func sequenceIdComparator(_ a: SequenceId, _ b: SequenceId) -> Int {
    if a.sequenceNumber != b.sequenceNumber {
        return a.sequenceNumber < b.sequenceNumber ? -1 : 1
    }
    if a.indexInBatch == b.indexInBatch {
        return 0
    }
    let difference = (a.indexInBatch ?? 0) - (b.indexInBatch ?? 0)
    return difference < 0 ? -1 : difference > 0 ? 1 : 0
}

/// shared-tree-core/sequenceIdUtils.ts: equalSequenceIds.
public func equalSequenceIds(_ a: SequenceId, _ b: SequenceId) -> Bool {
    sequenceIdComparator(a, b) == 0
}

/// shared-tree-core/sequenceIdUtils.ts: minSequenceId.
public func minSequenceId(_ a: SequenceId, _ b: SequenceId) -> SequenceId {
    sequenceIdComparator(a, b) < 0 ? a : b
}

/// shared-tree-core/sequenceIdUtils.ts: maxSequenceId.
public func maxSequenceId(_ a: SequenceId, _ b: SequenceId) -> SequenceId {
    sequenceIdComparator(a, b) > 0 ? a : b
}

/// shared-tree-core/sequenceIdUtils.ts: getUpperBoundOfPreviousSequenceId.
/// `{1, 2}` -> `{1, 1}`; `{2}` -> `{1, +Infinity}`.
public func getUpperBoundOfPreviousSequenceId(_ sequenceId: SequenceId) -> SequenceId {
    precondition(sequenceId.indexInBatch.map(\.isFinite) ?? true, "0xabc: indexInBatch must not be infinity")
    if sequenceId.indexInBatch == nil || sequenceId.indexInBatch == 0 {
        return SequenceId(sequenceNumber: sequenceId.sequenceNumber - 1, indexInBatch: .infinity)
    }
    return SequenceId(sequenceNumber: sequenceId.sequenceNumber, indexInBatch: (sequenceId.indexInBatch ?? 0) - 1)
}
