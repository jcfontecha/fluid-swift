import FluidJS

/// Ports opLifecycle/batchManager.ts: partial batch accumulation and LIFO rollback.
public final class BatchManager {
  public private(set) var messages: [LocalBatchMessage] = []
  public private(set) var clientSequenceNumber: Int?
  public private(set) var hasReentrantOps = false
  public init() {}
  public var referenceSequenceNumber: Int? { messages.last?.referenceSequenceNumber }
  public func push(
    _ message: LocalBatchMessage, reentrant: Bool = false, clientSequenceNumber: Int? = nil
  ) {
    if messages.isEmpty {
      self.clientSequenceNumber = clientSequenceNumber
    }
    hasReentrantOps = hasReentrantOps || reentrant
    messages.append(message)
  }
  public func pop() throws -> [LocalBatchMessage] {
    try require(!messages.isEmpty, "expected non-empty batch")
    let result = messages
    messages.removeAll(keepingCapacity: true)
    clientSequenceNumber = nil
    hasReentrantOps = false
    return result
  }
  public func rollback(to count: Int, process: (LocalBatchMessage) throws -> Void) throws {
    try require(count >= 0 && count <= messages.count, "invalid checkpoint")
    let suffix = Array(messages[count...])
    messages.removeSubrange(count...)
    for message in suffix.reversed() {
      try process(message)
    }
    try require(messages.count == count, "ops generated during rollback")
  }
}

/// Ports opLifecycle/batchManager.ts: reconnect identity from the original outer CSN.
public func generateBatchId(originalClientId: String, batchStartCsn: Int) -> String {
  "\(originalClientId)_[\(batchStartCsn)]"
}

/// Ports opLifecycle/batchManager.ts: explicit replay identity takes precedence.
public func getEffectiveBatchId(batchId: String?, clientId: String, batchStartCsn: Int) -> String {
  batchId ?? generateBatchId(originalClientId: clientId, batchStartCsn: batchStartCsn)
}

/// Ports opLifecycle/batchManager.ts: mark boundaries after allocation has been prepended.
public func addBatchMetadata(_ input: [LocalBatchMessage], batchId: String? = nil) throws
  -> [LocalBatchMessage]
{
  guard !input.isEmpty else {
    return []
  }
  var messages = input
  if messages.count > 1 {
    var first = try messages[0].metadata?.asObject() ?? JSObject()
    first["batch"] = .bool(true)
    messages[0].metadata = .object(first)
    var last = try messages[messages.count - 1].metadata?.asObject() ?? JSObject()
    last["batch"] = .bool(false)
    messages[messages.count - 1].metadata = .object(last)
  }
  if let batchId {
    var meta = try messages[0].metadata?.asObject() ?? JSObject()
    meta["batchId"] = string(batchId)
    messages[0].metadata = .object(meta)
  }
  return messages
}
