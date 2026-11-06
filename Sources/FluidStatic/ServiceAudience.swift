import FluidContainerDefinitions
import FluidDatastore
import FluidDriverDefinitions
import FluidJS

/// Ports fluid-static/src/serviceAudience.ts `ServiceAudience`: the container's interactive
/// clients grouped by user, each user as a service-specific member. Owner-local, like the
/// container it reads.
public final class ServiceAudience<Member: IMember> {
    private let container: any IContainer
    private let audience: any IAudience
    private let createServiceMember: (IClient) throws -> Member
    /// The member of each client ID, as of the last `getMembers`, so `memberRemoved` can report
    /// a client the audience no longer has.
    private var lastMembers = JSMap<String, Member>()
    public let events = ListenerList<ServiceAudienceEvent<Member>>()

    /// serviceAudience.ts constructor. The listeners hold this object weakly: the container's
    /// event lists outlive it.
    init(container: any IContainer, createServiceMember: @escaping (IClient) throws -> Member) throws {
        self.container = container
        audience = container.audience
        self.createServiceMember = createServiceMember
        // getMembers assigns lastMembers so memberRemoved has what it needs if it fires before
        // anything else calls getMembers.
        _ = try getMembers()
        audience.events.on { [weak self] event in
            self?.audienceChanged(event)
        }
        container.events.on { [weak self] event in
            if case .connected = event {
                self?.events.emit(.membersChanged)
            }
        }
    }

    /// serviceAudience.ts `getMembers`: one member per user ID, in audience order, each holding
    /// every connection of that user.
    public func getMembers() throws -> JSMap<String, Member> {
        var users = JSMap<String, Member>()
        for (clientId, client) in audience.getMembers().entries where shouldIncludeAsMember(client) {
            let userId = client.user.id.description
            var user = try users.get(userId) ?? createServiceMember(client)
            user.connections.append(IConnection(id: clientId.description, mode: client.mode))
            users.set(userId, user)
        }
        var clientMemberMap = JSMap<String, Member>()
        for (_, user) in users.entries {
            for connection in user.connections {
                clientMemberMap.set(connection.id, user)
            }
        }
        lastMembers = clientMemberMap
        return users
    }

    /// serviceAudience.ts `getMyself`: nil until this client's own join is processed.
    public func getMyself() throws -> Myself<Member>? {
        guard let clientId = container.clientId?.description else {
            return nil
        }
        guard let member = try getMember(clientId) else {
            return nil
        }
        return Myself(member: member, currentConnection: clientId)
    }

    private func getMember(_ clientId: String) throws -> Member? {
        guard let internalAudienceMember = audience.getMember(JSString(clientId)) else {
            return nil
        }
        guard let member = try getMembers().get(internalAudienceMember.user.id.description) else {
            throw DatastoreError("Attempted to fetch client \(clientId) that is not part of the current member list")
        }
        return member
    }

    /// serviceAudience.ts `addMember` and `removeMember` handlers. In TS an error thrown by a
    /// listener propagates out of the op or signal being processed and the container closes with
    /// it; a Swift listener cannot throw, so it closes the container with the error directly.
    private func audienceChanged(_ event: AudienceEvent) {
        switch event {
        case .addMember(let clientId, let client):
            guard shouldIncludeAsMember(client) else {
                return
            }
            do {
                // The audience emits addMember after storing the client, so getMember finds it.
                if let member = try getMember(clientId.description) {
                    events.emit(.memberAdded(clientId: clientId.description, member: member))
                }
                events.emit(.membersChanged)
            } catch {
                container.close(error)
            }
        case .removeMember(let clientId, _):
            if let member = lastMembers.get(clientId.description) {
                events.emit(.memberRemoved(clientId: clientId.description, member: member))
                events.emit(.membersChanged)
            }
        case .selfChanged:
            break
        }
    }

    /// serviceAudience.ts `shouldIncludeAsMember`: only human (interactive) clients.
    private func shouldIncludeAsMember(_ client: IClient) -> Bool {
        client.details.capabilities.interactive
    }
}

/// Ports serviceAudience.ts `createServiceAudience`.
public func createServiceAudience<Member: IMember>(
    container: any IContainer,
    createServiceMember: @escaping (IClient) throws -> Member
) throws -> ServiceAudience<Member> {
    try ServiceAudience(container: container, createServiceMember: createServiceMember)
}
