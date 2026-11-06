import FluidContainerDefinitions
import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS

/// Ports container-loader/src/protocol/quorum.ts: QuorumClients.
public final class QuorumClients {
    public let events = ListenerList<QuorumEvent>()
    private var members: [QuorumMember]
    // The loader installs audience forwarding before public listeners. This throwing hook
    // preserves that ordering and propagates assert 0x4b2 without an async event hop.
    var memberAdded: ((JSString, ISequencedClient) throws -> Void)?

    public init(members: [QuorumMember]) { self.members = members }

    public func getMembers() -> [QuorumMember] { members }

    public func getMember(_ clientId: JSString) -> ISequencedClient? {
        members.first { $0.clientId == clientId }?.client
    }

    public func addMember(_ clientId: JSString, _ details: ISequencedClient) throws {
        guard getMember(clientId) == nil else {
            throw JSONDecodingError("0x9a1: duplicate quorum client")
        }
        members.append(try QuorumMember(json: .array([.string(clientId), details.json])))
        try memberAdded?(clientId, details)
        events.emit(.addMember(clientId, details))
    }

    public func removeMember(_ clientId: JSString) throws {
        guard getMember(clientId) != nil else {
            throw JSONDecodingError("0x9a3: absent quorum client")
        }
        members.removeAll { $0.clientId == clientId }
        events.emit(.removeMember(clientId))
    }
}

/// Ports container-loader/src/protocol/quorum.ts: QuorumProposals.
public final class QuorumProposals {
    public let events = ListenerList<QuorumEvent>()
    private var proposals: [QuorumProposal]
    private var values: [QuorumValue]

    public init(proposals: [QuorumProposal], values: [QuorumValue]) {
        self.proposals = proposals
        self.values = values
    }

    public func getProposals() -> [QuorumProposal] { proposals }
    public func getValues() -> [QuorumValue] { values }
    public func has(_ key: JSString) -> Bool { values.contains { $0.key == key } }
    public func get(_ key: JSString) -> JSONValue? {
        values.first { $0.key == key }?.proposal.value
    }

    public func addProposal(_ proposal: IProposal, sequenceNumber: Int) throws {
        guard !proposals.contains(where: { $0.sequenceNumber == sequenceNumber }) else {
            throw JSONDecodingError("0x9a4: duplicate proposal sequenceNumber")
        }
        var object = JSObject<JSONValue>()
        object["sequenceNumber"] = .number(Double(sequenceNumber))
        object["key"] = .string(proposal.key)
        object["value"] = proposal.value
        let sequenced = try ISequencedProposal(json: .object(object))
        proposals.append(
            try QuorumProposal(
                json: .array([
                    .number(Double(sequenceNumber)), sequenced.json, .array([]),
                ])))
        events.emit(.addProposal(sequenced))
    }

    /// quorum.ts approves in sequence order, publishes the value before emitting, then removes
    /// the pending proposal. Legacy commitSequenceNumber remains -1 for wire compatibility.
    public func updateMinimumSequenceNumber(_ message: ISequencedDocumentMessage) throws {
        let completed = proposals.filter { $0.sequenceNumber <= message.minimumSequenceNumber }
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        for entry in completed {
            let proposal = entry.proposal
            var object = JSObject<JSONValue>()
            object["approvalSequenceNumber"] = .number(Double(message.sequenceNumber))
            object["commitSequenceNumber"] = .number(-1)
            object["key"] = .string(proposal.key)
            object["sequenceNumber"] = .number(Double(proposal.sequenceNumber))
            object["value"] = proposal.value
            let committed = try ICommittedProposal(json: .object(object))
            let value = try QuorumValue(json: .array([.string(proposal.key), committed.json]))
            if let index = values.firstIndex(where: { $0.key == proposal.key }) {
                values[index] = value
            } else {
                values.append(value)
            }
            events.emit(.approveProposal(committed))
            proposals.removeAll { $0.sequenceNumber == entry.sequenceNumber }
        }
    }
}

/// Ports container-loader/src/protocol/quorum.ts: Quorum, forwarding child events inline.
public final class Quorum {
    public let clients: QuorumClients
    public let proposals: QuorumProposals
    public let events = ListenerList<QuorumEvent>()

    public init(members: [QuorumMember], proposals: [QuorumProposal], values: [QuorumValue]) {
        clients = QuorumClients(members: members)
        self.proposals = QuorumProposals(proposals: proposals, values: values)
        clients.events.on { [weak self] in self?.events.emit($0) }
        self.proposals.events.on { [weak self] in self?.events.emit($0) }
    }

    public func getMembers() -> [QuorumMember] { clients.getMembers() }
    public func getMember(_ clientId: JSString) -> ISequencedClient? { clients.getMember(clientId) }
    public func addMember(_ clientId: JSString, _ details: ISequencedClient) throws {
        try clients.addMember(clientId, details)
    }
    public func removeMember(_ clientId: JSString) throws { try clients.removeMember(clientId) }
    public func has(_ key: JSString) -> Bool { proposals.has(key) }
    public func get(_ key: JSString) -> JSONValue? { proposals.get(key) }
    public func addProposal(_ proposal: IProposal, sequenceNumber: Int) throws {
        try proposals.addProposal(proposal, sequenceNumber: sequenceNumber)
    }
    public func updateMinimumSequenceNumber(_ message: ISequencedDocumentMessage) throws {
        try proposals.updateMinimumSequenceNumber(message)
    }

}

/// `QuorumClients` as the `IQuorumClients` that `ContainerRuntime.getQuorum()` hands to datastores.
public final class QuorumClientsView: IQuorumClients {
    private let clients: QuorumClients

    public init(_ clients: QuorumClients) { self.clients = clients }

    public func getMembers() -> JSMap<JSString, JSONValue> {
        var members = JSMap<JSString, JSONValue>()
        for member in clients.getMembers() { members.set(member.clientId, member.client.json) }
        return members
    }

    public func getMember(_ clientId: JSString) -> JSONValue? { clients.getMember(clientId)?.json }

    @discardableResult
    public func onAddMember(_ listener: @escaping (JSString, JSONValue) -> Void) -> Int {
        clients.events.on { event in
            if case .addMember(let clientId, let client) = event { listener(clientId, client.json) }
        }
    }

    @discardableResult
    public func onRemoveMember(_ listener: @escaping (JSString) -> Void) -> Int {
        clients.events.on { event in
            if case .removeMember(let clientId) = event { listener(clientId) }
        }
    }

    public func off(_ token: Int) { clients.events.off(token) }
}
