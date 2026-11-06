import FluidDriverDefinitions
import FluidJS
import Foundation

/// odspCache.ts's sessionJoinCache: shares in-flight discovery, evicts rejected promises.
public actor OdspSessionJoinCache {
    public struct Entry: Sendable {
        public let entryTime: Double
        public let response: JSONValue
        public init(entryTime: Double, response: JSONValue) {
            self.entryTime = entryTime
            self.response = response
        }
    }
    private struct Pending {
        let id: UUID
        let task: Task<Entry, Error>
    }
    private var entries: [String: Pending] = [:]
    public init() {}
    public func addOrGet(_ key: String, fetch: @escaping @Sendable () async throws -> Entry) async throws -> Entry {
        if let entry = entries[key] { return try await entry.task.value }
        let id = UUID()
        let task = Task { try await fetch() }
        entries[key] = Pending(id: id, task: task)
        do { return try await task.value }
        catch {
            if entries[key]?.id == id { entries.removeValue(forKey: key) }
            throw error
        }
    }
    public func remove(_ key: String) { entries.removeValue(forKey: key) }
}

/// odspDelayLoadedDeltaStream.ts. Discovery caching and refresh are owned by the stream's executor.
public actor OdspDelayLoadedDeltaStream {
    private let key: String
    private let cache: OdspSessionJoinCache
    /// fetchJoinSession(requestSocketToken, displayName, isRefreshingJoinSession, token options).
    private let fetch: @Sendable (Bool, String?, Bool, TokenFetchOptions) async throws -> JSONValue
    private let now: @Sendable () -> Double
    private let disableRefresh: Bool
    private var timer: Task<Void, Never>?
    private var timerGeneration = 0
    private var currentClientId: String?
    public private(set) var currentDeltaConnection: UUID?
    public private(set) var currentConnection: OdspDocumentDeltaConnection?
    public private(set) var relayServiceTenantAndSessionId: String?
    public private(set) var refreshDeadline: Double?
    public private(set) var refreshError: Error?
    public private(set) var disconnectError: Error?
    public init(hashedDocumentId: String, cache: OdspSessionJoinCache, disableRefresh: Bool = false, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, fetch: @escaping @Sendable (Bool, String?, Bool, TokenFetchOptions) async throws -> JSONValue) {
        key = hashedDocumentId + "/joinsession"
        self.cache = cache
        self.disableRefresh = disableRefresh
        self.now = now
        self.fetch = fetch
    }
    public func joinSession(requestSocketToken: Bool = true, displayName: String? = nil, refreshing: Bool = false, clientId: String? = nil, options: TokenFetchOptions = TokenFetchOptions()) async throws -> JSONValue {
        if refreshing, currentClientId == nil || (clientId != nil && clientId != currentClientId) {
            clearJoinSessionTimer()
            throw OdspNetworkError("genericError", canRetry: false)
        }
        let fetch = self.fetch
        let now = self.now
        let execute: @Sendable () async throws -> OdspSessionJoinCache.Entry = {
            let response = try await fetch(requestSocketToken, displayName, refreshing, options)
            return .init(entryTime: now(), response: response)
        }
        var entry = try await cache.addOrGet(key, fetch: execute)
        var duration = try entry.response.asObject()["refreshSessionDurationSeconds"]?.asNumber() ?? 3600
        if entry.entryTime + duration * 1000 - 30000 - now() <= 0 {
            await cache.remove(key)
            entry = try await cache.addOrGet(key, fetch: execute)
            duration = try entry.response.asObject()["refreshSessionDurationSeconds"]?.asNumber() ?? 3600
        }
        var response = try entry.response.asObject()
        response["refreshSessionDurationSeconds"] = .number(duration)
        relayServiceTenantAndSessionId = try entry.response.member("tenantId").asString().description + "/" + entry.response.member("id").asString().description
        clearJoinSessionTimer()
        let delta = entry.entryTime + duration * 1000 - 30000 - now()
        if !disableRefresh, delta > 0 {
            refreshDeadline = now() + delta
            let generation = timerGeneration
            let scheduledClient = currentClientId
            timer = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(delta)) } catch { return }
                await self?.refresh(generation: generation, requestSocketToken: requestSocketToken, displayName: displayName, clientId: scheduledClient)
            }
        }
        return .object(response)
    }
    public func connectToDeltaStream(client: JSONValue, factory: OdspSocketIOFactory, displayName: String? = nil, epoch: String? = nil, validateEpoch: @Sendable (String?) async throws -> Void) async throws -> UUID {
        guard currentDeltaConnection == nil else { throw JSONDecodingError("0x4ad") }
        let discovery = try await joinSession(displayName: displayName)
        guard let url = URL(string: try discovery.member("deltaStreamSocketUrl").asString().description) else { throw JSONDecodingError("invalid relay URL") }
        let fields = try discovery.asObject()
        guard let token = fields["socketToken"], token != .null else { throw OdspNetworkError("fetchTokenError", canRetry: false) }
        do {
            let id = try await factory.create(url: url, tenantId: discovery.member("tenantId").asString().description, documentId: discovery.member("id").asString().description, token: token, client: client, epoch: epoch)
            let details = try await factory.details(id)
            try await validateEpoch(details.asObject()["epoch"]?.asString().description)
            currentDeltaConnection = id
            currentClientId = try await factory.details(id).member("clientId").asString().description
            try await factory.setDisconnectHandler(id) { [weak self] error in
                await self?.disconnected(error: error)
                do { try await factory.release(id) }
                catch { await self?.recordDisconnectError(error) }
            }
            return id
        } catch {
            await connectionFailed(scenarioName: (error as? OdspNetworkError)?.scenarioName)
            throw error
        }
    }
    /// odspDelayLoadedDeltaStream.ts connectToDeltaStream: one token-refresh retry around the
    /// websocket token, join session and socket handshake. Without a host websocket fetcher the
    /// token comes from the join-session response.
    public func connectToDeltaStream(_ client: IClient, factory: OdspSocketIOFactory, getWebsocketToken: (@Sendable (TokenFetchOptions) async throws -> String?)?, epochTracker: EpochTracker, displayName: String?) async throws -> OdspDocumentDeltaConnection {
        guard currentDeltaConnection == nil else { throw JSONDecodingError("0x4ad") }
        return try await getWithRetryForTokenRefresh { options in
            let requestWebsocketTokenFromJoinSession = getWebsocketToken == nil
            // TS starts the websocket token request before joinSession, so its fetcher runs first.
            let websocketToken = try await getWebsocketToken?(options)
            let endpoint = try await self.joinSession(requestSocketToken: requestWebsocketTokenFromJoinSession, displayName: displayName, options: options)
            let fields = try endpoint.asObject()
            var finalToken = websocketToken
            if finalToken == nil, case .string(let token) = fields["socketToken"] { finalToken = token.description }
            guard let finalToken else { throw OdspNetworkError("fetchTokenError", canRetry: false) }
            guard let url = URL(string: try endpoint.member("deltaStreamSocketUrl").asString().description) else { throw JSONDecodingError("invalid relay URL") }
            do {
                let id = try await factory.create(url: url, tenantId: endpoint.member("tenantId").asString().description, documentId: endpoint.member("id").asString().description, token: .string(JSString(finalToken)), client: client.json, nonce: UUID().uuidString.lowercased(), epoch: epochTracker.fluidEpoch)
                try epochTracker.validateEpoch(try await factory.details(id).asObject()["epoch"]?.asString().description)
                let (details, events) = try await factory.deltaConnection(id)
                let connection = OdspDocumentDeltaConnection(factory: factory, id: id, details: details, events: events)
                currentDeltaConnection = id
                currentConnection = connection
                currentClientId = details.clientId.description
                try await factory.setDisconnectHandler(id) { [weak self] error in
                    await self?.disconnected(error: error)
                    do { try await factory.release(id) }
                    catch { await self?.recordDisconnectError(error) }
                }
                return connection
            } catch {
                await connectionFailed(scenarioName: (error as? OdspNetworkError)?.scenarioName)
                throw error
            }
        }
    }
    public func dispose() async {
        clearJoinSessionTimer()
        await currentConnection?.dispose()
        currentConnection = nil
    }
    private func recordDisconnectError(_ error: Error) { disconnectError = error }
    public func connected(clientId: String) { currentClientId = clientId }
    public func disconnected(error: OdspNetworkError? = nil) async {
        clearJoinSessionTimer()
        currentClientId = nil
        currentDeltaConnection = nil
        currentConnection = nil
        if error?.errorType == "authorizationError" { await cache.remove(key) }
    }
    public func connectionFailed(scenarioName: String?) async {
        if scenarioName == nil || scenarioName == "connect_document_error" {
            clearJoinSessionTimer()
            await cache.remove(key)
        }
    }
    public func clearJoinSessionTimer() {
        timer?.cancel()
        timer = nil
        refreshDeadline = nil
        timerGeneration += 1
    }
    private func refresh(generation: Int, requestSocketToken: Bool, displayName: String?, clientId: String?) async {
        guard generation == timerGeneration else { return }
        do {
            _ = try await getWithRetryForTokenRefresh { options in
                try await self.joinSession(requestSocketToken: requestSocketToken, displayName: displayName, refreshing: true, clientId: clientId, options: options)
            }
        } catch { refreshError = error }
    }
}
