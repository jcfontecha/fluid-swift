import FluidDriverDefinitions
import FluidJS
import FluidSocketIO
import Foundation

/// Ports driver-base/src/documentDeltaConnection.ts. Single-use Fluid handshake. Events remain captured until the consumer drains them, including
/// events received between success and the consumer's installation. No per-event tasks reorder I/O.
public actor DocumentDeltaConnection {
    public nonisolated let events: AsyncThrowingStream<SocketEvent, Error>
    private let continuation: AsyncThrowingStream<SocketEvent, Error>.Continuation
    private let socket = SocketIOClient()
    private var handshake: CheckedContinuation<IConnected, Error>?
    private var request: IConnect?
    private var details: IConnected?
    private var deadline: Task<Void, Never>?
    private var closed = false

    public init() { (events, continuation) = AsyncThrowingStream.makeStream() }

    public func connect(url: URL, message: IConnect) async throws -> IConnected {
        request = message
        for name in [
            "op", "signal", "nack", "connect_document_success", "connect_document_error",
            "disconnect",
            "error", "connect_error",
        ] {
            await socket.on(name) { [weak self] event in await self?.receive(event) }
        }
        deadline = Task {
            do { try await Task.sleep(for: .seconds(22)) } catch { return }
            await fail(DriverError("orderingServiceHandshakeTimeout", .string("timeout")))
        }
        let document = message.id.description
        let tenant = message.tenantId.description
        do {
            try await socket.connect(
                url, options: .init(query: ["documentId": document, "tenantId": tenant]))
            var object = try message.json.asObject()
            var features = try (object["supportedFeatures"] ?? .object(.init())).asObject()
            features["submit_signals_v2"] = .bool(true)
            object["supportedFeatures"] = .object(features)
            guard !closed else { throw DriverError("connect", .string("connection closed")) }
            return try await withCheckedThrowingContinuation { pending in
                handshake = pending
                Task {
                    do {
                        try await socket.emit("connect_document", arguments: [.object(object)])
                    } catch {
                        await self.fail(error)
                    }
                }
            }
        } catch {
            await fail(error)
            throw error
        }
    }

    private func receive(_ event: SocketEvent) async {
        guard !closed else { return }
        switch event.name {
        case "connect_document_success", "connect_document_error":
            do {
                guard let value = event.arguments.first else {
                    throw JSONDecodingError("missing handshake")
                }
                let incoming = try value.asObject()["nonce"]
                let outgoing = request?.nonce.map { JSONValue.string($0) }
                if let incoming, let outgoing, incoming != outgoing { return }
                if event.name == "connect_document_error" { throw DriverError(event.name, value) }
                let connected = try IConnected(json: value)
                let mode = connected.mode
                let scopes = connected.claims.scopes
                guard scopes.contains("doc:write") ? mode == request?.mode : mode != .write else {
                    throw DriverError("modeMismatch", value, canRetry: false)
                }
                details = connected
                deadline?.cancel()
                handshake?.resume(returning: connected)
                handshake = nil
            } catch { await fail(error) }
        case "disconnect", "error", "connect_error":
            await fail(
                DriverError(
                    event.name, event.arguments.first ?? .null,
                    canRetry: event.arguments.first != .string("Invalid namespace")))
        default: continuation.yield(event)
        }
    }

    private func fail(_ error: Error) async {
        guard !closed else { return }
        closed = true
        deadline?.cancel()
        handshake?.resume(throwing: error)
        handshake = nil
        continuation.finish(throwing: error)
        await socket.close()
    }

    public func submit(_ messages: [IDocumentMessage]) async throws {
        guard let details, !closed else { throw DriverError("submit", .string("disconnected")) }
        try await socket.emit(
            "submitOp",
            arguments: [.string(details.clientId), .array([.array(messages.map(\.json))])])
    }
    public func submitSignal(_ content: String, target: String? = nil) async throws {
        guard let details, !closed else { throw DriverError("signal", .string("disconnected")) }
        let features = details.supportedFeatures
        let signals: JSONValue
        if features?["submit_signals_v2"] == .bool(true) {
            var object = JSObject<JSONValue>()
            object["content"] = .string(JSString(content))
            if let target { object["targetClientId"] = .string(JSString(target)) }
            signals = .array([.object(object)])
        } else {
            guard target == nil else {
                throw DriverError("signal", .string("target requires v2"), canRetry: false)
            }
            signals = .array([.array([.string(JSString(content))])])
        }
        try await socket.emit("submitSignal", arguments: [.string(details.clientId), signals])
    }
    public func disconnect() async {
        await fail(DriverError("dispose", .string("Client closing delta connection")))
    }
}
