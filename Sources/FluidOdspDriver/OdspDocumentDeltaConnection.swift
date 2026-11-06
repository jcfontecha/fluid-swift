import FluidJS
import Foundation

/// odspDocumentDeltaConnection.ts SocketReference. The I/O owner supplies ordered enqueue/close
/// functions; all lifecycle transitions and listener delivery remain synchronous on its executor.
public final class SocketReference {
    public let key: String
    public private(set) var references = 1
    public var connected = false
    public private(set) var isPendingInitialConnection = true
    public private(set) var deletionDeadline: Double?
    private var closed = false
    private let send: (String, [JSONValue]) -> Void
    private let close: () -> Void
    private var listeners: [(UUID, (String?) throws -> Void)] = []
    public var onRemoveFromCache: () -> Void = {}
    public var disconnected: Bool { closed || (!connected && !isPendingInitialConnection) }
    public init(key: String, send: @escaping (String, [JSONValue]) -> Void, close: @escaping () -> Void) {
        self.key = key
        self.send = send
        self.close = close
    }
    public func addReference() throws {
        guard !disconnected else { throw JSONDecodingError("disconnected socket") }
        deletionDeadline = nil
        references += 1
    }
    public func removeSocketIoReference(now: Double) throws {
        guard references > 0 else { throw JSONDecodingError("0x09f") }
        references -= 1
        isPendingInitialConnection = false
        if disconnected { try closeSocket() }
        else if references == 0, deletionDeadline == nil { deletionDeadline = now + 2000 }
    }
    public func tick(now: Double) throws {
        if let deadline = deletionDeadline, now >= deadline {
            guard references == 0 else { throw JSONDecodingError("0x0a0") }
            try closeSocket()
        }
    }
    public func emit(_ name: String, _ arguments: [JSONValue]) throws {
        guard !closed else { throw JSONDecodingError("0x413") }
        send(name, arguments)
    }
    public func onDisconnect(_ listener: @escaping (String?) throws -> Void) -> UUID {
        let id = UUID()
        listeners.append((id, listener))
        return id
    }
    public func offDisconnect(_ id: UUID) { listeners.removeAll { $0.0 == id } }
    public func serverDisconnect(clientId: String?) throws {
        isPendingInitialConnection = false
        if let clientId {
            for (_, listener) in listeners { try listener(clientId) }
        } else { try closeSocket() }
    }
    public func closeSocket() throws {
        guard !closed else { return }
        deletionDeadline = nil
        onRemoveFromCache()
        closed = true
        // Block reuse and access before notifying. A reconnect in a callback must get a new socket.
        for (_, listener) in listeners { try listener(nil) }
        guard references == 0 else { throw JSONDecodingError("0x412") }
        close()
    }
}

/// Factory-owned registry avoids process-global mutable state across independent containers.
public final class OdspSocketCache {
    private var sockets: [String: SocketReference] = [:]
    public init() {}
    public func find(_ key: String) throws -> SocketReference? {
        guard let socket = sockets[key] else { return nil }
        if socket.disconnected {
            try socket.closeSocket()
            return nil
        }
        try socket.addReference()
        return socket
    }
    public func insert(_ socket: SocketReference) throws {
        guard sockets[socket.key] == nil else { throw JSONDecodingError("0x220") }
        sockets[socket.key] = socket
        socket.onRemoveFromCache = { [weak self, weak socket] in
            guard let socket else { return }
            self?.sockets.removeValue(forKey: socket.key)
        }
    }
}

