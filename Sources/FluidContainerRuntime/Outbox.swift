import FluidJS

/// The runtime supplies pending-state registration and ID ranges; this layer never owns either.
/// All callbacks run synchronously on the owning container executor.
public final class Outbox {
    public let mainBatch = BatchManager()
    public let blobAttachBatch = BatchManager()
    private let options: OpLifecycleOptions
    private let submitBatch: ([JSONValue]) throws -> Int
    private let onFlush: ([LocalBatchMessage], Int?, Bool) throws -> Void
    private var rebasing = false
    public var opReentrancy: () -> Bool = { false }
    public var reSubmit: ((LocalBatchMessage) throws -> Void)?
    public var shouldSend = true
    public var generateIdAllocation: () throws -> LocalBatchMessage? = { nil }
    public init(options: OpLifecycleOptions, submitBatch: @escaping ([JSONValue]) throws -> Int,
                onFlush: @escaping ([LocalBatchMessage], Int?, Bool) throws -> Void = { _, _, _ in }) {
        self.options = options; self.submitBatch = submitBatch; self.onFlush = onFlush
    }
    public func submit(_ message: LocalBatchMessage, clientSequenceNumber: Int? = nil, blobAttach: Bool = false) throws {
        let reentrant = opReentrancy() && !rebasing
        for batch in [mainBatch, blobAttachBatch] where !reentrant {
            if let ref = batch.referenceSequenceNumber { try require(ref == message.referenceSequenceNumber, "batch reference sequence mismatch") }
            if let csn = batch.clientSequenceNumber, let clientSequenceNumber { try require(csn == clientSequenceNumber, "batch client sequence mismatch") }
        }
        (blobAttach ? blobAttachBatch : mainBatch).push(message, reentrant: reentrant, clientSequenceNumber: clientSequenceNumber)
    }
    public func flush(batchId: String? = nil, referenceSequenceNumber: Int = 0, staged: Bool = false) throws {
        try require(!opReentrancy() || rebasing, "cannot flush reentrantly")
        if mainBatch.messages.isEmpty && blobAttachBatch.messages.isEmpty {
            if let batchId {
                let batches = try OpLifecycle.encode([], options: options, batchId: batchId, referenceSequenceNumber: referenceSequenceNumber)
                var csn: Int?
                if shouldSend && !staged {
                    for batch in batches { csn = try submitBatch(batch) }
                }
                let placeholder = LocalBatchMessage(runtimeOp: object([("type", string("groupedBatch")), ("contents", .array([]))]),
                    referenceSequenceNumber: referenceSequenceNumber,
                    metadata: object([("batchId", string(batchId)), ("groupedOpCount", number(0))]),
                    localOpMetadata: object([("emptyBatch", .bool(true))]), staged: staged)
                try onFlush([placeholder], csn, staged)
            }
            return
        }
        for manager in [blobAttachBatch, mainBatch] where !manager.messages.isEmpty {
            let reentrant = manager.hasReentrantOps
            var messages = try manager.pop()
            if reentrant {
                try require(batchId == nil && !rebasing, "invalid recursive rebase")
                guard let reSubmit else { throw JSONDecodingError("reentrant batch requires runtime resubmit") }
                rebasing = true
                defer { rebasing = false }
                for message in messages { try reSubmit(message) }
                try flush()
                continue
            }
            let staged = messages[0].staged
            var start: Int?
            if shouldSend && !staged {
                if let allocation = try generateIdAllocation() { messages.insert(allocation, at: 0) }
                messages = try OpLifecycle.stamp(messages, batchId: batchId)
                var config = options
                if manager === blobAttachBatch { config.grouped = false }
                let batches = try OpLifecycle.encode(messages, options: config, batchId: batchId)
                for batch in batches { start = try submitBatch(batch) - batch.count + 1 }
            }
            messages = try OpLifecycle.stamp(messages, batchId: batchId)
            try onFlush(messages, start, staged)
        }
    }
}
