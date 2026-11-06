import FluidContainerDefinitions
import FluidDriverDefinitions
import FluidJS

/// Ports container-loader/src/protocol/protocol.ts (ProtocolOpHandler) and the loader's
/// protocol.ts audience wiring. All mutations and listeners are synchronous on Container.
public final class ProtocolOpHandler {
    public private(set) var sequenceNumber: Int
    public private(set) var minimumSequenceNumber: Int
    public let quorum: Quorum
    public let audience: Audience

    public init(state: IProtocolState, audience: Audience = Audience()) throws {
        self.audience = audience
        sequenceNumber = state.sequenceNumber
        minimumSequenceNumber = state.minimumSequenceNumber
        quorum = Quorum(members: state.members, proposals: state.proposals, values: state.values)
        for member in quorum.getMembers() {
            try audience.addMember(member.clientId, member.client.client)
        }
        quorum.clients.memberAdded = { [weak self] id, details in
            try self?.audience.addMember(id, details.client)
        }
        quorum.events.on { [weak self] event in
            if case .removeMember(let id) = event { self?.audience.removeMember(id) }
        }
    }

    public func initialClients(_ clients: [ISignalClient]) throws {
        audience.clearReadClients()
        for entry in clients where entry.client.mode == .read {
            try audience.addMember(entry.clientId, entry.client)
        }
    }

    public func processSignal(_ signal: ISignalMessage) throws {
        guard signal.clientId == nil, var content = signal.content else { return }
        if case .string(let text) = content { content = try JSON.parse(text.description) }
        switch try content.member("type").asString() {
        case "clear": audience.clearReadClients()
        case "join":
            let entry = try ISignalClient(json: content.member("content"))
            if entry.client.mode == .read { try audience.addMember(entry.clientId, entry.client) }
        case "leave":
            let id = try content.member("content").asString()
            if audience.getMember(id)?.mode == .read { audience.removeMember(id) }
        default: break
        }
    }

    public func processMessage(_ message: ISequencedDocumentMessage) throws -> IProcessMessageResult
    {
        guard message.sequenceNumber == sequenceNumber + 1 else {
            throw JSONDecodingError("Protocol state is not moving sequentially")
        }
        sequenceNumber = message.sequenceNumber
        minimumSequenceNumber = message.minimumSequenceNumber
        switch message.type {
        case "join":
            let join = try IClientJoin(json: systemData(message))
            var object = JSObject<JSONValue>()
            object["client"] = join.detail.json
            object["sequenceNumber"] = .number(Double(sequenceNumber))
            try quorum.addMember(join.clientId, ISequencedClient(json: .object(object)))
        case "leave":
            try quorum.removeMember(systemData(message).asString())
        case "propose":
            guard var contents = message.contents else {
                throw JSONDecodingError("missing proposal contents")
            }
            if case .string(let text) = contents { contents = try JSON.parse(text.description) }
            try quorum.addProposal(
                IProposal(json: contents), sequenceNumber: sequenceNumber)
        default: break
        }
        try quorum.updateMinimumSequenceNumber(message)
        var result = JSObject<JSONValue>()
        result["immediateNoOp"] = .bool(message.type == "propose")
        return try IProcessMessageResult(json: .object(result))
    }

    public var view: JSONValue {
        var result = JSObject<JSONValue>()
        result["sequenceNumber"] = .number(Double(sequenceNumber))
        result["minimumSequenceNumber"] = .number(Double(minimumSequenceNumber))
        result["members"] = .array(quorum.getMembers().map(\.json))
        result["proposals"] = .array(quorum.proposals.getProposals().map(\.json))
        result["values"] = .array(quorum.proposals.getValues().map(\.json))
        result["audience"] = .array(
            audience.getMembers().entries.map { .array([.string($0.key), $0.value.json]) })
        return .object(result)
    }
}

func systemData(_ message: ISequencedDocumentMessage) throws -> JSONValue {
    guard let data = message.data else { throw JSONDecodingError("missing system message data") }
    return try JSON.parse(data.description)
}
