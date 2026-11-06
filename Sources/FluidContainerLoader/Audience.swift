import FluidContainerDefinitions
import FluidDriverDefinitions
import FluidJS

/// Ports container-loader/src/audience.ts. Disconnection retains last observed membership.
public final class Audience: IAudience {
    public let events = ListenerList<AudienceEvent>()
    private var members = JSMap<JSString, IClient>()
    private var currentClientId: JSString?

    public init() {}

    public func getMembers() -> JSMap<JSString, IClient> { members }

    public func getMember(_ id: JSString) -> IClient? { members.get(id) }

    public func getSelf() -> ISelf? {
        currentClientId.map { ISelf(clientId: $0, client: getMember($0)) }
    }

    /// audience.ts `setCurrentClientId`: the new self may not be a member yet.
    public func setCurrentClientId(_ clientId: JSString) {
        guard currentClientId != clientId else { return }
        let oldId = currentClientId
        currentClientId = clientId
        events.emit(.selfChanged(old: oldId.map { ISelf(clientId: $0, client: nil) }, new: ISelf(clientId: clientId, client: getMember(clientId))))
    }

    /// audience.ts assert 0x4b2: duplicate signals are allowed only for identical payloads.
    public func addMember(_ id: JSString, _ client: IClient) throws {
        if let old = getMember(id) {
            guard JSON.stringify(old.json) == JSON.stringify(client.json) else {
                throw JSONDecodingError("0x4b2: audience payload changed")
            }
        } else {
            members.set(id, client)
            events.emit(.addMember(id, client))
        }
    }

    @discardableResult
    public func removeMember(_ id: JSString) -> Bool {
        guard let old = getMember(id) else { return false }
        _ = members.delete(id)
        events.emit(.removeMember(id, old))
        return true
    }

    public func clearReadClients() {
        for (clientId, client) in members.entries where client.mode == .read {
            removeMember(clientId)
        }
    }
}