/// odspDocumentDeltaConnection.ts. Multiplex routing and synchronous teardown, with Socket.IO
/// writes queued by the I/O adapter supplied to SocketReference.
public final class OdspDocumentDeltaConnection {
    public static let socketTimeoutMs = 60000
    public static let handshakeTimeoutMs = 62000
    public private(set) var disposed = false
    public let documentId: String
    public let clientId: String
    public var supportedGetOps = true
    public var supportedFlushOps = false
    public var onDisconnect: () -> Void = {}
    public var onOps: ([JSONValue]) -> Void = { _ in }
    public var onSignal: (JSONValue) -> Void = { _ in }
    public var onNack: (JSONValue) -> Void = { _ in }
    private let reference: SocketReference
    private let noncePrefix: String
    private var counter = 0
    private var listenerId: UUID?
    private var requests: [(String, Int, Int)] = []
    private var flushNonce: String?
    public var onFlush: (JSONValue) -> Void = { _ in }
    public init(reference: SocketReference, documentId: String, clientId: String, noncePrefix: String) {
        self.reference = reference
        self.documentId = documentId
        self.clientId = clientId
        self.noncePrefix = noncePrefix
        listenerId = reference.onDisconnect { [weak self] target in
            guard let self, target == nil || target == self.clientId else { return }
            try self.dispose()
        }
    }
    public static func enableMultiplexing(_ url: String) throws -> Bool {
        guard let components = URLComponents(string: url) else { throw JSONDecodingError("invalid socket URL") }
        return !(components.queryItems ?? []).contains { $0.name == "documentId" || $0.name == "tenantId" }
    }
    public static func socketKey(url: String, tenantId: String, documentId: String, prefix: String? = nil) throws -> String {
        let key = prefix.flatMap { $0.isEmpty ? nil : $0 + "," } ?? ""
        return key + url + (try enableMultiplexing(url) ? "" : "," + tenantId + "," + documentId)
    }
    public func requestOps(from: Int, to: Int) throws {
        guard !reference.disconnected else { throw JSONDecodingError("0x413") }
        guard to > from else { throw JSONDecodingError("0x272") }
        guard supportedGetOps else { return }
        counter += 1
        let nonce = noncePrefix + String(counter)
        if requests.count >= 5 { requests.removeFirst() }
        requests.append((nonce, from, to))
        var body = JSObject<JSONValue>()
        body["nonce"] = .string(JSString(nonce))
        body["from"] = .number(Double(from))
        body["to"] = .number(Double(to - 1))
        try reference.emit("get_ops", [.string(JSString(clientId)), .object(body)])
    }
    public func flush() throws {
        guard !reference.disconnected else { throw JSONDecodingError("0x414") }
        guard supportedFlushOps else { throw JSONDecodingError("flush() API is not supported by PUSH, required for single-commit summaries") }
        counter += 1
        let nonce = noncePrefix + String(counter)
        flushNonce = nonce
        var body = JSObject<JSONValue>()
        body["nonce"] = .string(JSString(nonce))
        try reference.emit("flush_ops", [.string(JSString(clientId)), .object(body)])
    }
    public func submit(_ messages: [JSONValue]) throws {
        guard !disposed, reference.connected else { return }
        try reference.emit("submitOp", [.string(JSString(clientId)), .array([.array(messages)])])
    }
    public func submitSignal(_ signals: [JSONValue]) throws {
        guard !disposed, reference.connected else { return }
        try reference.emit("submitSignal", [.string(JSString(clientId)), .array(signals)])
    }
    public func receive(name: String, arguments: [JSONValue], multiplex: Bool = true) throws {
        guard !disposed else { return }
        switch name {
        case "op":
            guard arguments.count >= 2 else { throw JSONDecodingError("missing op arguments") }
            if !multiplex || arguments[0] == .string(JSString(documentId)) { onOps(try arguments[1].asArray()) }
        case "signal":
            guard let message = arguments.first else { throw JSONDecodingError("missing signal") }
            if !multiplex { onSignal(message) }
            else {
                guard arguments.count >= 2 else { throw JSONDecodingError("0xa65") }
                guard arguments[1] == .string(JSString(documentId)) else { return }
                let messages: [JSONValue]
                if case .array(let values) = message { messages = values } else { messages = [message] }
                let filtered = try messages.filter {
                    let target = try $0.asObject()["targetClientId"]
                    return target == nil || target == .string("") || target == .string(JSString(clientId))
                }
                if filtered.count == 1, let first = filtered.first { onSignal(first) }
                else if !filtered.isEmpty { onSignal(.array(filtered)) }
            }
        case "get_ops_response":
            guard let response = arguments.first else { throw JSONDecodingError("missing get_ops response") }
            let nonce = try response.member("nonce").asString().description
            guard nonce.hasPrefix(noncePrefix) || requests.contains(where: { $0.0 == nonce }) else { return }
            requests.removeAll { $0.0 == nonce }
            if let messages = try response.asObject()["messages"]?.asArray(), !messages.isEmpty { onOps(messages) }
        case "flush_ops_response":
            guard let response = arguments.first else { throw JSONDecodingError("missing flush response") }
            if try response.member("nonce").asString().description == flushNonce {
                flushNonce = nil
                onFlush(response)
            }
        case "nack":
            guard arguments.count >= 2 else { throw JSONDecodingError("missing nack arguments") }
            let target = try arguments[0].asString().description
            if target.isEmpty || target == documentId || target == clientId { onNack(arguments[1]) }
        default: break
        }
    }
    public func dispose(now: Double = 0) throws {
        guard !disposed else { return }
        disposed = true
        if let listenerId { reference.offDisconnect(listenerId) }
        if !reference.disconnected { try reference.emit("disconnect_document", [.string(JSString(clientId)), .string(JSString(documentId))]) }
        requests.removeAll()
        flushNonce = nil
        try reference.removeSocketIoReference(now: now)
        onDisconnect()
    }
}
