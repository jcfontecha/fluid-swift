import Foundation
import FluidJS

public struct SocketIOOptions: Sendable {
    public var query: [String: String]
    public var path: String
    public var timeout: Duration
    public init(query: [String: String] = [:], path: String = "/socket.io/", timeout: Duration = .seconds(20)) {
        self.query = query
        self.path = path
        self.timeout = timeout
    }

    public func websocketURL(_ url: URL) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SocketIOError.protocolError("invalid URL")
        }
        switch parts.scheme {
        case "http", "ws": parts.scheme = "ws"
        case "https", "wss": parts.scheme = "wss"
        default: throw SocketIOError.protocolError("invalid URL scheme")
        }
        parts.path = (path.hasPrefix("/") ? path : "/" + path)
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        var params = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        params.merge(query) { _, new in new }
        params["EIO"] = "4"
        params["transport"] = "websocket"
        parts.queryItems = params.keys.sorted().map { URLQueryItem(name: $0, value: params[$0]) }
        guard let result = parts.url else { throw SocketIOError.protocolError("invalid URL") }
        return result
    }
}

public struct SocketEvent: Sendable {
    public let name: String
    public let arguments: [JSONValue]
    public let acknowledgementID: Int?
}

/// Socket.IO 5 / Engine.IO 4 client: websocket transport, default namespace, JSON packets only —
/// the subset the 3.11.0 routerlicious driver uses (`routerlicious-driver/src/documentDeltaConnection.ts:38-48`:
/// `transports: ["websocket"]`, `reconnection: false`). There is no internal reconnection or polling
/// fallback: instances are single-use, and the Fluid connection manager creates a new client to reconnect.
///
/// Register handlers before `connect`, then emit (e.g. `connect_document`); `emit` before `connect`
/// completes throws. A single delivery task awaits each handler before delivering the next event, in
/// arrival order. Pass a closure that hops to the container actor; no detached per-event Tasks may
/// reorder that actor's inbox. Handlers may emit/ack/close, but must not wait for a future inbound event.
public actor SocketIOClient {
    public typealias Handler = @Sendable (SocketEvent) async -> Void
    private struct Delivery: Sendable { let event: SocketEvent; let handlers: [Handler] }
    private let deliveries: AsyncStream<Delivery>
    private let deliveryContinuation: AsyncStream<Delivery>.Continuation
    private var deliveryTask: Task<Void, Never>?
    private var handlers: [String: [(UUID, Handler)]] = [:]
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reader: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var writer: Task<Void, Error>?
    private var connecting: CheckedContinuation<Void, Error>?
    private var connected = false
    private var started = false
    private var opened = false
    private var heartbeat: Duration = .zero
    private var nextID = 0
    private var acknowledgements: [Int: Handler] = [:]

    public init() {
        (deliveries, deliveryContinuation) = AsyncStream.makeStream()
    }

    @discardableResult
    public func on(_ name: String, handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers[name, default: []].append((id, handler))
        return id
    }

    public var isConnected: Bool { connected }

    public func off(_ name: String, id: UUID) { handlers[name]?.removeAll { $0.0 == id } }

    public func connect(_ url: URL, options: SocketIOOptions = .init()) async throws {
        guard !started else { throw SocketIOError.protocolError("client is single-use") }
        try Task.checkCancellation()
        let endpoint = try options.websocketURL(url)
        started = true
        let deliveries = self.deliveries
        deliveryTask = Task {
            for await delivery in deliveries {
                for handler in delivery.handlers { await handler(delivery.event) }
            }
        }
        let session = URLSession(configuration: .ephemeral)
        self.session = session
        let socket = session.webSocketTask(with: endpoint)
        // URLSession's 1 MiB default would reject a large connect_document_success (initialMessages
        // carries catch-up ops); the JS client imposes no inbound frame limit.
        socket.maximumMessageSize = Int.max
        self.socket = socket
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                connecting = continuation
                socket.resume()
                armTimeout(options.timeout, reason: "connection timeout")
                reader = Task { await self.receive(socket) }
            }
        } onCancel: {
            Task { await self.finish("connection cancelled") }
        }
    }

    public func emit(_ name: String, arguments: [JSONValue] = [], ack: Handler? = nil) async throws {
        guard connected else { throw SocketIOError.closed("not connected") }
        let id: Int?
        if let ack {
            id = nextID
            acknowledgements[nextID] = ack
            nextID += 1
        } else { id = nil }
        do {
            try await send(.message(.init(.event, id: id, data: .array([.string(JSString(name))] + arguments))))
        } catch {
            if let id { acknowledgements[id] = nil }
            throw error
        }
    }

    public func acknowledge(_ id: Int, arguments: [JSONValue] = []) async throws {
        guard connected else { throw SocketIOError.closed("not connected") }
        try await send(.message(.init(.ack, id: id, data: .array(arguments))))
    }

    public func close() async {
        if connected { try? await send(.message(.init(.disconnect))) }
        await finish("io client disconnect")
    }

    private func send(_ packet: EnginePacket) async throws {
        guard let socket else { throw SocketIOError.closed("transport closed") }
        let text = try packet.encode()
        let previous = writer
        let pending = Task {
            try await previous?.value
            try await socket.send(.string(text))
        }
        writer = pending
        try await pending.value
    }

    private func receive(_ transport: URLSessionWebSocketTask) async {
        do {
            while socket != nil {
                let frame = try await transport.receive()
                guard case .string(let text) = frame else { throw SocketIOError.protocolError("binary not used by Fluid") }
                try await process(EnginePacket.decode(text))
            }
        } catch {
            if socket != nil { await finish(String(describing: error)) }
        }
    }

    private func process(_ packet: EnginePacket) async throws {
        switch packet {
        case .open(let value):
            guard !opened else { throw SocketIOError.protocolError("duplicate handshake") }
            _ = try value.member("sid").asString()
            let interval = try value.member("pingInterval").asNumber()
            let timeout = try value.member("pingTimeout").asNumber()
            guard interval.isFinite, timeout.isFinite, interval > 0, timeout > 0,
                  interval + timeout < 1e12 else { throw SocketIOError.protocolError("invalid heartbeat") }
            opened = true
            heartbeat = .milliseconds(interval + timeout)
            // Keep the connection deadline until Socket.IO CONNECT arrives.
            try await send(.message(.init(.connect)))
        case .ping(let payload):
            guard opened else { throw SocketIOError.protocolError("ping before handshake") }
            if connected { armTimeout(heartbeat, reason: "ping timeout") }
            try await send(.pong(payload))
        case .message(let message):
            guard opened else { throw SocketIOError.protocolError("message before handshake") }
            switch message.kind {
            case .connect:
                guard !connected, let data = message.data else { throw SocketIOError.protocolError("invalid connect") }
                _ = try data.member("sid").asString()
                connected = true
                armTimeout(heartbeat, reason: "ping timeout")
                connecting?.resume()
                connecting = nil
                deliver("connect", [])
            case .connectError:
                deliver("connect_error", [message.data!])
                await finish("connect error", reportConnectError: false)
            case .disconnect: await finish("io server disconnect")
            case .event:
                guard connected else { throw SocketIOError.protocolError("event before connect") }
                let args = try message.data!.asArray()
                deliver(try args[0].asString().description, Array(args.dropFirst()), id: message.id)
            case .ack:
                if let id = message.id, let handler = acknowledgements.removeValue(forKey: id) {
                    deliveryContinuation.yield(Delivery(event: SocketEvent(name: "ack", arguments: try message.data!.asArray(), acknowledgementID: id), handlers: [handler]))
                }
            }
        case .close: await finish("transport close")
        case .pong, .noop: break
        }
    }

    private func armTimeout(_ delay: Duration, reason: String) {
        timer?.cancel()
        timer = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            await self.finish(reason)
        }
    }

    private func deliver(_ name: String, _ args: [JSONValue], id: Int? = nil) {
        let event = SocketEvent(name: name, arguments: args, acknowledgementID: id)
        deliveryContinuation.yield(Delivery(event: event, handlers: (handlers[name] ?? []).map { $0.1 }))
    }

    private func finish(_ reason: String, reportConnectError: Bool = true) async {
        guard socket != nil else { return }
        let wasConnected = connected
        connected = false
        timer?.cancel()
        reader?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        writer?.cancel()
        writer = nil
        acknowledgements.removeAll()
        connecting?.resume(throwing: SocketIOError.closed(reason))
        connecting = nil
        if wasConnected { deliver("disconnect", [.string(JSString(reason))]) }
        else if reportConnectError { deliver("connect_error", [.string(JSString(reason))]) }
        deliveryContinuation.finish()
    }
}
