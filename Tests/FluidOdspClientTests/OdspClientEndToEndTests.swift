import FluidJS
import FluidSequence
import FluidStatic
import Foundation
import Synchronization
import Testing

@testable import FluidOdspClient

/// The repository's harness/ directory, which holds the local ODSP service and its node_modules.
private let harness = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "harness")

/// The local ODSP service's fake tokens (harness/src/odsp-service/tokens.ts).
private struct LocalTokenProvider: IOdspTokenProvider {
    let user: String

    func fetchWebsocketToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
        TokenResponse(token: "push:\(user)")
    }

    func fetchStorageToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
        TokenResponse(token: "storage:\(user)")
    }
}

private struct Timeout: Error, CustomStringConvertible {
    let description: String
}

/// Polls `poll` on the main actor until it returns a value. Waiting on the other processes is
/// what needs the polling; each suspension also lets the main-owned container run.
@MainActor
private func until<T>(_ label: String, timeout: Duration = .seconds(60), _ poll: () throws -> T?) async throws -> T {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let value = try poll() {
            return value
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw Timeout(description: "Timeout: \(label)")
}

/// Complete stdout lines of a child process, collected on Foundation's reader thread.
private final class Lines: Sendable {
    private let state = Mutex<(partial: String, lines: [String])>(("", []))

    func append(_ data: Data) {
        state.withLock { state in
            state.partial += String(decoding: data, as: UTF8.self)
            while let newline = state.partial.firstIndex(of: "\n") {
                state.lines.append(String(state.partial[..<newline]))
                state.partial = String(state.partial[state.partial.index(after: newline)...])
            }
        }
    }

    func take() -> String? {
        state.withLock { state in
            state.lines.isEmpty ? nil : state.lines.removeFirst()
        }
    }
}

/// A `node` child process in harness/, spoken to in lines. Its stderr goes to the test's stderr.
@MainActor
private final class NodeProcess {
    private let name: String
    private let process = Process()
    private let input = Pipe()
    private let output = Lines()

    init(_ name: String, _ arguments: [String]) throws {
        self.name = name
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node"] + arguments
        process.currentDirectoryURL = harness
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        stdout.fileHandleForReading.readabilityHandler = { [output] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                output.append(data)
            }
        }
        try process.run()
    }

    func send(_ line: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func nextLine() async throws -> String {
        try await until("a line from \(name)") { output.take() }
    }

    /// Asks the process to exit (stdin EOF, then SIGTERM) and waits for it.
    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
    }
}

/// M4-style live co-editing between the real TS `@fluidframework/odsp-client` 3.11.0 and the
/// Swift `OdspClient`, on the local ODSP service (harness/src/odsp-service).
@Suite(.serialized) struct OdspClientEndToEndTests {
    @MainActor @Test func coEditsATypeScriptCreatedContainer() async throws {
        let server = try NodeProcess("odsp-service", ["--import", "tsx", "src/odsp-service/main.ts", "--port", "7096"])
        defer { server.stop() }
        // main.ts prints its connection values as one indented JSON object.
        var info: [String] = []
        while info.last != "}" {
            info.append(try await server.nextLine())
        }
        let connection = try JSON.parse(info.joined(separator: "\n"))
        let siteUrl = try connection.member("siteUrl").asString().description
        let driveId = try connection.member("driveId").asString().description

        let script = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "ts-text-client.mjs"), encoding: .utf8)
        let ts = try NodeProcess("ts client", ["--input-type=module", "--eval", script, siteUrl, driveId, "ts"])
        defer { ts.stop() }
        let itemId = try JSON.parse(await ts.nextLine()).member("itemId").asString().description

        let client = OdspClient(properties: OdspClientProps(connection: OdspConnectionConfig(
            tokenProvider: LocalTokenProvider(user: "swift"), siteUrl: siteUrl, driveId: driveId, filePath: "")))
        let (container, services) = try await client.getContainer(
            itemId, containerSchema: ContainerSchema(initialObjects: ["text": SharedString.self]),
            isolation: MainActor.shared)
        let text = try #require(container.initialObjects["text"] as? SharedString)
        var remoteDeltas = 0
        text.sequenceDelta.on { event in
            if !event.isLocal {
                remoteDeltas += 1
            }
        }
        try await until("Swift connected") { container.connectionState == .connected ? () : nil }
        // The TS edit was made after attach, so it reaches Swift as an op, not in the snapshot.
        #expect(text.getText() == "TS: hello")

        // Concurrent edits: neither client has seen the other's when it makes its own.
        try text.insertText(text.getLength(), " and Swift")
        try ts.send(#"{"op":"insert","pos":0,"text":"[ts] "}"#)
        _ = try await ts.nextLine()

        // Converged: the same text on both clients, and neither has unacknowledged ops.
        let deadline = ContinuousClock.now + .seconds(60)
        while true {
            try ts.send(#"{"op":"view"}"#)
            let tsView = try JSON.parse(await ts.nextLine())
            if try tsView.member("text").asString() == text.getText(), try tsView.member("dirty") == .bool(false), !container.isDirty {
                break
            }
            guard ContinuousClock.now < deadline else {
                throw Timeout(description: "Timeout: convergence (ts \(tsView), swift \(text.getText()))")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(text.getText() == "[ts] TS: hello and Swift")
        #expect(remoteDeltas >= 1)

        let members = try services.audience.getMembers()
        #expect(Set(members.keys) == ["ts", "swift"])
        let myself = try #require(try services.audience.getMyself())
        #expect(myself.member.name == "swift")
        #expect(myself.member.email == "swift@local-odsp.test")

        services.dispose()
        container.dispose()
        #expect(container.disposed)
    }
}
