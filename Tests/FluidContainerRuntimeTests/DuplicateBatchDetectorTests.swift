import Testing
import FluidJS
@testable import FluidContainerRuntime

struct DuplicateBatchDetectorTests {
  func batch(_ seq: Int, msn: Int = 0, client: String = "a", csn: Int = 7, id: String? = nil) -> JSONValue {
    object([
      ("clientId", string(client)), ("batchStartCsn", number(csn)),
      ("batchId", id.map(string)),
      ("keyMessage", object([("sequenceNumber", number(seq)), ("minimumSequenceNumber", number(msn))])),
    ])
  }

  @Test func emptyAndSnapshot() throws {
    let empty = try DuplicateBatchDetector()
    #expect(empty.getRecentBatchInfoForSummary() == nil)
    let snapshot = try JSON.parse(#"[[1,"one"],[2,"two"]]"#)
    let loaded = try DuplicateBatchDetector(batchIdsFromSnapshot: snapshot)
    #expect(loaded.getRecentBatchInfoForSummary() == snapshot)
    #expect(try loaded.processInboundBatch(batch(3, id: "one")) == JSON.parse(#"{"duplicate":true,"otherSequenceNumber":1}"#))
  }

  @Test func implicitAndExplicitIdentity() throws {
    let detector = try DuplicateBatchDetector()
    #expect(try detector.processInboundBatch(batch(1)) == JSON.parse(#"{"duplicate":false}"#))
    #expect(try detector.processInboundBatch(batch(2, client: "reconnected", csn: 1, id: "a_[7]")) == JSON.parse(#"{"duplicate":true,"otherSequenceNumber":1,"otherBatchInfo":{"clientId":"a","batchStartCsn":7,"batchIdExplicit":false}}"#))
    let reversed = try DuplicateBatchDetector()
    _ = try reversed.processInboundBatch(batch(1, client: "reconnected", csn: 1, id: "a_[7]"))
    #expect(try reversed.processInboundBatch(batch(2)) == JSON.parse(#"{"duplicate":true,"otherSequenceNumber":1,"otherBatchInfo":{"clientId":"reconnected","batchStartCsn":1,"batchIdExplicit":true}}"#))
  }

  @Test func minimumSequenceIsStrictAndDuplicatesDoNotReplaceOriginal() throws {
    let detector = try DuplicateBatchDetector()
    _ = try detector.processInboundBatch(batch(1))
    _ = try detector.processInboundBatch(batch(2, msn: 1))
    #expect(detector.getRecentBatchInfoForSummary() == (try JSON.parse(#"[[1,"a_[7]"]]"#)))
    #expect(try detector.processInboundBatch(batch(3, msn: 2)) == JSON.parse(#"{"duplicate":false}"#))
    #expect(detector.getRecentBatchInfoForSummary() == (try JSON.parse(#"[[3,"a_[7]"]]"#)))
  }

  @Test func telemetryWindows() throws {
    let detector = try DuplicateBatchDetector()
    _ = try detector.processInboundBatch(batch(1))
    _ = try detector.processInboundBatch(batch(2, csn: 8))
    var metrics: [String: Int] = [:]
    _ = detector.getRecentBatchInfoForSummary { metrics[$0] = $1 }
    #expect(metrics == ["recentBatchCount": 2, "peakRecentBatchCount": 2, "processedBatchCount": 2])
    _ = try detector.processInboundBatch(batch(3, msn: 3))
    _ = detector.getRecentBatchInfoForSummary { metrics[$0] = $1 }
    #expect(metrics == ["recentBatchCount": 1, "peakRecentBatchCount": 2, "processedBatchCount": 1])
  }

  @Test func duplicateSequenceAssertsAndSnapshotOrderIsNotSorted() throws {
    let detector = try DuplicateBatchDetector()
    _ = try detector.processInboundBatch(batch(1))
    #expect(throws: JSONDecodingError.self) {
      try detector.processInboundBatch(batch(1, csn: 8))
    }
    let snapshot = try JSON.parse(#"[[4,"four"],[1,"one"]]"#)
    let loaded = try DuplicateBatchDetector(batchIdsFromSnapshot: snapshot)
    _ = try loaded.processInboundBatch(batch(5, msn: 3))
    #expect(loaded.getRecentBatchInfoForSummary() == (try JSON.parse(#"[[4,"four"],[1,"one"],[5,"a_[7]"]]"#)))
  }
}
