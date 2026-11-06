import FluidJS

/// Ports opLifecycle/duplicateBatchDetector.ts: parallel-fork detection within the MSN window.
public final class DuplicateBatchDetector {
  private struct RecordedBatch {
    let batchId: JSString
    let info: JSONValue?
  }
  private var seqNumByBatchId: [JSString: Int] = [:]
  private var batchesBySeqNum: [Int: RecordedBatch] = [:]
  // JS Map order is insertion order, even for out-of-order snapshot entries.
  private var order: [Int] = []
  private var head = 0
  private var processedBatchCount = 0
  private var peakTrackedBatchCount = 0

  public init(batchIdsFromSnapshot: JSONValue? = nil) throws {
    if let batchIdsFromSnapshot {
      for entry in try batchIdsFromSnapshot.asArray() {
        let pair = try entry.asArray()
        try require(pair.count == 2, "invalid recent batch entry")
        let sequence = try pair[0].asInt()
        let id = try pair[1].asString()
        if batchesBySeqNum[sequence] == nil {
          order.append(sequence)
        }
        batchesBySeqNum[sequence] = RecordedBatch(batchId: id, info: nil)
        seqNumByBatchId[id] = sequence
      }
      peakTrackedBatchCount = batchesBySeqNum.count
    }
  }

  public func processInboundBatch(_ batchStart: JSONValue) throws -> JSONValue {
    let sequence = try batchStart.member("keyMessage").member("sequenceNumber").asInt()
    let minimum = try batchStart.member("keyMessage").member("minimumSequenceNumber").asInt()
    let client = try batchStart.member("clientId").asString()
    let csn = try batchStart.member("batchStartCsn").asInt()
    let explicitId = try field(batchStart, "batchId")?.asString()
    var derivedUnits = client.utf16
    derivedUnits.append(contentsOf: JSString("_[\(csn)]").utf16)
    let id = explicitId ?? JSString(utf16: derivedUnits)
    processedBatchCount += 1
    clearOldBatchIds(minimum)
    if let otherSequence = seqNumByBatchId[id] {
      guard let other = batchesBySeqNum[otherSequence], other.batchId == id else {
        throw JSONDecodingError("0xce0: duplicate indexes out of sync")
      }
      return object([
        ("duplicate", .bool(true)), ("otherSequenceNumber", number(otherSequence)),
        ("otherBatchInfo", other.info),
      ])
    }
    try require(batchesBySeqNum[sequence] == nil, "0xce1: duplicate sequence number")
    let info = object([
      ("clientId", .string(client)), ("batchStartCsn", number(csn)),
      ("batchIdExplicit", .bool(explicitId != nil)),
    ])
    batchesBySeqNum[sequence] = RecordedBatch(batchId: id, info: info)
    seqNumByBatchId[id] = sequence
    order.append(sequence)
    peakTrackedBatchCount = max(peakTrackedBatchCount, batchesBySeqNum.count)
    return object([("duplicate", .bool(false))])
  }

  private func clearOldBatchIds(_ minimum: Int) {
    while head < order.count && order[head] < minimum {
      let sequence = order[head]
      if let removed = batchesBySeqNum.removeValue(forKey: sequence) {
        seqNumByBatchId.removeValue(forKey: removed.batchId)
      }
      head += 1
    }
    // Amortized compaction, not an array shift on each sequenced batch.
    if head > 1024 && head * 2 > order.count {
      order.removeFirst(head)
      head = 0
    }
  }

  public func getRecentBatchInfoForSummary(
    telemetry: ((String, Int) -> Void)? = nil
  ) -> JSONValue? {
    telemetry?("recentBatchCount", batchesBySeqNum.count)
    telemetry?("peakRecentBatchCount", peakTrackedBatchCount)
    telemetry?("processedBatchCount", processedBatchCount)
    processedBatchCount = 0
    peakTrackedBatchCount = batchesBySeqNum.count
    guard !batchesBySeqNum.isEmpty else {
      return nil
    }
    return .array(order[head...].compactMap { sequence in
      guard let recorded = batchesBySeqNum[sequence] else {
        return nil
      }
      return .array([number(sequence), .string(recorded.batchId)])
    })
  }
}
