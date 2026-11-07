import Fluid
import FluidJS
import Foundation
import Synchronization
import Testing

/// The repository's harness/ directory, which holds the local services and their node_modules.
private let harness = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "harness")

/// The local ODSP service's fake tokens (harness/src/odsp-service/tokens.ts).
private struct LocalTokens: OdspTokenProvider {
    func fetchStorageToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
        TokenResponse(token: "storage:swift")
    }

    func fetchWebsocketToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
        TokenResponse(token: "push:swift")
    }
}

private struct Timeout: Error, CustomStringConvertible {
    let description: String
}

/// Polls `poll` on the main actor until it returns a value. Each suspension also lets the
/// main-owned container run.
@MainActor
private func until<T>(_ label: String, timeout: Duration = .seconds(60), _ poll: () async throws -> T?) async throws -> T {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let value = try await poll() {
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

/// A `node` child process, spoken to in lines. Its stderr goes to the test's stderr.
@MainActor
private final class NodeProcess {
    private let name: String
    private let process = Process()
    private let input = Pipe()
    private let output = Lines()

    init(_ name: String, _ arguments: [String], directory: URL = harness, environment: [String: String] = [:]) throws {
        self.name = name
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node"] + arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
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

    func request(_ line: String) async throws -> JSONValue {
        try send(line)
        return try JSON.parse(await nextLine())
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

/// A tinylicious 7.0.1 server on `port`, storing into a fresh temporary directory.
@MainActor
private final class Tinylicious {
    private let process: NodeProcess
    private let directory: URL

    init(port: Int) async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "fluid-create-tinylicious-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process = try NodeProcess(
            "tinylicious",
            [harness.appending(path: "node_modules/tinylicious/dist/index.js").path],
            directory: directory,
            environment: ["PORT": "\(port)", "storage": directory.appending(path: "storage").path])
        let endpoint = URL(string: "http://localhost:\(port)")!
        try await until("tinylicious \(port) startup") { () async throws -> Void? in
            let response = try? await URLSession.shared.data(from: endpoint).1 as? HTTPURLResponse
            return response?.statusCode == 200 ? () : nil
        }
    }

    func stop() {
        process.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// ts-load-client.mjs, the real TS client that loads the Swift-created container.
private let loadScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "ts-load-client.mjs")

/// Creates a container with `Fluid`, edits it while detached, attaches it, then has the real TS
/// client `loadTS` load it by the returned id. Both see the detached edits, then co-edit.
@MainActor
private func createAttachAndCoEdit(
    create: () async -> FluidContainer<TextAndMap>,
    loadTS: (String) throws -> NodeProcess
) async throws {
    let container = await create()
    #expect(container.status.name == "detached")
    let text = container.initialObjects.text
    let map = container.initialObjects.map
    text.insert("Swift: detached", at: 0)
    map["origin"] = "swift"

    let recorder = StatusRecorder(container)
    let id = try await container.attach()
    #expect(!id.isEmpty)
    // fluidContainer.ts attach: an attached container cannot attach again, and stays open.
    do {
        _ = try await container.attach()
        Issue.record("attach on an attached container must throw")
    } catch {}
    try await until("Swift connected") { container.status.name == "connected" ? () : nil }
    #expect(recorder.seen.first == "attaching")
    #expect(!recorder.seen.contains("closed"))

    let ts = try loadTS(id)
    defer { ts.stop() }
    // The detached edits are in the attach summary, so a fresh TS load sees them.
    let loaded = try JSON.parse(await ts.nextLine())
    #expect(try loaded.member("text").asString() == "Swift: detached")
    #expect(try loaded.member("map").member("origin").asString() == "swift")

    // Concurrent edits: neither client has seen the other's when it makes its own.
    text.insert(" and Swift", at: text.utf16Count)
    _ = try await ts.request(#"{"op":"insert","pos":0,"text":"[ts] "}"#)
    try await until("convergence") { () async throws -> Void? in
        let view = try await ts.request(#"{"op":"view"}"#)
        let converged =
            try view.member("text").asString().description == text.string
            && view.member("dirty") == .bool(false)
            && !container.isDirty
        return converged ? () : nil
    }
    #expect(text.string == "[ts] Swift: detached and Swift")
}

/// `Fluid` creates containers that the real TS 3.11.0 service clients load and co-edit.
@Suite(.serialized) struct CreateContainerEndToEndTests {
    /// The local ODSP service (harness/src/odsp-service) on 7098, one of PROTOCOL.md M4's ports.
    @MainActor @Test func odspContainerCreatedInSwiftLoadsInTypeScript() async throws {
        let server = try NodeProcess("odsp-service", ["--import", "tsx", "src/odsp-service/main.ts", "--port", "7098"])
        defer { server.stop() }
        // main.ts prints its connection values as one indented JSON object.
        var info: [String] = []
        while info.last != "}" {
            info.append(try await server.nextLine())
        }
        let connection = try JSON.parse(info.joined(separator: "\n"))
        let siteUrl = try connection.member("siteUrl").asString().description
        let driveId = try connection.member("driveId").asString().description
        let script = try String(contentsOf: loadScript, encoding: .utf8)

        let client = OdspClient(siteURL: URL(string: siteUrl)!, driveID: driveId, tokenProvider: LocalTokens())
        try await createAttachAndCoEdit {
            await client.createContainer(schema: TextAndMap.self, isolation: MainActor.shared)
        } loadTS: { itemId in
            try NodeProcess("ts odsp client", ["--input-type=module", "--eval", script, "odsp", siteUrl, driveId, itemId])
        }
    }

    @MainActor @Test func tinyliciousContainerCreatedInSwiftLoadsInTypeScript() async throws {
        let port = 7083
        let server = try await Tinylicious(port: port)
        defer { server.stop() }
        let script = try String(contentsOf: loadScript, encoding: .utf8)

        let client = TinyliciousClient(port: port)
        try await createAttachAndCoEdit {
            await client.createContainer(schema: TextAndMap.self, isolation: MainActor.shared)
        } loadTS: { id in
            try NodeProcess("ts tinylicious client", ["--input-type=module", "--eval", script, "tinylicious", "\(port)", id])
        }
    }
}
