import FluidAzureClient
import FluidJS
import FluidMap
import FluidRouterliciousDriver
import FluidSequence
import FluidStatic
import FluidTinyliciousClient
import FluidTinyliciousDriver
import Foundation
import Synchronization
import Testing

/// The repository's harness/ directory, which holds tinylicious, the TS clients and the script.
private let harness = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "harness")

/// Tokens for a fixed user. Tinylicious does not verify signatures; the user's `name` is the
/// first 13 characters of its id (InsecureTinyliciousTokenProvider.signedToken).
private struct UserTokenProvider: ITokenProvider {
    let user: String

    func fetchOrdererToken(tenantId: String, documentId: String?, refresh: Bool) async throws -> ITokenResponse {
        let jwt = try InsecureTinyliciousTokenProvider().signedToken(
            tenant: tenantId,
            document: documentId ?? "",
            userID: user,
            now: Int(Date().timeIntervalSince1970.rounded()))
        return ITokenResponse(jwt: jwt, fromCache: false)
    }

    func fetchStorageToken(tenantId: String, documentId: String, refresh: Bool) async throws -> ITokenResponse {
        try await fetchOrdererToken(tenantId: tenantId, documentId: documentId, refresh: refresh)
    }
}

private struct Timeout: Error, CustomStringConvertible {
    let description: String
}

/// Polls `poll` on the main actor until it returns a value. Each suspension also lets the
/// main-owned containers run.
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
        directory = FileManager.default.temporaryDirectory.appending(path: "fluid-l9-tinylicious-\(UUID().uuidString)")
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

private let schema = ContainerSchema(initialObjects: ["text": SharedString.self, "map": SharedMap.self])

/// The map's entries by key, for comparison across clients (iteration order is not compared).
private func entries(_ map: SharedMap) -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    for (key, value) in map.entries() {
        result[key.description] = value
    }
    return result
}

private func entries(_ object: JSONValue) throws -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    for (key, value) in try object.asObject().entries {
        result[key.description] = value
    }
    return result
}

