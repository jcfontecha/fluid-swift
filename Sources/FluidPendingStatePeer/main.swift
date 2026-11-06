import FluidContainerRuntime
import FluidJS
import Foundation

while let line = readLine() {
  do {
    let scenario = try JSON.parse(line)
    if try scenario.asObject()["runtime"] == .bool(true) {
      let result = try runRuntime(scenario)
      FileHandle.standardOutput.write(Data((JSON.stringify(result) + "\n").utf8))
      continue
    }
    var detector = try DuplicateBatchDetector(batchIdsFromSnapshot: scenario.member("snapshot"))
    var results: [JSONValue] = []
    for command in try scenario.member("commands").asArray() {
      let kind = try command.member("kind").asString()
      if kind == "process" {
        var batch = try command.member("batch").asObject()
        var key = JSObject<JSONValue>()
        key["sequenceNumber"] = batch["sequenceNumber"]
        key["minimumSequenceNumber"] = batch["minimumSequenceNumber"]
        batch["keyMessage"] = .object(key)
        results.append(try detector.processInboundBatch(.object(batch)))
      } else {
        guard kind == "summary" || kind == "reload" else {
          throw JSONDecodingError("unknown command")
        }
        let summary = detector.getRecentBatchInfoForSummary()
        results.append(summary ?? .null)
        if kind == "reload" {
          detector = try DuplicateBatchDetector(batchIdsFromSnapshot: summary)
        }
      }
    }
    FileHandle.standardOutput.write(Data((JSON.stringify(.array(results)) + "\n").utf8))
  } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
  }
}
