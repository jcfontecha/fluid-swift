import FluidJS
import Foundation

/// Ports pendingStateManager.ts. All callbacks execute on the container's serial executor.
public final class PendingStateManager {
  private var pending: [JSONValue] = []
  private var head = 0
  private var saved: [JSONValue] = []
  private var initial: [JSONValue] = []
  private var lastReplayClientId: String?
  public private(set) var isApplyingStashedOps = false
  public var onAfterStashedOpsApplied: () -> Void = {}
  public var generateUUID: () -> String = { UUID().uuidString.lowercased() }
  public init() {}
  public init(stashedLocalState: JSONValue) throws {
    initial = try stashedLocalState.member("pendingStates").asArray()
    isApplyingStashedOps = !initial.isEmpty
  }
  public var pendingMessagesCount: Int { pending.count - head + initial.count }
  public func hasPendingMessages() -> Bool { pendingMessagesCount != 0 }
  public func hasPendingUserChanges() throws -> Bool {
    if !initial.isEmpty { return true }
    for record in pending.dropFirst(head) {
      let op = try record.member("runtimeOp")
      let type = try op.member("type").asString()
      if ["groupedBatch", "idAllocation", "documentSchemaChange", "GC"].contains(type.description) { continue }
      if type == "component", try field(op.member("contents"), "address") == string("_scheduler") { continue }
      if type == "attach", try field(op.member("contents"), "id") == string("_scheduler") { continue }
      return true
    }
    return false
  }
  public func onFlushBatch(_ batch: [LocalBatchMessage], clientSequenceNumber: Int?, clientId: String, staged: Bool = false) throws {
    try require(clientSequenceNumber == nil || !staged, "0xb84")
    let info = object([
      ("clientId", string(clientSequenceNumber == nil ? generateUUID() : clientId)),
      ("batchStartCsn", number(clientSequenceNumber ?? -1)),
      ("length", number(batch.count)), ("staged", .bool(staged)),
    ])
    for message in batch {
      pending.append(object([
        ("type", string("message")), ("referenceSequenceNumber", number(message.referenceSequenceNumber)),
        ("content", string(serializeOp(message.runtimeOp))), ("runtimeOp", message.runtimeOp),
        ("localOpMetadata", message.localOpMetadata), ("opMetadata", message.metadata), ("batchInfo", info),
      ]))
    }
  }
  private func serializable(_ record: JSONValue) throws -> JSONValue {
    var value = try record.asObject()
    value["runtimeOp"] = nil
    value["localOpMetadata"] = nil
    return .object(value)
  }
  public func getLocalState(snapshotSequenceNumber: Int? = nil) throws -> JSONValue {
    try require(initial.isEmpty, "0x2e9")
    var records = try saved.filter { try $0.member("sequenceNumber").asInt() > (snapshotSequenceNumber ?? 0) }
    for record in pending.dropFirst(head) {
      if let snapshotSequenceNumber {
        try require(record.member("referenceSequenceNumber").asInt() >= snapshotSequenceNumber, "trying to stash ops older than our latest snapshot")
      }
      records.append(try serializable(record))
    }
    return object([("pending", object([("pendingStates", .array(records))]))])
  }
  private func effectiveId(_ record: JSONValue) throws -> JSString {
    if let metadata = try field(record, "opMetadata"), let id = try field(metadata, "batchId") { return try id.asString() }
    let info = try record.member("batchInfo")
    var units = try info.member("clientId").asString().utf16
    units.append(contentsOf: JSString("_[\(try info.member("batchStartCsn").asInt())]").utf16)
    return JSString(utf16: units)
  }
  public func processInboundMessages(_ inbound: JSONValue, local: Bool) throws -> [JSONValue] {
    if let start = try field(inbound, "batchStart") {
      if local {
        try require(pending.count > head, "0xa21")
        try require(pending[head].member("batchInfo").member("staged") != .bool(true), "0xb85")
      } else if pending.count > head {
        var units = try start.member("clientId").asString().utf16
        units.append(contentsOf: JSString("_[\(try start.member("batchStartCsn").asInt())]").utf16)
        let id = try field(start, "batchId")?.asString() ?? JSString(utf16: units)
        try require(id != effectiveId(pending[head]), "Forked Container Error! Matching batchIds but mismatched clientId")
      }
    }
    if try field(inbound, "length") == number(0), local {
      let metadata = try acknowledge(inbound.member("batchStart").member("keyMessage"), compare: false)
      try require(metadata?.member("emptyBatch") == .bool(true), "0xa20")
      return []
    }
    let messages = try inbound.member("type") == string("fullBatch") ? inbound.member("messages").asArray() : [inbound.member("nextMessage")]
    return try messages.map { message in
      object([("message", message), ("localOpMetadata", local ? try acknowledge(message, compare: true) : nil)])
    }
  }
  private func acknowledge(_ message: JSONValue, compare: Bool) throws -> JSONValue? {
    try require(pending.count > head, "0x169")
    var record = try pending[head].asObject()
    record["sequenceNumber"] = try message.member("sequenceNumber")
    saved.append(try serializable(.object(record)))
    head += 1
    if compare {
      let envelope = try object([("type", message.member("type")), ("contents", field(message, "contents"))])
      try require(record["content"] == string(JSON.stringify(envelope)), "pending local message content mismatch")
    }
    if head > 1024 && head * 2 > pending.count {
      pending.removeFirst(head)
      head = 0
    }
    return record["localOpMetadata"]
  }