/// Concurrent text and map edits on both clients, then waits until both hold the same text and
/// map and neither has unacknowledged ops. Returns the converged text.
@MainActor
private func coEdit(ts: NodeProcess, container: FluidContainer, text: SharedString, map: SharedMap, user: String) async throws
    -> String
{
    // Neither client has seen the other's edits when it makes its own.
    try text.insertText(text.getLength(), " and Swift")
    try map.set(JSString(user), .string("hello"))
    try map.set("shared", .string(JSString(user)))
    _ = try await ts.request(#"{"op":"insert","pos":0,"text":"[ts] "}"#)
    _ = try await ts.request(#"{"op":"set","key":"shared","value":"ts"}"#)

    try await until("convergence") { () async throws -> Void? in
        let tsView = try await ts.request(#"{"op":"view"}"#)
        let converged =
            try tsView.member("text").asString() == text.getText()
            && (try entries(tsView.member("map"))) == entries(map)
            && tsView.member("dirty") == .bool(false)
            && !container.isDirty
        return converged ? () : nil
    }
    return text.getText().description
}

/// The audience as user id -> (name, connection ids), from the TS client's `members` answer.
private func members(_ answer: JSONValue) throws -> [String: (name: String, connections: Set<String>)] {
    var result: [String: (name: String, connections: Set<String>)] = [:]
    for (userId, member) in try answer.member("members").asObject().entries {
        let connections = try member.member("connections").asArray().map { try $0.member("id").asString().description }
        result[userId.description] = (try member.member("name").asString().description, Set(connections))
    }
    return result
}

/// Waits until the TS client and the Swift audience hold the same two users, with the same names
/// and connections.
@MainActor
private func waitForMatchingAudiences<Member: IMember>(
    ts: NodeProcess, _ audience: ServiceAudience<Member>, name: (Member) -> String
) async throws {
    try await until("matching audiences") { () async throws -> Void? in
        let tsMembers = try members(await ts.request(#"{"op":"members"}"#))
        let swiftMembers = try audience.getMembers()
        guard tsMembers.count == 2, Set(tsMembers.keys) == Set(swiftMembers.keys) else {
            return nil
        }
        for (userId, member) in swiftMembers.entries {
            guard tsMembers[userId]?.name == name(member),
                tsMembers[userId]?.connections == Set(member.connections.map(\.id))
            else {
                return nil
            }
        }
        return ()
    }
}

/// Live co-editing between the real TS 3.11.0 service clients and the Swift ports on tinylicious.
///
/// TS `TinyliciousClient` always uses the tenant "tinylicious" and `AzureClient` in local mode the
/// tenant "local"; tinylicious keeps each tenant's documents apart, so neither client can load
/// the other's container (checked against TS: loading fails with 0x8e4, "Snapshot should exist").
/// Each client therefore co-edits with its own TS counterpart, and the Swift
/// `TinyliciousClient` is shown to fail on the Azure container as TS does.
@Suite(.serialized) struct ServiceClientsEndToEndTests {
    @MainActor @Test func azureClientCoEditsATypeScriptAzureContainer() async throws {
        let port = 7081
        let server = try await Tinylicious(port: port)
        defer { server.stop() }
        let ts = try NodeProcess("ts azure client", ["--import", "tsx", "src/azure-client/ts-client.ts", "azure", "\(port)", "ts"])
        defer { ts.stop() }
        let id = try JSON.parse(await ts.nextLine()).member("id").asString().description

        let client = AzureClient(properties: AzureClientProps(connection: .local(AzureLocalConnectionConfig(
            endpoint: "http://localhost:\(port)/",
            tokenProvider: UserTokenProvider(user: "swift-azure")))))
        let (container, services) = try await client.getContainer(
            id, containerSchema: schema, oldestSupportedClient: "2.0.0", isolation: MainActor.shared)
        let text = try #require(container.initialObjects["text"] as? SharedString)
        let map = try #require(container.initialObjects["map"] as? SharedMap)
        try await until("Swift connected") { container.connectionState == .connected ? () : nil }
        // The TS edits were made after attach, so they reach Swift as ops.
        #expect(text.getText() == "TS: hello")
        #expect(map.get("ts") == .string("hello"))

        let converged = try await coEdit(ts: ts, container: container, text: text, map: map, user: "swift-azure")
        #expect(converged == "[ts] TS: hello and Swift")
        #expect(map.get("swift-azure") == .string("hello"))

        try await waitForMatchingAudiences(ts: ts, services.audience) { $0.name }
        #expect(Set(try services.audience.getMembers().keys) == ["ts", "swift-azure"])
        let myself = try #require(try services.audience.getMyself())
        #expect(myself.member.name == "swift-azure")

        // getContainerVersions reads the same versions from storage as TS does.
        try await until("matching versions") { () async throws -> Void? in
            let tsVersions = try await ts.request(#"{"op":"versions"}"#).member("versions").asArray().map { version in
                AzureContainerVersion(
                    id: try version.member("id").asString().description,
                    date: try version.member("date").asString().description)
            }
            let swiftVersions = try await client.getContainerVersions(id)
            return !swiftVersions.isEmpty && swiftVersions == tsVersions ? () : nil
        }

        // The Azure container is under the tenant "local", out of TinyliciousClient's reach.
        let tinylicious = try TinyliciousClient(properties: TinyliciousClientProps(connection: TinyliciousConnectionConfig(port: port)))
        await #expect(throws: (any Error).self) {
            _ = try await tinylicious.getContainer(id, containerSchema: schema, oldestSupportedClient: "2.0.0", isolation: MainActor.shared)
        }

        container.dispose()
        #expect(container.disposed)
    }

    @MainActor @Test func tinyliciousClientCoEditsATypeScriptTinyliciousContainer() async throws {
        let port = 7082
        let server = try await Tinylicious(port: port)
        defer { server.stop() }
        let ts = try NodeProcess("ts tinylicious client", ["--import", "tsx", "src/azure-client/ts-client.ts", "tinylicious", "\(port)", "ts"])
        defer { ts.stop() }
        let id = try JSON.parse(await ts.nextLine()).member("id").asString().description

        let client = try TinyliciousClient(properties: TinyliciousClientProps(connection: TinyliciousConnectionConfig(
            port: port,
            tokenProvider: UserTokenProvider(user: "swift-tiny"))))
        let (container, services) = try await client.getContainer(
            id, containerSchema: schema, oldestSupportedClient: "2.0.0", isolation: MainActor.shared)
        let text = try #require(container.initialObjects["text"] as? SharedString)
        let map = try #require(container.initialObjects["map"] as? SharedMap)
        try await until("Swift connected") { container.connectionState == .connected ? () : nil }
        #expect(text.getText() == "TS: hello")
        #expect(map.get("ts") == .string("hello"))

        let converged = try await coEdit(ts: ts, container: container, text: text, map: map, user: "swift-tiny")
        #expect(converged == "[ts] TS: hello and Swift")
        #expect(map.get("swift-tiny") == .string("hello"))

        try await waitForMatchingAudiences(ts: ts, services.audience) { $0.name }
        let myself = try #require(try services.audience.getMyself())
        #expect(myself.member.name == "swift-tiny")

        container.dispose()
        #expect(container.disposed)
    }
}
