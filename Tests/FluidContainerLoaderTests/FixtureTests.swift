import FluidContainerDefinitions
import FluidDatastoreDefinitions
import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Foundation
import Testing

@testable import FluidContainerLoader

private func capturedMessages() throws -> [ISequencedDocumentMessage] {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(
            "FluidDriverDefinitionsTests/Fixtures/session.json")
    let fixtures = try JSON.parse(String(contentsOf: path, encoding: .utf8)).asArray()
    var seen = Set<Int>()
    var messages: [ISequencedDocumentMessage] = []
    for fixture in fixtures
    where try fixture.member("type").asString() == "ISequencedDocumentMessage" {
        let message = try ISequencedDocumentMessage(
            json: JSON.parse(fixture.member("text").asString().description))
        if seen.insert(message.sequenceNumber).inserted { messages.append(message) }
    }
    return messages.sorted { $0.sequenceNumber < $1.sequenceNumber }
}

private func emptyProtocol(sequenceNumber: Int = 0, msn: Int = 0) throws -> ProtocolOpHandler {
    var state = JSObject<JSONValue>()
    state["sequenceNumber"] = .number(Double(sequenceNumber))
    state["minimumSequenceNumber"] = .number(Double(msn))
    for key: JSString in ["members", "proposals", "values"] { state[key] = .array([]) }
    return try ProtocolOpHandler(state: IProtocolState(json: .object(state)))
}

private func replacing(_ message: ISequencedDocumentMessage, _ key: JSString, _ value: JSONValue)
    throws -> ISequencedDocumentMessage
{
    var object = try message.json.asObject()
    object[key] = value
    return try ISequencedDocumentMessage(json: .object(object))
}

@Test func capturedProposalLifecyclePublishesBeforeApprovalAndRemovesAfterEvent() throws {
    let messages = try capturedMessages()
    let handler = try emptyProtocol()
    let delta = DeltaManager(active: { true })
    var order: [String] = []
    handler.quorum.events.on { event in
        switch event {
        case .addMember: order.append("quorum.addMember")
        case .removeMember: order.append("quorum.removeMember")
        case .addProposal(let proposal):
            #expect(
                handler.quorum.proposals.getProposals().contains {
                    $0.sequenceNumber == proposal.sequenceNumber
                })
            order.append("addProposal")
        case .approveProposal(let proposal):
            #expect(handler.quorum.proposals.get(proposal.key) == proposal.value)
            #expect(
                handler.quorum.proposals.getProposals().contains {
                    $0.sequenceNumber == proposal.sequenceNumber
                })
            #expect(proposal.commitSequenceNumber == -1)
            order.append("approveProposal")
        }
    }
    handler.audience.events.on { event in
        switch event {
        case .addMember: order.append("audience.addMember")
        case .removeMember: order.append("audience.removeMember")
        case .selfChanged: order.append("audience.selfChanged")
        }
    }
    delta.events.on { event in
        if case .op = event { order.append("op") }
    }
    for message in messages {
        try delta.validate(message, protocolHandler: handler, clientId: nil)
        _ = try handler.processMessage(message)
        delta.enqueueMessages([message])
        let entry = try #require(try delta.nextMessage(sequenceNumber: message.sequenceNumber - 1))
        delta.recordProcessed(entry)
    }
    #expect(order.contains("addProposal"))
    #expect(order.contains("approveProposal"))
    #expect(handler.quorum.proposals.getProposals().isEmpty)
    #expect(order.prefix(3) == ["audience.addMember", "quorum.addMember", "op"])
    #expect(delta.log.map(\.json) == messages.map(\.json))
}

@Test func approvalSortsRestoredProposalsAndOverwritesValuesWithoutReorderingKeys() throws {
    let message = try #require(capturedMessages().first { $0.minimumSequenceNumber >= 4 })
    let proposalMessage = try #require(capturedMessages().first { $0.type == "propose" })
    let contents = try #require(proposalMessage.contents)
    let proposal = try IProposal(json: JSON.parse(contents.asString().description))
    let quorum = QuorumProposals(proposals: [], values: [])
    var approvals: [Int] = []
    quorum.events.on { if case .approveProposal(let p) = $0 { approvals.append(p.sequenceNumber) } }
    try quorum.addProposal(proposal, sequenceNumber: 3)
    try quorum.addProposal(proposal, sequenceNumber: 2)
    #expect(throws: JSONDecodingError.self) { try quorum.addProposal(proposal, sequenceNumber: 2) }
    try quorum.updateMinimumSequenceNumber(message)
    #expect(approvals == [2, 3])
    #expect(quorum.getValues().count == 1)
    #expect(quorum.getValues().first?.proposal.sequenceNumber == 3)
    #expect(quorum.getProposals().isEmpty)
}

