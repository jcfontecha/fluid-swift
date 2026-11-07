import FluidContainerDefinitions
import FluidDriverUtils
import FluidDriverDefinitions
import FluidJS

/// Ports container-loader/src/connectionManager.ts. Its state belongs to the container's owner;
/// connecting to the delta stream is the only async edge. connectionManager.ts keeps one attempt in
/// flight (`pendingConnection`) and re-checks it after the await, so an attempt that disconnect or
/// close cancelled disposes the connection it got instead of installing it.
public final class ConnectionManager {
    public private(set) var connection: (any IDocumentDeltaConnection)?
    public private(set) var clientId: JSString?
    public let connectionStateHandler = ConnectionStateHandler()
    public var connected: Bool { connectionStateHandler.connected }
    public private(set) var reconnectMode: ReconnectMode
    public var requestedMode = ConnectionMode.write
    public private(set) var readonlyPermissions = false
    private let sleep: RetrySleep
    /// connectionManager.ts `pendingConnection`: the attempt in flight, if any.
    public private(set) var pendingConnection: Int?
    /// The latest attempt. `connection`, when set, is the one it produced.
    public private(set) var attempt = 0

    public init(reconnectAllowed: Bool = true, sleep: @escaping RetrySleep = retrySleep) {
        reconnectMode = reconnectAllowed ? .enabled : .never
        self.sleep = sleep
    }

    public func setAutoReconnect(_ mode: ReconnectMode) throws {
        guard mode != .never, reconnectMode != .never else {
            throw JSONDecodingError("0x0df: cannot change Never reconnect mode")
        }
        reconnectMode = mode
    }

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
        var fields = try client.json.asObject()
        fields["mode"] = requestedMode.json
        let requestedClient = try IClient(json: .object(fields))
        var delayMs = 500.0
        while pendingConnection == attempt {
            let connection: any IDocumentDeltaConnection
            do {
                connection = try await service.connectToDeltaStream(requestedClient)
            } catch {
                guard pendingConnection == attempt else { return nil }
                guard canRetryOnError(error) else { throw error }
                guard reconnectMode == .enabled else {
                    pendingConnection = nil
                    return nil
                }
                delayMs = calculateMaxWaitTime(delayMs, error: error)
                try await sleep(delayMs)
                continue
            }
            guard pendingConnection == attempt else {
                await connection.dispose()
                return nil
            }
            pendingConnection = nil
            self.connection = connection
            clientId = connection.details.clientId
            readonlyPermissions = !connection.details.claims.scopes.contains("doc:write")
            return connection
        }
        return nil
    }

    /// Whether events from attempt `attempt` belong to the current connection.
    public func isCurrent(_ attempt: Int) -> Bool {
        connection != nil && attempt == self.attempt
    }

    /// connectionManager.ts cancelConnection: the attempt in flight is abandoned.
    public func cancelConnection() {
        pendingConnection = nil
    }

    /// connectionManager.ts disconnectFromDeltaStream: forgets the connection, and any attempt in
    /// flight, and returns the connection for the caller to dispose.
    public func disconnect() -> (any IDocumentDeltaConnection)? {
        connectionStateHandler.receivedDisconnectEvent(hasPendingOps: false, currentClientInQuorum: false)
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

/// connectionManager.ts getNackReconnectInfo: unlike HTTP status classification, ONLY 403
/// is fatal. A 400 nack reconnects in write mode, and retryAfter is seconds on the wire.
public func getNackReconnectInfo(_ content: INackContent) -> NetworkError {
    NetworkError("Nack (\(content.type.rawValue)): \(content.message)",
                 canRetry: content.code != 403, retryAfterSeconds: content.retryAfter)
}
