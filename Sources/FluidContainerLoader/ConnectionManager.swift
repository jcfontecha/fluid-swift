import FluidDriverDefinitions
import FluidJS

/// Ports container-loader/src/connectionManager.ts. Synchronous connection state is owned by
/// Container's executor; connectToDeltaStream and connection disposal are the only async edges.
public final class ConnectionManager {
    public private(set) var connection: (any IDocumentDeltaConnection)?
    public private(set) var clientId: JSString?
    public private(set) var connected = false

    public init() {}

    public nonisolated(nonsending) func connect(_ service: any IDocumentService, client: IClient) async throws
        -> IConnected
    {
        let connection = try await service.connectToDeltaStream(client)
        self.connection = connection
        clientId = connection.details.clientId
        connected = false
        return connection.details
    }

    /// Write-mode clients must wait for their own sequenced join before submitting ops.
    public func receivedJoin(_ message: ISequencedDocumentMessage) throws {
        if message.type == "join", try IClientJoin(json: systemData(message)).clientId == clientId {
            connected = true
        }
    }

    public nonisolated(nonsending) func disconnect() async {
        connected = false
        let old = connection
        connection = nil
        await old?.dispose()
    }

    public func connectionFailed() { connected = false }
}
