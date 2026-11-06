import FluidDriverDefinitions
import FluidJS

/// Ports audience.ts ISelf.
public struct ISelf: Sendable {
    public let clientId: JSString
    public let client: IClient?

    public init(clientId: JSString, client: IClient?) {
        self.clientId = clientId
        self.client = client
    }
}

/// Ports audience.ts IAudience: the clients connected to the document, and this client's own
/// entry. Read on the owning container's executor.
public protocol IAudience: AnyObject {
    var events: ListenerList<AudienceEvent> { get }
    func getMembers() -> JSMap<JSString, IClient>
    func getMember(_ clientId: JSString) -> IClient?
    func getSelf() -> ISelf?
}
