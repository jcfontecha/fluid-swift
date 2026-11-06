import FluidContainerDefinitions
import FluidDatastore
import FluidDriverDefinitions
import FluidJS
import Testing

@testable import FluidStatic

private struct TestMember: IMember {
    let userId: String
    var connections: [IConnection]
}

private func client(user: String, mode: String = "write", interactive: Bool = true) throws -> IClient {
    try IClient(json: JSON.parse("""
        {"mode":"\(mode)","details":{"capabilities":{"interactive":\(interactive)}},"permission":[],"scopes":[],\
        "user":{"id":"\(user)"}}
        """))
}

private func member(_ client: IClient) -> TestMember {
    TestMember(userId: client.user.id.description, connections: [])
}

private func names(_ event: ServiceAudienceEvent<TestMember>) -> String {
    switch event {
    case .membersChanged: "membersChanged"
    case .memberAdded(let clientId, let member): "memberAdded(\(clientId),\(member.userId))"
    case .memberRemoved(let clientId, let member): "memberRemoved(\(clientId),\(member.userId))"
    }
}

@Suite struct ServiceAudienceTests {
    /// serviceAudience.ts `getMembers`: interactive clients only, one member per user in audience
    /// order, each with all of that user's connections.
    @Test func groupsInteractiveConnectionsByUser() throws {
        let container = FakeContainer()
        try container.loaderAudience.addMember("c1", client(user: "ada"))
        try container.loaderAudience.addMember("c2", client(user: "summarizer", interactive: false))
        try container.loaderAudience.addMember("c3", client(user: "bob", mode: "read"))
        try container.loaderAudience.addMember("c4", client(user: "ada", mode: "read"))
        let audience = try createServiceAudience(container: container, createServiceMember: member)
        let members = try audience.getMembers()
        #expect(members.keys == ["ada", "bob"])
        #expect(members.get("ada")?.connections.map(\.id) == ["c1", "c4"])
        #expect(members.get("ada")?.connections.map(\.mode) == [.write, .read])
        #expect(members.get("bob")?.connections.map(\.id) == ["c3"])
    }

    /// serviceAudience.ts addMember handler: a human client adds a member (with every connection
    /// of that user), then members change; a non-interactive client emits nothing.
    @Test func addingAHumanClientEmitsMemberAddedThenMembersChanged() throws {
        let container = FakeContainer()
        try container.loaderAudience.addMember("c1", client(user: "ada"))
        let audience = try createServiceAudience(container: container, createServiceMember: member)
        var received: [String] = []
        audience.events.on { received.append(names($0)) }
        try container.loaderAudience.addMember("c2", client(user: "summarizer", interactive: false))
        try container.loaderAudience.addMember("c3", client(user: "ada"))
        #expect(received == ["memberAdded(c3,ada)", "membersChanged"])
        #expect(try audience.getMembers().get("ada")?.connections.map(\.id) == ["c1", "c3"])
    }

    /// serviceAudience.ts removeMember handler: reported from the members as of the last
    /// getMembers, so a removed client still has its member.
    @Test func removingAKnownClientEmitsMemberRemovedThenMembersChanged() throws {
        let container = FakeContainer()
        try container.loaderAudience.addMember("c1", client(user: "ada"))
        try container.loaderAudience.addMember("c2", client(user: "summarizer", interactive: false))
        let audience = try createServiceAudience(container: container, createServiceMember: member)
        var received: [String] = []
        audience.events.on { received.append(names($0)) }
        container.loaderAudience.removeMember("c2")
        container.loaderAudience.removeMember("c1")
        #expect(received == ["memberRemoved(c1,ada)", "membersChanged"])
    }

    /// serviceAudience.ts: the container's `connected` event changes the members.
    @Test func connectingChangesMembers() throws {
        let container = FakeContainer()
        let audience = try createServiceAudience(container: container, createServiceMember: member)
        var received: [String] = []
        audience.events.on { received.append(names($0)) }
        container.events.emit(.connected(clientId: "c1"))
        container.events.emit(.disconnected)
        #expect(received == ["membersChanged"])
    }

    /// serviceAudience.ts `getMyself`: nil without a client ID or before the client is a member.
    @Test func myselfIsThisClientsMemberAndConnection() throws {
        let container = FakeContainer()
        let audience = try createServiceAudience(container: container, createServiceMember: member)
        #expect(try audience.getMyself() == nil)
        container.clientId = "c2"
        #expect(try audience.getMyself() == nil)
        try container.loaderAudience.addMember("c1", client(user: "ada", mode: "read"))
        try container.loaderAudience.addMember("c2", client(user: "ada"))
        let myself = try #require(try audience.getMyself())
        #expect(myself.currentConnection == "c2")
        #expect(myself.member.userId == "ada")
        #expect(myself.member.connections.map(\.id) == ["c1", "c2"])
    }

    /// A member that cannot be created throws in TS out of the audience event, which closes the
    /// container; here the handler closes it with that error.
    @Test func aMemberThatCannotBeCreatedClosesTheContainer() throws {
        let container = FakeContainer()
        let audience = try createServiceAudience(container: container) { client -> TestMember in
            guard client.user.id != "bad" else { throw DatastoreError("not a service user") }
            return member(client)
        }
        try withExtendedLifetime(audience) {
            try container.loaderAudience.addMember("c1", client(user: "bad"))
        }
        #expect(container.calls == ["close"])
        #expect(container.closeErrors == ["not a service user"])
    }
}
