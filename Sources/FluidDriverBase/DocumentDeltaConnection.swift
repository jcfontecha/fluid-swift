import FluidDriverDefinitions
import FluidJS
import FluidSocketIO
import Foundation
import Synchronization

/// Ports driver-base/src/documentDeltaConnection.ts. A single-use socket.io connection: `initialize`
/// performs the connect_document handshake, then socket events become `events`. The stream
/// buffers from the start of the handshake until the consumer drains it, so ops and signals that
/// arrive before the consumer attaches keep their order (the TS early op/signal handlers). It ends
/// with one `disconnect` event. No per-event tasks reorder I/O.
public actor DocumentDeltaConnection: IDocumentDeltaConnection {
    public nonisolated let events: AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error>
    private nonisolated let continuation: AsyncThrowingStream<DocumentDeltaConnectionEvent, any Error>.Continuation
    private nonisolated let connected = Mutex<IConnected?>(nil)
    private let socket = SocketIOClient()
    private var handshake: CheckedContinuation<IConnected, any Error>?
    private var request: IConnect?
    private var deadline: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var disposed = false

    /// documentDeltaConnection.ts `errorMessageForClientDisposeWithoutError`.
    public static let errorMessageForClientDisposeWithoutError = "Client closing delta connection"

    public init() {
        (events, continuation) = AsyncThrowingStream.makeStream()
    }

    /// documentDeltaConnection.ts `details`: reading it before the handshake completes is an internal error.
    public nonisolated var details: IConnected {
        guard let details = connected.withLock({ $0 }) else {
            preconditionFailure("Internal error: calling method before _details is initialized!")
        }
        return details
    }

    /// documentDeltaConnection.ts `initialize`: open the socket, send `connect_document` with
    /// `supportedFeatures.submit_signals_v2`, and wait for the matching success or error.
    public func initialize(url: URL, connectMessage: IConnect, timeoutMs: Int) async throws {
        request = connectMessage
        for name in [
            "op", "signal", "nack", "connect_document_success", "connect_document_error",
            "disconnect", "error", "connect_error",
        ] {
            await socket.on(name) { [weak self] event in await self?.receive(event) }
        }
        // documentDeltaConnection.ts: the handshake deadline is the socket timeout plus 2000 ms.
        deadline = Task {
            do { try await Task.sleep(for: .milliseconds(timeoutMs + 2000)) } catch { return }
            await disconnect(DriverError("orderingServiceHandshakeTimeout", .string("timeout")))
        }
        let document = connectMessage.id.description
        let tenant = connectMessage.tenantId.description
        do {
            try await socket.connect(
                url,
                options: .init(query: ["documentId": document, "tenantId": tenant], timeout: .milliseconds(timeoutMs)))
            var object = try connectMessage.json.asObject()
            var features = try (object["supportedFeatures"] ?? .object(.init())).asObject()
            features["submit_signals_v2"] = .bool(true)
            object["supportedFeatures"] = .object(features)
            guard !disposed else { throw DriverError("connect", .string("connection closed")) }
            let _: IConnected = try await withCheckedThrowingContinuation { pending in
                handshake = pending
                Task {
                    do {
                        try await socket.emit("connect_document", arguments: [.object(object)])
                    } catch {
                        await self.disconnect(error)
                    }
                }
            }
            startPingLoop()
        } catch {
            await disconnect(error)
            throw error
        }
    }

    private func receive(_ event: SocketEvent) async {
        guard !disposed else { return }
        do {
            switch event.name {
            case "connect_document_success", "connect_document_error":
                try handshakeResponse(event)
            case "op":
                guard event.arguments.count == 2 else { throw JSONDecodingError("invalid op arguments") }
                let messages = try event.arguments[1].asArray().map { try ISequencedDocumentMessage(json: $0) }
                continuation.yield(.op(documentId: try event.arguments[0].asString(), messages: messages))
            case "signal":
                guard let value = event.arguments.first else { throw JSONDecodingError("missing signal") }
                // documentDeltaConnection.ts earlySignalHandler: a signal or an array of signals.
                let batch: [JSONValue]
                if case .array(let values) = value { batch = values } else { batch = [value] }
                continuation.yield(.signal(try batch.map { try ISignalMessage(json: $0) }))
            case "nack":
                guard event.arguments.count == 2 else { throw JSONDecodingError("invalid nack arguments") }
                let nacks = try event.arguments[1].asArray().map { try INack(json: $0) }
                continuation.yield(.nack(documentId: try event.arguments[0].asString(), nacks: nacks))
            default:
                // disconnect, error, connect_error.
                throw DriverError(
                    event.name, event.arguments.first ?? .null,
                    canRetry: event.arguments.first != .string("Invalid namespace"))
            }
        } catch {
            await disconnect(error)
        }
    }

    /// Nonce filter, then mode/write-scope consistency (documentDeltaConnection.ts connect_document_success).
    private func handshakeResponse(_ event: SocketEvent) throws {
        guard let value = event.arguments.first else { throw JSONDecodingError("missing handshake") }
        let incoming = try value.asObject()["nonce"]
        let outgoing = request?.nonce.map { JSONValue.string($0) }
        if let incoming, let outgoing, incoming != outgoing { return }
        if event.name == "connect_document_error" { throw DriverError(event.name, value) }
        let details = try IConnected(json: value)
        let mode = details.mode
        let scopes = details.claims.scopes
        guard scopes.contains("doc:write") ? mode == request?.mode : mode != .write else {
            throw DriverError("modeMismatch", value, canRetry: false)
        }
        connected.withLock { $0 = details }
        deadline?.cancel()
        handshake?.resume(returning: details)
        handshake = nil
    }

    /// documentDeltaConnection.ts: the container's pong listener starts a volatile `ping` with an
    /// acknowledgement; each ack reports the latency and schedules the next ping a minute later.
    private func startPingLoop() {
        pingLoop = Task {
            while !Task.isCancelled {
                let start = Date().timeIntervalSince1970 * 1000
                let (acknowledged, ack) = AsyncStream<Void>.makeStream()
                do {
                    try await socket.emit("ping") { _ in
                        ack.yield()
                        ack.finish()
                    }
                } catch { return }
                var iterator = acknowledged.makeAsyncIterator()
                guard await iterator.next() != nil else { return }
                pong(Date().timeIntervalSince1970 * 1000 - start)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    private func pong(_ latency: Double) {
        guard !disposed else { return }
        continuation.yield(.pong(latency: latency))
    }

    /// documentDeltaConnection.ts `disconnect`: mark disposed, close the socket, then report the
    /// disconnect to the consumer. Repeated calls are ignored.
    private func disconnect(_ error: any Error) async {
        guard !disposed else { return }
        disposed = true
        deadline?.cancel()
        pingLoop?.cancel()
        handshake?.resume(throwing: error)
        handshake = nil
        await socket.close()
        continuation.yield(.disconnect(reason: error))
        continuation.finish()
    }

    public func submit(_ messages: [IDocumentMessage]) async throws {
        guard !disposed else { throw DriverError("submit", .string("disconnected")) }
        try await socket.emit(
            "submitOp",
            arguments: [.string(details.clientId), .array([.array(messages.map(\.json))])])
    }

    /// documentDeltaConnection.ts `submitSignal`: v2 signal objects when the service supports
    /// them; a targeted signal without v2 is a usage error.
    public func submitSignal(_ content: String, targetClientId: String?) async throws {
        guard !disposed else { throw DriverError("signal", .string("disconnected")) }
        let features = details.supportedFeatures
        let signals: JSONValue
        if features?["submit_signals_v2"] == .bool(true) {
            var object = JSObject<JSONValue>()
            object["content"] = .string(JSString(content))
            if let targetClientId { object["targetClientId"] = .string(JSString(targetClientId)) }
            signals = .array([.object(object)])
        } else {
            guard targetClientId == nil else {
                throw DriverError("signal", .string("target requires v2"), canRetry: false)
            }
            signals = .array([.array([.string(JSString(content))])])
        }
        try await socket.emit("submitSignal", arguments: [.string(details.clientId), signals])
    }

    /// documentDeltaConnection.ts `dispose()` without an error.
    public func dispose() async {
        await disconnect(DriverError("dispose", .string(JSString(Self.errorMessageForClientDisposeWithoutError))))
    }
}
