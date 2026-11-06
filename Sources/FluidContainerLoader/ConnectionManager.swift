import FluidDriverDefinitions
import FluidJS

/// Ports container-loader/src/connectionManager.ts. Its state belongs to the container's owner;
/// connecting to the delta stream is the only async edge. connectionManager.ts keeps one attempt in
/// flight (`pendingConnection`) and re-checks it after the await, so an attempt that disconnect or
/// close cancelled disposes the connection it got instead of installing it.
public final class ConnectionManager {
    public private(set) var connection: (any IDocumentDeltaConnection)?
    public private(set) var clientId: JSString?
    public private(set) var connected = false
    /// connectionManager.ts `pendingConnection`: the attempt in flight, if any.
    public private(set) var pendingConnection: Int?
    /// The latest attempt. `connection`, when set, is the one it produced.
    public private(set) var attempt = 0

    public init() {}

    /// connectionManager.ts connectCore: nil when a connection exists or an attempt is in flight.
    public func beginConnection() -> Int? {
        guard connection == nil, pendingConnection == nil else { return nil }
        attempt += 1
        pendingConnection = attempt
        return attempt
    }

    /// Connects attempt `attempt`. Returns nil when the attempt was cancelled while it awaited the
    /// driver (connectionManager.ts: "Check for abort signal after while loop as well").
    public nonisolated(nonsending) func connect(_ service: any IDocumentService, client: IClient, attempt: Int)
        async throws -> (any IDocumentDeltaConnection)?
    {
        let connection = try await service.connectToDeltaStream(client)
        guard pendingConnection == attempt else {
            await connection.dispose()
            return nil
        }
        pendingConnection = nil
        self.connection = connection
        clientId = connection.details.clientId
        connected = false
        return connection
    }

    /// Whether events from attempt `attempt` belong to the current connection.
    public func isCurrent(_ attempt: Int) -> Bool {
        connection != nil && attempt == self.attempt
    }

    /// connectionManager.ts cancelConnection: the attempt in flight is abandoned.
    public func cancelConnection() {
        pendingConnection = nil
    }

    /// Write-mode clients must wait for their own sequenced join before submitting ops.
    public func receivedJoin(_ message: ISequencedDocumentMessage) throws {
        if message.type == "join", try IClientJoin(json: systemData(message)).clientId == clientId {
            connected = true
        }
    }

    /// connectionManager.ts disconnectFromDeltaStream: forgets the connection, and any attempt in
    /// flight, and returns the connection for the caller to dispose.
    public func disconnect() -> (any IDocumentDeltaConnection)? {
        connected = false
        pendingConnection = nil
        let old = connection
        connection = nil
        return old
    }

    /// connectionManager.ts sendMessages: one batch, enqueued synchronously on the connection.
    public func sendMessages(_ messages: [IDocumentMessage]) throws {
        guard let connection else { throw JSONDecodingError("disconnected") }
        connection.submit(messages)
    }

    /// connectionManager.ts submitSignal: without a connection the signal is dropped (TS logs
    /// `submitSignalDisconnected`).
    public func submitSignal(_ content: String, targetClientId: String?) throws {
        try connection?.submitSignal(content, targetClientId: targetClientId)
    }
}
