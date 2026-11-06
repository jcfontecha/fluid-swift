import FluidJS

/// Ports compressionDefinitions.ts: native H1 supports the upstream lz4 algorithm.
public enum CompressionAlgorithms: String {
  case lz4
}

/// Ports compressionDefinitions.ts: compression threshold is measured before grouping.
public struct CompressionRuntimeOptions {
  public var minimumBatchSizeInBytes: Int
  public var compressionAlgorithm: CompressionAlgorithms
  public init(
    minimumBatchSizeInBytes: Int = 614400, compressionAlgorithm: CompressionAlgorithms = .lz4
  ) {
    self.minimumBatchSizeInBytes = minimumBatchSizeInBytes
    self.compressionAlgorithm = compressionAlgorithm
  }
}

/// Ports opLifecycle/outbox.ts: grouping and chunk sizing belong to their respective managers.
public struct OutboxConfig {
  public var compressionOptions: CompressionRuntimeOptions
  public var maxBatchSizeInBytes: Int
  public init(
    compressionOptions: CompressionRuntimeOptions = .init(), maxBatchSizeInBytes: Int = 1_048_576
  ) {
    self.compressionOptions = compressionOptions
    self.maxBatchSizeInBytes = maxBatchSizeInBytes
  }
}

/// Ports opLifecycle/outbox.ts: flush ordering, allocation, rebase and pending registration.
/// All callbacks run synchronously on the owning container executor.
public final class Outbox {
  public let mainBatch = BatchManager()
  public let blobAttachBatch = BatchManager()
  private let config: OutboxConfig
  private let groupingManager: OpGroupingManager
  private let compressor: OpCompressor
  private let splitter: OpSplitter
  private let submitBatch: ([JSONValue]) throws -> Int
  private let onFlush: ([LocalBatchMessage], Int?, Bool) throws -> Void
  private var rebasing = false
  public var opReentrancy: () -> Bool = { false }
  public var reSubmit: ((LocalBatchMessage) throws -> Void)?
  public var shouldSend = true
  public var generateIdAllocation: () throws -> LocalBatchMessage? = { nil }
  public init(
    config: OutboxConfig = .init(), groupingManager: OpGroupingManager = .init(),
    compressor: OpCompressor = .init(), splitter: OpSplitter,
    submitBatch: @escaping ([JSONValue]) throws -> Int,
    onFlush: @escaping ([LocalBatchMessage], Int?, Bool) throws -> Void = { _, _, _ in }
  ) {
    self.config = config
    self.groupingManager = groupingManager
    self.compressor = compressor
    self.splitter = splitter
    self.submitBatch = submitBatch
    self.onFlush = onFlush
  }
  public func submit(
    _ message: LocalBatchMessage, clientSequenceNumber: Int? = nil, blobAttach: Bool = false
  ) throws {
    let reentrant = opReentrancy() && !rebasing
    for batch in [mainBatch, blobAttachBatch] where !reentrant {
      if let ref = batch.referenceSequenceNumber {
        try require(ref == message.referenceSequenceNumber, "batch reference sequence mismatch")
      }
      if let csn = batch.clientSequenceNumber, let clientSequenceNumber {
        try require(csn == clientSequenceNumber, "batch client sequence mismatch")
      }
    }
    (blobAttach ? blobAttachBatch : mainBatch).push(
      message, reentrant: reentrant, clientSequenceNumber: clientSequenceNumber)
  }
  public func flush(batchId: String? = nil, referenceSequenceNumber: Int = 0, staged: Bool = false)
    throws
  {
    try require(!opReentrancy() || rebasing, "cannot flush reentrantly")
    if mainBatch.messages.isEmpty && blobAttachBatch.messages.isEmpty {
      if let batchId {
        try require(
          splitter.chunkSizeInBytes > 0 && splitter.chunkSizeInBytes < config.maxBatchSizeInBytes,
          "invalid chunk size")
        let empty = try groupingManager.createEmptyGroupedBatch(
          resubmittingBatchId: batchId,
          referenceSequenceNumber: referenceSequenceNumber, staged: staged)
        var csn: Int?
        if shouldSend && !staged {
          csn = try submitBatch(empty.outboundBatch.messages)
        }
        try onFlush([empty.placeholderMessage], csn, staged)
      }
      return
    }
    for manager in [blobAttachBatch, mainBatch] where !manager.messages.isEmpty {
      let reentrant = manager.hasReentrantOps
      var messages = try manager.pop()
      if reentrant {
        try require(batchId == nil && !rebasing, "invalid recursive rebase")
        guard let reSubmit else {
          throw JSONDecodingError("reentrant batch requires runtime resubmit")
        }
        rebasing = true
        defer {
          rebasing = false
        }
        for message in messages {
          try reSubmit(message)
        }
        try flush()
        continue
      }
      let staged = messages[0].staged
      var start: Int?
      if shouldSend && !staged {
        if let allocation = try generateIdAllocation() {
          messages.insert(allocation, at: 0)
        }
        messages = try addBatchMetadata(messages, batchId: batchId)
        let batch = try virtualizeBatch(
          messages,
          groupingEnabled: manager !== blobAttachBatch && groupingManager.groupedBatchingEnabled())
        start = try submitBatch(batch.messages) - batch.messages.count + 1
      }
      messages = try addBatchMetadata(messages, batchId: batchId)
      try onFlush(messages, start, staged)
    }
  }

  private func virtualizeBatch(_ messages: [LocalBatchMessage], groupingEnabled: Bool) throws
    -> OutboundBatch
  {
    try require(
      splitter.chunkSizeInBytes > 0 && splitter.chunkSizeInBytes < config.maxBatchSizeInBytes,
      "invalid chunk size")
    var batch = localBatchToOutboundBatch(messages)
    if groupingEnabled {
      batch = try groupingManager.groupBatch(batch)
    }
    if batch.messages.count == 1
      && batch.contentSizeInBytes >= config.compressionOptions.minimumBatchSizeInBytes
    {
      batch = try compressor.compressBatch(batch)
      if batch.contentSizeInBytes > splitter.chunkSizeInBytes {
        return try splitter.splitSingletonBatchMessage(batch)
      }
    }
    try require(estimateSocketSize(batch) < config.maxBatchSizeInBytes, "BatchTooLarge")
    return batch
  }
}

/// Ports opLifecycle/outbox.ts: conservative transport-envelope overhead per message.
func estimateSocketSize(_ batch: OutboundBatch) -> Int {
  batch.contentSizeInBytes + 200 * batch.messages.count
}

/// Ports opLifecycle/outbox.ts: serialize logical ops and retain the original UTF-16 size.
func localBatchToOutboundBatch(_ messages: [LocalBatchMessage]) -> OutboundBatch {
  var size = 0
  let wire = messages.map { message in
    let text = serializeOp(message.runtimeOp)
    size += text.utf16.count
    return object([
      ("contents", string(text)), ("metadata", message.metadata),
      ("referenceSequenceNumber", number(message.referenceSequenceNumber)),
    ])
  }
  return OutboundBatch(
    messages: wire, contentSizeInBytes: size,
    referenceSequenceNumber: messages.first?.referenceSequenceNumber ?? 0)
}