@Test(arguments: [
    "sequence", "msnBackwards", "msnTooHigh", "nullClient", "missingMember", "ownGap",
    "clientSequence",
])
func deltaValidationRejectsCorruptedCaptures(_ corruption: String) throws {
    let messages = try capturedMessages()
    let original = try #require(messages.first { $0.type == "op" })
    let handler = try emptyProtocol()
    let delta = DeltaManager(active: { true })
    for message in messages where message.sequenceNumber < original.sequenceNumber {
        try delta.validate(message, protocolHandler: handler, clientId: nil)
        _ = try handler.processMessage(message)
    }
    var invalid = original
    var target = handler
    var clientId: JSString?
    let expected: String
    switch corruption {
    case "sequence":
        invalid = try replacing(original, "sequenceNumber", .number(100))
        expected = "Found a non-Sequential sequenceNumber"
    case "msnBackwards":
        target = try emptyProtocol(sequenceNumber: original.sequenceNumber - 1, msn: 1)
        invalid = try replacing(original, "clientId", .null)
        invalid = try replacing(invalid, "type", .string("noop"))
        expected =
            "Invalid MinimumSequenceNumber from service - document may have been restored to previous state"
    case "msnTooHigh":
        invalid = try replacing(
            original, "minimumSequenceNumber", .number(Double(original.sequenceNumber)))
        expected = "MSN has to be lower than sequence #"
    case "nullClient":
        invalid = try replacing(original, "clientId", .null)
        expected = "Mismatch in clientId"
    case "missingMember":
        invalid = try replacing(original, "clientId", .string("absent-client"))
        expected = "Remote message's clientId is missing from the quorum"
    case "ownGap":
        clientId = original.clientId
        invalid = try replacing(original, "clientSequenceNumber", .number(3))
        expected = "gap in client sequence number: 2"
    default:
        try delta.validate(original, protocolHandler: handler, clientId: nil)
        expected = "DeltaManager.validateClientSequenceNumberConsistency"
    }
    #expect(throws: JSONDecodingError.self) {
        do { try delta.validate(invalid, protocolHandler: target, clientId: clientId) } catch {
            #expect(String(describing: error) == expected)
            throw error
        }
    }
}

@Test func duplicateFingerprintIgnoresContentsButRejectsChangedTimestamp() throws {
    let message = try #require(capturedMessages().first)
    let delta = DeltaManager(active: { true })
    delta.enqueueMessages([message])
    let entry = try #require(try delta.nextMessage(sequenceNumber: 0))
    delta.recordProcessed(entry)
    delta.enqueueMessages([try replacing(message, "contents", .string("different transport"))])
    #expect(try delta.nextMessage(sequenceNumber: 1) == nil)
    delta.enqueueMessages([try replacing(message, "timestamp", .number(message.timestamp + 1))])
    #expect(throws: DriverError.self) { _ = try delta.nextMessage(sequenceNumber: 1) }
}

@Test func noopHeuristicCoalescesAtDrainAndDoesNotAcknowledgeSystemMessages() throws {
    let messages = try capturedMessages()
    let op = try #require(messages.first { $0.type == "op" })
    let join = try #require(messages.first { $0.type == "join" })
    var heuristic = NoopHeuristic()
    heuristic.noopCountFrequency = 2
    heuristic.notifyMessageProcessed(join)
    #expect(heuristic.opsProcessedSinceOpSent == 0)
    heuristic.notifyMessageProcessed(op)
    let wantsNoop1 = heuristic.takeWantsNoop()
    #expect(!wantsNoop1)
    heuristic.notifyMessageProcessed(op)
    heuristic.notifyMessageProcessed(op)
    let wantsNoop2 = heuristic.takeWantsNoop()
    #expect(wantsNoop2)
    heuristic.notifyMessageSent()
    #expect(heuristic.opsProcessedSinceOpSent == 0)
    heuristic.notifyMessageProcessed(op)
    heuristic.notifyMessageProcessed(op)
    heuristic.notifyMessageSent()
    let wantsNoop3 = heuristic.takeWantsNoop()
    #expect(!wantsNoop3)
    heuristic.notifyDisconnect()
    heuristic.noopCountFrequency = 0
    heuristic.notifyMessageProcessed(op)
    let wantsNoop4 = heuristic.takeWantsNoop()
    #expect(!wantsNoop4)
}

@Test func quorumClientsViewReportsMembersAndEventsToDatastores() throws {
    let handler = try emptyProtocol()
    let view = QuorumClientsView(handler.quorum.clients)
    var added: [JSString] = []
    var removed: [JSString] = []
    let token = view.onAddMember { clientId, _ in added.append(clientId) }
    view.onRemoveMember { clientId in removed.append(clientId) }
    let delta = DeltaManager(active: { true })
    for message in try capturedMessages() {
        try delta.validate(message, protocolHandler: handler, clientId: nil)
        _ = try handler.processMessage(message)
    }
    #expect(!added.isEmpty)
    let members = handler.quorum.getMembers()
    #expect(Array(view.getMembers().keys).count == members.count)
    for member in members { #expect(view.getMember(member.clientId) == member.client.json) }
    view.off(token)
    #expect(removed.count == (try capturedMessages().filter { $0.type == "leave" }.count))
}

@Test func deltaManagerReportsActiveFromItsConnection() {
    var connected = false
    let delta = DeltaManager(active: { connected })
    #expect(!delta.active)
    connected = true
    #expect(delta.active)
    #expect(delta.readOnlyInfo == ReadOnlyInfo(readonly: false))
}
