import FluidContainerRuntime
import FluidDriverDefinitions
import FluidJS

/// Harness-only deterministic clock and quorum adapter; production algorithms are unchanged.
func summaryTrace(_ params: JSONValue) throws -> JSONValue {
    let election = try SummarizerClientElection(members: [], sequenceNumber: 0)
    let data = SummarizeHeuristicData(lastOpSequenceNumber: 0, summaryTime: 0)
    let runner = SummarizeHeuristicRunner(data: data)
    var result: [JSONValue] = []
    for step in try params.member("steps").asArray() {
        let sequence = try step.member("sequence").asInt()
        let now = try step.member("now").asNumber()
        let type = try step.member("type").asString()
        switch type {
        case "join":
            let member = try QuorumMember(json: step.member("member"))
            election.addMember(member, sequenceNumber: sequence)
        case "leave": election.removeMember(try step.member("id").asString(), sequenceNumber: sequence)
        case "attempt": data.recordAttempt(now: now)
        case "ack": data.markLastAttemptAsSuccessful()
        default: break
        }
        election.process(type: type == "ack" ? "summaryAck" : type, sequenceNumber: sequence)
        if type == "op" { data.numRuntimeOps += 1 }
        if type == "noop" { data.numNonRuntimeOps += 1 }
        data.lastOpSequenceNumber = sequence
        var row = JSObject<JSONValue>()
        row["election"] = election.serialize()
        row["reason"] = runner.run(now: now).map { .string(JSString($0)) } ?? .null
        row["idleTime"] = .number(runner.idleTime)
        row["runtimeOps"] = .number(Double(data.numRuntimeOps))
        row["nonRuntimeOps"] = .number(Double(data.numNonRuntimeOps))
        row["lastSummary"] = .number(Double(data.lastSuccessfulSummary.refSequenceNumber))
        result.append(.object(row))
    }
    return .array(result)
}