  public func applyStashedOpsAt(_ sequenceNumber: Int? = nil, attached: Bool = true,
    applyStashedOp: (String) throws -> JSONValue?) throws {
    guard !initial.isEmpty else { return }
    while let next = initial.first {
      if let sequenceNumber {
        let reference = try next.member("referenceSequenceNumber").asInt()
        if reference > sequenceNumber { break }
        try require(reference == sequenceNumber, "loaded from snapshot too recent to apply stashed ops")
      }
      initial.removeFirst()
      var record = try next.asObject()
      let content = try next.member("content").asString().description
      let op = try JSON.parse(content)
      let empty = try op.member("type") == string("groupedBatch") && op.member("contents").asArray().isEmpty
      if empty {
        record["localOpMetadata"] = object([("emptyBatch", .bool(true))])
        record["runtimeOp"] = op
      } else {
        record["localOpMetadata"] = try applyStashedOp(content)
        if !attached {
          try require(record["localOpMetadata"] == nil, "Local Op Metadata must be undefined when not attached")
          continue
        }
        record["runtimeOp"] = op
      }
      if record["batchInfo"] == nil {
        record["batchInfo"] = object([
          ("clientId", string(generateUUID())), ("batchStartCsn", number(-1)),
          ("length", number(-1)), ("staged", .bool(false)),
        ])
      }
      pending.append(.object(record))
    }
    if initial.isEmpty && isApplyingStashedOps {
      isApplyingStashedOps = false
      onAfterStashedOpsApplied()
    }
  }

  public func replayPendingStates(clientId: String, connected: Bool = true,
    reSubmitBatch: ([LocalBatchMessage], JSString, Bool) throws -> Void) throws {
    try require(connected, "0x172")
    try require(lastReplayClientId != clientId, "0x173")
    lastReplayClientId = clientId
    try require(initial.isEmpty, "0x174")
    var remaining = pending.count - head
    while remaining > 0 {
      let first = pending[head]
      let id = try effectiveId(first)
      let staged = try first.member("batchInfo").member("staged") == .bool(true)
      var batch: [LocalBatchMessage] = []
      var record = first
      let flag = try field(first, "opMetadata").flatMap { try field($0, "batch") }
      try require(flag != .bool(false), "0x41b")
      while true {
        head += 1
        remaining -= 1
        let metadata = try field(record, "localOpMetadata")
        let empty: Bool
        if case .object(let fields) = metadata {
          empty = fields["emptyBatch"] == .bool(true)
        } else {
          empty = false
        }
        if !empty {
          batch.append(try LocalBatchMessage(
            runtimeOp: record.member("runtimeOp"),
            referenceSequenceNumber: record.member("referenceSequenceNumber").asInt(),
            metadata: field(record, "opMetadata"), localOpMetadata: metadata, staged: staged))
        }
        if try flag != .bool(true) || (field(record, "opMetadata").flatMap { try field($0, "batch") }) == .bool(false) { break }
        try require(remaining > 0, "0x555")
        record = pending[head]
        try require(field(record, "opMetadata").flatMap { try field($0, "batch") } != .bool(true), "0x556")
      }
      try reSubmitBatch(batch, id, staged)
    }
    saved.removeAll(keepingCapacity: true)
    pending.removeFirst(head)
    head = 0
  }
}
