import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import FluidRouterliciousDriver
import Foundation

/// Ports container-loader/src/connectionManager.ts. Synchronous connection state is owned by
/// Container's executor; connectToDeltaStream and socket disposal are the only async edges.
public final class ConnectionManager {
    public private(set) var connection: DocumentDeltaConnection?
    public private(set) var clientId: JSString?
    public private(set) var connected = false

    public init() {}

    public nonisolated(nonsending) func connect(_ service: DocumentService, summarizer: Bool = false) async throws
        -> IConnected
    {
        let connection = DocumentDeltaConnection()
        self.connection = connection
        let details = try await service.connectToDeltaStream(connection, summarizer: summarizer)
        clientId = details.clientId
        connected = false
        return details
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
        await old?.disconnect()
    }

    public func connectionFailed() { connected = false }
}
