import FluidJS

/// Synchronous state owned by ServiceContainer's executor. Runtime payloads are never interpreted.
public struct ProtocolHandler: Sendable {
    public private(set) var sequenceNumber: Int
    public private(set) var minimumSequenceNumber: Int
    private var members: [(JSONValue, JSONValue)]
    private var proposals: [JSONValue]
    private var values: [(JSONValue, JSONValue)]
    private var audience: [(JSONValue, JSONValue)]
    private var clientSequences: [JSString: Int] = [:]

    public init(snapshot: JSONValue) throws {
        sequenceNumber = try snapshot.member("attributes").member("sequenceNumber").asInt()
        minimumSequenceNumber = try snapshot.member("attributes").member("minimumSequenceNumber").asInt()
        members = try Self.pairs(snapshot.member("quorumMembers"))
        proposals = try snapshot.member("quorumProposals").asArray()
        values = try Self.pairs(snapshot.member("quorumValues"))
        audience = try members.map { ($0.0, try $0.1.member("client")) }
    }
    private static func pairs(_ value: JSONValue) throws -> [(JSONValue, JSONValue)] {
        try value.asArray().map { value in
            let pair = try value.asArray()
            guard pair.count == 2 else { throw JSONDecodingError("invalid map entry") }
            return (pair[0], pair[1])
        }
    }
    private mutating func addAudience(_ id: JSONValue, _ client: JSONValue) throws {
        if let old = audience.first(where: { $0.0 == id }) {
            guard JSON.stringify(old.1) == JSON.stringify(client) else { throw JSONDecodingError("0x4b2: audience payload changed") }
        } else { audience.append((id, client)) }
    }
    public mutating func clearReadClients() throws {
        audience = try audience.filter { try $0.1.member("mode") != .string("read") }
    }
    public mutating func initialClients(_ clients: [JSONValue]) throws {
        try clearReadClients()
        for entry in clients {
            let client = try entry.member("client")
            if try client.member("mode") == .string("read") { try addAudience(entry.member("clientId"), client) }
        }
    }
    public mutating func signal(_ signal: JSONValue) throws {
        guard try signal.member("clientId") == .null else { return }
        var content = try signal.member("content")
        if case .string(let text) = content { content = try JSON.parse(text.description) }
        switch try content.member("type").asString() {
        case "clear": try clearReadClients()
        case "join":
            let entry = try content.member("content"), client = try entry.member("client")
            if try client.member("mode") == .string("read") { try addAudience(entry.member("clientId"), client) }
        case "leave":
            let id = try content.member("content")
            if let old = audience.first(where: { $0.0 == id }), try old.1.member("mode") == .string("read") { audience.removeAll { $0.0 == id } }
        default: break
        }
    }
    /// Returns true when Container must submit an immediate accept message.
    public mutating func process(_ message: JSONValue) throws -> Bool {
        let sn = try message.member("sequenceNumber").asInt(), msn = try message.member("minimumSequenceNumber").asInt()
        let sender = try message.member("clientId"), type = try message.member("type").asString()
        guard sn == sequenceNumber + 1 else { throw JSONDecodingError("Found a non-Sequential sequenceNumber") }
        guard msn >= minimumSequenceNumber else { throw JSONDecodingError("Invalid MinimumSequenceNumber from service - document may have been restored to previous state") }
        guard msn < sn || (msn == sn && sender == .null) else { throw JSONDecodingError("MSN has to be lower than sequence #") }
        if sender == .null, ["op", "propose", "reject", "accept", "summarize"].contains(type) { throw JSONDecodingError("Mismatch in clientId") }
        if sender != .null {
            let id = try sender.asString(), csn = try message.member("clientSequenceNumber").asInt()
            if let previous = clientSequences[id], csn <= previous { throw JSONDecodingError("DeltaManager.validateClientSequenceNumberConsistency") }
            clientSequences[id] = csn
            guard type == "join" || members.contains(where: { $0.0 == sender }) else { throw JSONDecodingError("Remote message's clientId is missing from the quorum") }
        }
        sequenceNumber = sn; minimumSequenceNumber = msn
        switch type {
        case "join":
            let join = try JSON.parse(message.member("data").asString().description), id = try join.member("clientId"), client = try join.member("detail")
            guard !members.contains(where: { $0.0 == id }) else { throw JSONDecodingError("0x9a1: duplicate quorum client") }
            var sequenced = JSObject<JSONValue>(); sequenced["client"] = client; sequenced["sequenceNumber"] = .number(Double(sn))
            members.append((id, .object(sequenced))); try addAudience(id, client)
        case "leave":
            let id = try JSON.parse(message.member("data").asString().description)
            guard members.contains(where: { $0.0 == id }) else { throw JSONDecodingError("0x9a3: absent quorum client") }
            members.removeAll { $0.0 == id }; audience.removeAll { $0.0 == id }; clientSequences[try id.asString()] = nil
        case "propose":
            var contents = try message.member("contents")
            if case .string(let text) = contents { contents = try JSON.parse(text.description) }
            var proposal = JSObject<JSONValue>(); proposal["sequenceNumber"] = .number(Double(sn)); proposal["key"] = try contents.member("key"); proposal["value"] = try contents.member("value")
            proposals.append(.array([.number(Double(sn)), .object(proposal), .array([])]))
        default: break
        }
        var remaining: [JSONValue] = []
        for entry in proposals {
            let tuple = try entry.asArray()
            guard tuple.count == 3 else { throw JSONDecodingError("invalid proposal") }
            let number = try tuple[0].asInt(), proposal = tuple[1]
            if number <= msn {
                var committed = JSObject<JSONValue>()
                committed["approvalSequenceNumber"] = .number(Double(sn)); committed["commitSequenceNumber"] = .number(-1)
                committed["key"] = try proposal.member("key"); committed["sequenceNumber"] = .number(Double(number)); committed["value"] = try proposal.member("value")
                let key = try proposal.member("key")
                if let index = values.firstIndex(where: { $0.0 == key }) { values[index].1 = .object(committed) } else { values.append((key, .object(committed))) }
            } else { remaining.append(entry) }
        }
        proposals = remaining
        return type == "propose"
    }
    public var view: JSONValue {
        var result = JSObject<JSONValue>()
        result["sequenceNumber"] = .number(Double(sequenceNumber)); result["minimumSequenceNumber"] = .number(Double(minimumSequenceNumber))
        result["members"] = .array(members.map { .array([$0.0, $0.1]) }); result["proposals"] = .array(proposals)
        result["values"] = .array(values.map { .array([$0.0, $0.1]) }); result["audience"] = .array(audience.map { .array([$0.0, $0.1]) })
        return .object(result)
    }
}
