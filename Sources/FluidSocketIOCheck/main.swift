import Foundation
import FluidJS
import FluidSocketIO

actor Inbox {
    var events: [SocketEvent] = []
    func add(_ event: SocketEvent) { events.append(event) }
    func take(_ name: String) -> SocketEvent? {
        guard let i = events.firstIndex(where: { $0.name == name }) else { return nil }
        return events.remove(at: i)
    }
    func wait(_ name: String) async throws -> SocketEvent {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let event = take(name) { return event }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SocketIOError.closed("waiting for \(name)")
    }
}

@main struct Check {
    static func main() async throws {
        let inbox = Inbox()
        let client = SocketIOClient()
        for name in ["server_event", "observed", "ack", "disconnect", "server_ack_ok", "heartbeat_count"] {
            await client.on(name) { await inbox.add($0) }
        }
        await client.on("ordered") { event in
            try? await Task.sleep(for: .milliseconds(2))
            await inbox.add(event)
        }
        await client.on("needs_ack") { event in
            if let id = event.acknowledgementID { try? await client.acknowledge(id, arguments: event.arguments) }
        }
        try await client.connect(URL(string: "http://127.0.0.1:7172")!, options: .init(query: ["tenantId": "tenant & 💧", "documentId": "doc/1"], path: "/fluid-test"))
        _ = try await inbox.wait("server_event")
        _ = try await inbox.wait("server_ack_ok")
        for index in 0..<20 {
            let event = try await inbox.wait("ordered")
            guard event.arguments == [.number(Double(index))] else { throw SocketIOError.protocolError("event order") }
        }
        try await client.emit("plain", arguments: [try JSON.parse(#"{"hello":"💧","surrogate":"\ud800"}"#)])
        _ = try await inbox.wait("observed")
        try await client.emit("with_ack", arguments: [.number(42)]) { await inbox.add($0) }
        let ack = try await inbox.wait("ack")
        guard ack.arguments == [.number(42), .string("ok")] else { throw SocketIOError.protocolError("wrong ack") }
        // Server only sends this after receiving at least three actual Engine.IO pongs.
        _ = try await inbox.wait("heartbeat_count")
        try await client.emit("disconnect_me")
        let disconnected = try await inbox.wait("disconnect")
        guard disconnected.arguments == [.string("io server disconnect")] else { throw SocketIOError.protocolError("disconnect reason") }
        await client.close()
        let second = SocketIOClient()
        try await second.connect(URL(string: "http://127.0.0.1:7172")!, options: .init(path: "/fluid-test"))
        await second.close()

        let rejected = SocketIOClient()
        await rejected.on("connect_error") { await inbox.add($0) }
        do {
            try await rejected.connect(URL(string: "http://127.0.0.1:7172")!, options: .init(query: ["reject": "yes"], path: "/fluid-test"))
            throw SocketIOError.protocolError("expected rejection")
        } catch SocketIOError.closed { }
        let rejection = try await inbox.wait("connect_error")
        guard try rejection.arguments[0].member("message") == .string("denied") else { throw SocketIOError.protocolError("connect error data") }

        let message = try JSON.parse(String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))
        let tiny = SocketIOClient()
        for name in ["connect_document_success", "connect_document_error"] {
            await tiny.on(name) { await inbox.add($0) }
        }
        try await tiny.connect(URL(string: "http://127.0.0.1:7072")!, options: .init(query: ["tenantId": "tinylicious", "documentId": try message.member("id").asString().description]))
        try await tiny.emit("connect_document", arguments: [message])
        let success = try await inbox.wait("connect_document_success")
        guard success.arguments.count == 1 else { throw SocketIOError.protocolError("connect response arity") }
        let payload = success.arguments[0]
        guard try payload.member("mode") == .string("write"),
              try payload.member("version") == .string("^0.4.0"),
              try payload.member("supportedFeatures").member("submit_signals_v2") == .bool(true) else {
            throw SocketIOError.protocolError("connect response")
        }
        print("connect_document_success=" + JSON.stringify(payload))
        await tiny.close()
        print("socketio-check passed")
    }
}
