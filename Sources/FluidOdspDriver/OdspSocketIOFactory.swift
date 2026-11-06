import FluidDriverDefinitions
import FluidJS
import FluidSocketIO
import Foundation

/// I/O owner for odspDocumentDeltaConnection.ts's factory-wide SocketReference registry.
/// All state and delivery run on this actor; a single writer preserves synchronous emit order.
public actor OdspSocketIOFactory {
    private enum Write: Sendable {
        case emit(String, [JSONValue])
        case close
    }
    private final class Session {
        let socket: SocketIOClient
        let reference: SocketReference
        let writer: Task<Void, Never>
        var connecting: Task<Void, Error>?
        var deletion: Task<Void, Never>?
        init(socket: SocketIOClient, reference: SocketReference, writer: Task<Void, Never>) {
            self.socket = socket
            self.reference = reference
            self.writer = writer
        }
    }
    private final class Pending {
        let key: String
        let documentId: String
        let epochTracker = EpochTracker()
        let nonce: String
        let multiplex: Bool
        var requestedMode: JSONValue = .null
        var disconnectError: any Error = OdspNetworkError("genericNetworkError", canRetry: true)
        var handshake: CheckedContinuation<UUID, Error>?
        var timeout: Task<Void, Never>?
        var connection: OdspDocumentDeltaConnectionState?
        var details: JSONValue?
        var ops: [JSONValue] = []
        var signals: [JSONValue] = []
        var earlyOps = true
        var earlySignals = true
        var events: [JSONValue] = []
        var flush: CheckedContinuation<JSONValue, Error>?
        var disconnectHandler: (@Sendable (OdspNetworkError?) async -> Void)?
        var disconnectNotified = false
        /// The IDocumentDeltaConnection event stream, once `deltaConnection` handed it out.
        var eventsContinuation: AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error>.Continuation?
        /// Events go to the contract stream once handed out (a malformed message ends it with the
        /// error); before that they are kept as JSON for `takeEvents`.
        func record(_ legacy: JSONValue, _ event: () throws -> DocumentDeltaConnectionEvent) {
            guard let eventsContinuation else {
                events.append(legacy)
                return
            }
            do { eventsContinuation.yield(try event()) }
            catch { eventsContinuation.finish(throwing: error) }
        }
        init(key: String, documentId: String, nonce: String, multiplex: Bool) {
            self.key = key
            self.documentId = documentId
            self.nonce = nonce
            self.multiplex = multiplex
        }
    }
    private var sessions: [String: Session] = [:]
    private var pending: [UUID: Pending] = [:]
    public init() {}

    public func create(url: URL, tenantId: String, documentId: String, token: JSONValue, client: JSONValue, nonce: String = UUID().uuidString, epoch: String? = nil, prefix: String? = nil) async throws -> UUID {
        let key = try OdspDocumentDeltaConnectionState.socketKey(url: url.absoluteString, tenantId: tenantId, documentId: documentId, prefix: prefix)
        let multiplex = try OdspDocumentDeltaConnectionState.enableMultiplexing(url.absoluteString)
        let session: Session
        if let existing = sessions[key], !existing.reference.disconnected {
            try existing.reference.addReference()
            existing.deletion?.cancel()
            session = existing
        } else {
            let socket = SocketIOClient()
            let (writes, continuation) = AsyncStream<Write>.makeStream()
            let reference = SocketReference(key: key, send: { name, args in
                continuation.yield(.emit(name, args))
            }, close: {
                continuation.yield(.close)
                continuation.finish()
            })
            let writer = Task { [weak self] in
                for await write in writes {
                    do {
                        switch write {
                        case .emit(let name, let args): try await socket.emit(name, arguments: args)
                        case .close: await socket.close()
                        }
                    } catch { await self?.failed(key: key, socket: socket, error: error) }
                }
            }
            session = Session(socket: socket, reference: reference, writer: writer)
            let query = multiplex ? [:] : ["documentId": documentId, "tenantId": tenantId]
            // Publish one readiness task before yielding: concurrent creators must await the same socket.
            session.connecting = Task { [weak self] in
                for name in ["op", "signal", "nack", "get_ops_response", "flush_ops_response", "connect_document_success", "connect_document_error", "server_disconnect", "disconnect", "error", "connect_error"] {
                    await socket.on(name) { [weak self] event in
                        await self?.receive(key: key, socket: socket, event: event)
                    }
                }
                try await socket.connect(url, options: .init(query: query, timeout: .seconds(60)))
            }
            sessions[key] = session
        }
        let id = UUID()
        let entry = Pending(key: key, documentId: documentId, nonce: nonce, multiplex: multiplex)
        if let epoch { try entry.epochTracker.validateEpoch(epoch) }
        entry.requestedMode = try client.member("mode")
        pending[id] = entry
        do {
            try await session.connecting?.value
            session.reference.connected = true
            var message = JSObject<JSONValue>()
            message["client"] = client
            message["id"] = .string(JSString(documentId))
            message["mode"] = try client.member("mode")
            message["tenantId"] = .string(JSString(tenantId))
            message["token"] = token
            message["versions"] = .array(["^0.4.0", "^0.3.0", "^0.2.0", "^0.1.0"].map { .string(JSString($0)) })
            message["driverVersion"] = .string("3.11.0")
            message["nonce"] = .string(JSString(nonce))
            if let epoch = entry.epochTracker.fluidEpoch { message["epoch"] = .string(JSString(epoch)) }
            let environment = try client.member("details").asObject()["environment"]?.asString().description ?? ""
            message["relayUserAgent"] = .string(JSString(environment + "; driverVersion:3.11.0"))
            message["supportedFeatures"] = try JSON.parse("{\"api_get_ops\":true,\"submit_signals_v2\":true}")
            return try await withCheckedThrowingContinuation { continuation in
                entry.handshake = continuation
                entry.timeout = Task {
                    do { try await Task.sleep(for: .seconds(62)) } catch { return }
                    self.reject(id: id, error: OdspNetworkError("genericNetworkError", canRetry: true))
                }
                do { try session.reference.emit("connect_document", [.object(message)]) }
                catch { reject(id: id, error: error) }
            }
        } catch {
            reject(id: id, error: error)
            throw error
        }
    }

    public func initialMessages(_ id: UUID) throws -> [JSONValue] {
        let entry = try get(id)
        guard entry.earlyOps else { throw JSONDecodingError("0x08e") }
        entry.earlyOps = false
        let initial = try entry.details?.member("initialMessages").asArray() ?? []
        if entry.ops.isEmpty { return initial }
        let result = try (initial + entry.ops).map { (try $0.member("sequenceNumber").asInt(), $0) }.sorted { $0.0 < $1.0 }.map { $0.1 }
        entry.ops.removeAll()
        return result
    }
    public func initialSignals(_ id: UUID) throws -> [JSONValue] {
        let entry = try get(id)
        entry.earlySignals = false
        let result = try (entry.details?.member("initialSignals").asArray() ?? []) + entry.signals
        entry.signals.removeAll()
        return result
    }
    /// The IDocumentDeltaConnection view of a connected handle: details carry the merged initial
    /// messages and signals (TS `initialMessages`/`initialSignals` getters); later ops, signals,
    /// nacks and the final disconnect arrive on the returned stream.
    public func deltaConnection(_ id: UUID) throws -> (details: IConnected, events: AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error>) {
        let entry = try get(id)
        guard let payload = entry.details else { throw JSONDecodingError("not connected") }
        var details = try payload.asObject()
        details["initialMessages"] = .array(try initialMessages(id))
        details["initialSignals"] = .array(try initialSignals(id))
        let connected = try IConnected(json: .object(details))
        let (events, continuation) = AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error>.makeStream()
        entry.eventsContinuation = continuation
        return (connected, events)
    }
    /// A teardown assertion surfaces on the event stream; nothing else observes it.
    public func failEvents(_ id: UUID, _ error: any Error) {
        pending[id]?.eventsContinuation?.finish(throwing: error)
    }
    public func isDisposed(_ id: UUID) -> Bool {
        pending[id]?.connection?.disposed ?? true
    }
    public func takeEvents(_ id: UUID) throws -> [JSONValue] {
        let entry = try get(id)
        let events = entry.events
        entry.events.removeAll()
        return events
    }
    public func submit(_ id: UUID, messages: [JSONValue]) throws { try get(id).connection?.submit(messages) }
    public func submitSignal(_ id: UUID, signals: [JSONValue]) throws { try get(id).connection?.submitSignal(signals) }
    public func requestOps(_ id: UUID, from: Int, to: Int) throws { try get(id).connection?.requestOps(from: from, to: to) }
    public func flush(_ id: UUID) async throws -> JSONValue {
        let entry = try get(id)
        guard let connection = entry.connection else { throw JSONDecodingError("not connected") }
        return try await withCheckedThrowingContinuation { continuation in
            entry.flush?.resume(throwing: JSONDecodingError("process involving flush() was cancelled OR unsupported concurrency"))
            entry.flush = continuation
            do { try connection.flush() }
            catch {
                entry.flush = nil
                continuation.resume(throwing: error)
            }
        }
    }
    public func dispose(_ id: UUID) async throws {
        let entry = try get(id)
        try entry.connection?.dispose(now: Date().timeIntervalSince1970 * 1000)
        scheduleDeletion(key: entry.key)
        await notifyDisconnects()
    }
    /// The owner releases the handle after consuming its terminal event; socket refs were already removed.
    public func release(_ id: UUID) async throws {
        try await dispose(id)
        pending.removeValue(forKey: id)
    }
    private func scheduleDeletion(key: String) {
        guard let session = sessions[key], session.reference.references == 0 else { return }
        session.deletion?.cancel()
        session.deletion = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            do {
                try session.reference.tick(now: Date().timeIntervalSince1970 * 1000)
                if session.reference.disconnected, sessions[key] === session { sessions.removeValue(forKey: key) }
            } catch { await self.failed(key: key, socket: session.socket, error: error) }
        }
    }
    public func close() async throws {
        for (id, entry) in pending where entry.connection?.disposed != true {
            reject(id: id, error: OdspNetworkError("genericNetworkError", canRetry: true))
        }
        await notifyDisconnects()
        pending.removeAll()
        let closing = Array(sessions.values)
        sessions.removeAll()
        for session in closing {
            session.deletion?.cancel()
            try session.reference.closeSocket()
            await session.writer.value
        }
    }
    public func details(_ id: UUID) throws -> JSONValue {
        guard let details = try get(id).details else { throw JSONDecodingError("not connected") }
        return details
    }
    public func setDisconnectHandler(_ id: UUID, handler: @escaping @Sendable (OdspNetworkError?) async -> Void) async throws {
        let entry = try get(id)
        entry.disconnectHandler = handler
        entry.disconnectNotified = false
        await notifyDisconnects()
    }
    private func notifyDisconnects() async {
        for (_, entry) in pending where entry.connection?.disposed == true && !entry.disconnectNotified {
            entry.disconnectNotified = true
            await entry.disconnectHandler?(entry.disconnectError as? OdspNetworkError)
            entry.flush?.resume(throwing: entry.disconnectError)
            entry.flush = nil
        }
    }
    private func get(_ id: UUID) throws -> Pending {
        guard let entry = pending[id] else { throw JSONDecodingError("unknown delta connection") }
        return entry
    }
    private func reject(id: UUID, error: Error) {
        guard let entry = pending[id] else { return }
        entry.timeout?.cancel()
        entry.handshake?.resume(throwing: error)
        entry.handshake = nil
        entry.disconnectError = error
        if let connection = entry.connection {
            do { try connection.dispose() } catch { entry.events.append(.array([.string("error"), .string(JSString(String(describing: error)))])) }
        } else if let session = sessions[entry.key] {
            do { try session.reference.removeSocketIoReference(now: Date().timeIntervalSince1970 * 1000) }
            catch { entry.events.append(.array([.string("error"), .string(JSString(String(describing: error)))])) }
            pending.removeValue(forKey: id)
            scheduleDeletion(key: entry.key)
        }
    }
    private func failed(key: String, socket: SocketIOClient, error: Error) async {
        guard let session = sessions[key], session.socket === socket else { return }
        for (id, entry) in pending where entry.key == key {
            entry.disconnectError = error
            if entry.connection == nil { reject(id: id, error: error) }
        }
        do { try session.reference.serverDisconnect(clientId: nil) }
        catch {
            for (_, entry) in pending where entry.key == key {
                entry.events.append(.array([.string("error"), .string(JSString(String(describing: error)))]))
            }
        }
        await notifyDisconnects()
    }
    private func receive(key: String, socket: SocketIOClient, event: SocketEvent) async {
        guard sessions[key]?.socket === socket else { return }
        for (id, entry) in pending where entry.key == key {
            if entry.connection?.disposed == true { continue }
            do {
                switch event.name {
                case "connect_document_success", "connect_document_error":
                    guard entry.handshake != nil, let response = event.arguments.first else { continue }
                    let fields = try response.asObject()
                    if let nonce = fields["nonce"], nonce != .string(JSString(entry.nonce)) { continue }
                    if event.name == "connect_document_error" {
                        let code = try response.member("code").asInt()
                        var error = try createOdspNetworkError(status: code)
                        error.scenarioName = "connect_document_error"
                        if code == 400 || code == 404 { error.canRetry = true }
                        throw error
                    }
                    let scopes = try response.member("claims").member("scopes").asArray()
                    let mode = try response.member("mode").asString()
                    if scopes.contains(.string("doc:write")) ? .string(mode) != entry.requestedMode : mode == "write" {
                        var error = OdspNetworkError("genericNetworkError", canRetry: false)
                        error.scenarioName = "connect_document_success"
                        throw error
                    }
                    try entry.epochTracker.validateEpoch(fields["epoch"]?.asString().description)
                    guard let session = sessions[key] else { throw JSONDecodingError("missing session") }
                    let connection = OdspDocumentDeltaConnectionState(reference: session.reference, documentId: entry.documentId, clientId: try response.member("clientId").asString().description, noncePrefix: UUID().uuidString + "-")
                    connection.supportedGetOps = try fields["supportedFeatures"]?.asObject()["api_get_ops"] == .bool(true)
                    connection.supportedFlushOps = try fields["supportedFeatures"]?.asObject()["api_flush_ops"] == .bool(true)
                    connection.onOps = { [weak entry] ops in
                        guard let entry else { return }
                        entry.record(.array([.string("op"), .array(ops)])) {
                            .op(documentId: JSString(entry.documentId), messages: try ops.map { try ISequencedDocumentMessage(json: $0) })
                        }
                    }
                    connection.onSignal = { [weak entry] signal in
                        entry?.record(.array([.string("signal"), signal])) {
                            let signals: [JSONValue]
                            if case .array(let values) = signal { signals = values } else { signals = [signal] }
                            return .signal(try signals.map { try ISignalMessage(json: $0) })
                        }
                    }
                    connection.onNack = { [weak entry] target, nacks in
                        entry?.record(.array([.string("nack"), nacks])) {
                            .nack(documentId: target, nacks: try nacks.asArray().map { try INack(json: $0) })
                        }
                    }
                    connection.onDisconnect = { [weak entry] in
                        guard let entry else { return }
                        entry.record(.array([.string("disconnect"), .string(JSString(entry.documentId))])) {
                            .disconnect(reason: entry.disconnectError)
                        }
                        entry.eventsContinuation?.finish()
                    }
                    connection.onFlush = { [weak entry] response in
                        guard let entry else { return }
                        entry.flush?.resume(returning: response)
                        entry.flush = nil
                    }
                    entry.connection = connection
                    entry.details = response
                    entry.timeout?.cancel()
                    entry.handshake?.resume(returning: id)
                    entry.handshake = nil
                case "op" where entry.earlyOps:
                    if !entry.multiplex || event.arguments.first == .string(JSString(entry.documentId)) {
                        guard event.arguments.count > 1 else { throw JSONDecodingError("missing ops") }
                        entry.ops += try event.arguments[1].asArray()
                    }
                case "signal" where entry.earlySignals:
                    if !entry.multiplex || event.arguments.count < 2 || event.arguments[1] == .string(JSString(entry.documentId)) {
                        guard let signal = event.arguments.first else { throw JSONDecodingError("missing signal") }
                        if case .array(let signals) = signal { entry.signals += signals }
                        else { entry.signals.append(signal) }
                    }
                case "server_disconnect":
                    let target = try event.arguments.count > 1 ? event.arguments[1].asString().description : nil
                    guard let failure = event.arguments.first else { throw JSONDecodingError("missing server disconnect") }
                    var error = try createOdspNetworkError(status: failure.member("code").asInt())
                    // SocketReference treats server disconnects as recoverable; joinSession gates retry.
                    error.canRetry = true
                    for (_, candidate) in pending where candidate.key == key { candidate.disconnectError = error }
                    if let session = sessions[key] { try session.reference.serverDisconnect(clientId: target) }
                    if entry.handshake != nil { throw OdspNetworkError("genericNetworkError", canRetry: true) }
                case "disconnect", "error", "connect_error":
                    await failed(key: key, socket: socket, error: OdspNetworkError("genericNetworkError", canRetry: true))
                    return
                default: try entry.connection?.receive(name: event.name, arguments: event.arguments, multiplex: entry.multiplex)
                }
            } catch { reject(id: id, error: error) }
        }
        await notifyDisconnects()
    }
}
