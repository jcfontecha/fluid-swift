import FluidDriverDefinitions
import FluidJS

/// Ports summary/summarizerClientElection.ts. Quorum mutations are delivered synchronously
/// after membership changes, using the sequence number of the triggering protocol message.
public final class SummarizerClientElection {
    private var members: [QuorumMember]
    public private(set) var electedClientId: JSString?
    public private(set) var electedParentId: JSString?
    private var parentSequence: Int?
    private var electionSequenceNumber: Int
    private var lastAck: Int?

    public init(members: [QuorumMember], sequenceNumber: Int, initialState: JSONValue? = nil) throws {
        self.members = members
        electionSequenceNumber = sequenceNumber
        if let initialState {
            electionSequenceNumber = try initialState.member("electionSequenceNumber").asInt()
            let state = try initialState.asObject()
            if let parent = try state["electedParentId"]?.asString(), let member = member(parent), eligible(member) {
                setParent(parent)
            }
            if let id = try state["electedClientId"]?.asString(), let client = member(id) {
                if eligible(client) {
                    electedClientId = id
                    if electedParentId == nil && !summarizer(client) { setParent(id) }
                } else {
                    let next = nextParent(after: client.sequenceNumber)
                    setParent(next)
                    electedClientId = next
                }
            }
        } else {
            setParent(nextParent(after: -1))
            electedClientId = members.filter { summarizer($0.client) }
                .min { $0.client.sequenceNumber < $1.client.sequenceNumber }?.clientId ?? electedParentId
        }
    }
    private func member(_ id: JSString) -> ISequencedClient? { members.first { $0.clientId == id }?.client }
    private func summarizer(_ member: ISequencedClient) -> Bool { member.client.details.type == "summarizer" }
    private func eligible(_ member: ISequencedClient) -> Bool {
        member.client.details.capabilities.interactive || summarizer(member)
    }
    private func nextParent(after sequence: Int) -> JSString? {
        members.filter { eligible($0.client) && !summarizer($0.client) && $0.client.sequenceNumber > sequence }
            .min { $0.client.sequenceNumber < $1.client.sequenceNumber }?.clientId
    }
    private func setParent(_ id: JSString?) {
        electedParentId = id
        parentSequence = id.flatMap { member($0)?.sequenceNumber }
    }
    private func update(client: JSString?, parent: JSString?, sequence: Int) {
        guard client != electedClientId || parent != electedParentId else { return }
        if client != electedClientId {
            electionSequenceNumber = sequence
            lastAck = nil
        }
        electedClientId = client
        setParent(parent)
        if client == nil { resetElectedClient(sequenceNumber: sequence) }
    }
    public func resetElectedClient(sequenceNumber: Int) {
        let parent = nextParent(after: -1)
        update(client: electedClientId == nil || electedClientId == electedParentId ? parent : electedClientId,
               parent: parent, sequence: sequenceNumber)
    }
    public func addMember(_ entry: QuorumMember, sequenceNumber: Int) {
        members.append(entry)
        guard eligible(entry.client) else { return }
        let isSummarizer = summarizer(entry.client)
        let incumbentIsSummarizer = electedClientId.flatMap { member($0) }.map(summarizer) ?? false
        if electedClientId == nil || (isSummarizer && !incumbentIsSummarizer) {
            update(client: entry.clientId, parent: isSummarizer ? electedParentId : entry.clientId, sequence: sequenceNumber)
        } else if electedParentId == nil && !isSummarizer {
            update(client: electedClientId, parent: entry.clientId, sequence: sequenceNumber)
        }
    }
    public func removeMember(_ id: JSString, sequenceNumber: Int) {
        members.removeAll { $0.clientId == id }
        let next = nextParent(after: parentSequence ?? -1) ?? nextParent(after: -1)
        if id == electedClientId {
            let parent = id == electedParentId ? next : electedParentId
            update(client: parent, parent: parent, sequence: sequenceNumber)
        } else if id == electedParentId {
            update(client: electedClientId, parent: next, sequence: sequenceNumber)
        }
    }
    public func process(type: JSString, sequenceNumber: Int) {
        if type == "summaryAck" { lastAck = sequenceNumber }
        else if type != "summarize" && type != "summaryNack" && electedClientId == nil {
            resetElectedClient(sequenceNumber: sequenceNumber)
        }
    }
    public func serialize() -> JSONValue {
        var fields = JSObject<JSONValue>()
        fields["electionSequenceNumber"] = .number(Double(lastAck ?? electionSequenceNumber))
        fields["electedClientId"] = electedClientId.map(JSONValue.string)
        fields["electedParentId"] = electedParentId.map(JSONValue.string)
        return .object(fields)
    }
}
