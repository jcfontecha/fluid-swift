import FluidDriverDefinitions
import FluidJS

/// Ports container-loader/src/audience.ts. Disconnection retains last observed membership.
public final class Audience {
    public let events = ListenerList<AudienceEvent>()
    private var members: [(clientId: JSString, client: IClient)] = []

    public init() {}
    public func getMembers() -> [(clientId: JSString, client: IClient)] { members }
    public func getMember(_ id: JSString) -> IClient? {
        members.first { $0.clientId == id }?.client
    }

    /// audience.ts assert 0x4b2: duplicate signals are allowed only for identical payloads.
    public func addMember(_ id: JSString, _ client: IClient) throws {
        if let old = getMember(id) {
            guard JSON.stringify(old.json) == JSON.stringify(client.json) else {
                throw JSONDecodingError("0x4b2: audience payload changed")
            }
        } else {
            members.append((id, client))
            events.emit(.addMember(id, client))
        }
    }

    @discardableResult
    public func removeMember(_ id: JSString) -> Bool {
        guard let old = getMember(id) else { return false }
        members.removeAll { $0.clientId == id }
        events.emit(.removeMember(id, old))
        return true
    }

    public func clearReadClients() {
        for entry in members where entry.client.mode == .read {
            removeMember(entry.clientId)
        }
    }
}
