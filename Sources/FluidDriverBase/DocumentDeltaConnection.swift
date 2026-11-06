import Foundation
import FluidJS
import FluidSocketIO

public struct DriverError: Error, Sendable, CustomStringConvertible {
    public let scenario: String
    public let payload: JSONValue
    public let canRetry: Bool
    public let errorType: String
    public let statusCode: Int?
    public let retryAfterSeconds: Double?
    public var description: String { "\(scenario): \(JSON.stringify(payload))" }
    public init(_ scenario: String, _ payload: JSONValue, canRetry: Bool = true) {
        self.scenario = scenario; self.payload = payload
        var code: Int?
        var retry: Double?
        var internalCode: JSONValue?
        if case .object(let fields) = payload {
            if case .number(let number) = fields["code"] { code = Int(exactly: number) }
            if case .number(let milliseconds) = fields["retryAfterMs"] { retry = milliseconds / 1000 }
            internalCode = fields["internalErrorCode"]
        }
        statusCode = code
        var retryable = canRetry
        var type = "genericNetworkError"
        if canRetry, let code {
            switch code {
            case 401, 403: type = "authorizationError"; retryable = false
            case 404: type = "fileNotFoundOrAccessDeniedError"; retryable = false
            case 429, 500, 502: retryable = true
            case 503 where internalCode == .string("ClusterDraining"):
                type = "clusterDrainingError"; retryable = true; retry = retry ?? 660
            default: retryable = retry != nil
            }
        }
        self.canRetry = retryable; errorType = type; retryAfterSeconds = retry
    }
}

/// Single-use Fluid handshake. Events remain captured until the consumer drains them, including
/// events received between success and the consumer's installation. No per-event tasks reorder I/O.
public actor DocumentDeltaConnection {
    public nonisolated let events: AsyncThrowingStream<SocketEvent, Error>
    private let continuation: AsyncThrowingStream<SocketEvent, Error>.Continuation
    private let socket = SocketIOClient()
    private var handshake: CheckedContinuation<JSONValue, Error>?
    private var request: JSONValue = .null
    private var details: JSONValue?
    private var deadline: Task<Void, Never>?
    private var closed = false

    public init() { (events, continuation) = AsyncThrowingStream.makeStream() }

    public func connect(url: URL, message: JSONValue) async throws -> JSONValue {
        request = message
        for name in ["op", "signal", "nack", "connect_document_success", "connect_document_error", "disconnect", "error", "connect_error"] {
            await socket.on(name) { [weak self] event in await self?.receive(event) }
        }
        deadline = Task {
            do { try await Task.sleep(for: .seconds(22)) } catch { return }
            await fail(DriverError("orderingServiceHandshakeTimeout", .string("timeout")))
        }
        let document = try message.member("id").asString().description
        let tenant = try message.member("tenantId").asString().description
        do {
            try await socket.connect(url, options: .init(query: ["documentId": document, "tenantId": tenant]))
            var object = try message.asObject()
            var features = try (object["supportedFeatures"] ?? .object(.init())).asObject()
            features["submit_signals_v2"] = .bool(true)
            object["supportedFeatures"] = .object(features)
            guard !closed else { throw DriverError("connect", .string("connection closed")) }
            return try await withCheckedThrowingContinuation { pending in
                handshake = pending
                Task {
                    do { try await socket.emit("connect_document", arguments: [.object(object)]) }
                    catch { await self.fail(error) }
                }
            }
        } catch { await fail(error); throw error }
    }

    private func receive(_ event: SocketEvent) async {
        guard !closed else { return }
        switch event.name {
        case "connect_document_success", "connect_document_error":
            do {
                guard let value = event.arguments.first else { throw JSONDecodingError("missing handshake") }
                let incoming = try value.asObject()["nonce"]
                let outgoing = try request.asObject()["nonce"]
                if let incoming, let outgoing, incoming != outgoing { return }
                if event.name == "connect_document_error" { throw DriverError(event.name, value) }
                let mode = try value.member("mode")
                let scopes = try value.member("claims").member("scopes").asArray()
                guard scopes.contains(.string("doc:write")) ? mode == (try request.member("mode")) : mode != .string("write") else {
                    throw DriverError("modeMismatch", value, canRetry: false)
                }
                details = value
                deadline?.cancel()
                handshake?.resume(returning: value); handshake = nil
            } catch { await fail(error) }
        case "disconnect", "error", "connect_error":
            await fail(DriverError(event.name, event.arguments.first ?? .null, canRetry: event.arguments.first != .string("Invalid namespace")))
        default: continuation.yield(event)
        }
    }

    private func fail(_ error: Error) async {
        guard !closed else { return }
        closed = true; deadline?.cancel()
        handshake?.resume(throwing: error); handshake = nil
        continuation.finish(throwing: error)
        await socket.close()
    }

    public func submit(_ messages: [JSONValue]) async throws {
        guard let details, !closed else { throw DriverError("submit", .string("disconnected")) }
        try await socket.emit("submitOp", arguments: [details.member("clientId"), .array([.array(messages)])])
    }
    public func submitSignal(_ content: String, target: String? = nil) async throws {
        guard let details, !closed else { throw DriverError("signal", .string("disconnected")) }
        let features = try details.asObject()["supportedFeatures"]?.asObject()
        let signals: JSONValue
        if features?["submit_signals_v2"] == .bool(true) {
            var object = JSObject<JSONValue>(); object["content"] = .string(JSString(content))
            if let target { object["targetClientId"] = .string(JSString(target)) }
            signals = .array([.object(object)])
        } else {
            guard target == nil else { throw DriverError("signal", .string("target requires v2"), canRetry: false) }
            signals = .array([.array([.string(JSString(content))])])
        }
        try await socket.emit("submitSignal", arguments: [details.member("clientId"), signals])
    }
    public func disconnect() async { await fail(DriverError("dispose", .string("Client closing delta connection"))) }
}
