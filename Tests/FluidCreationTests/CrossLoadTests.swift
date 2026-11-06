import FluidJS
import FluidSequence
import FluidStatic
import Foundation
import Synchronization
import Testing

import FluidOdspClient
import FluidAzureClient
import FluidTinyliciousClient
import FluidTinyliciousDriver
import FluidMap
import FluidContainerLoader
import FluidOdspDriver
import FluidDriverDefinitions

/// The repository's harness/ directory, which holds the local ODSP service and its node_modules.
private let harness = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "harness")

/// The local ODSP service's fake tokens (harness/src/odsp-service/tokens.ts).
private struct LocalTokenProvider: IOdspTokenProvider {
    let user: String

    func fetchWebsocketToken(siteUrl: String, refresh: Bool) async throws -> FluidOdspClient.TokenResponse {
        FluidOdspClient.TokenResponse(token: "push:\(user)")
    }

    func fetchStorageToken(siteUrl: String, refresh: Bool) async throws -> FluidOdspClient.TokenResponse {
        FluidOdspClient.TokenResponse(token: "storage:\(user)")
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

    init(_ name: String, _ arguments: [String], environment: [String: String] = [:]) throws {
        self.name = name
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
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

@Suite(.serialized) struct CrossLoadTests {
    @MainActor @Test func odsp() async throws {
        let server = try NodeProcess("odsp", ["--import", "tsx", "src/odsp-service/main.ts", "--port", "7085"])
        defer { server.stop() }
        var line = ""
        while line != "}" { line = try await server.nextLine() }
        for swiftCreates in [true, false] {
            try await exercise(kind: "odsp", port: 7085, swiftCreates: swiftCreates)
        }
        try await detachedBlobs()
    }

    @MainActor @Test func tinyliciousAndAzure() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let server = try NodeProcess("tinylicious", ["node_modules/tinylicious/dist/index.js"],
            environment: ["PORT": "7083", "storage": temporary.path])
        defer { server.stop() }
        for _ in 0..<300 {
            if let (_, response) = try? await URLSession.shared.data(from: URL(string: "http://localhost:7083")!),
                (response as? HTTPURLResponse)?.statusCode == 200 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        for kind in ["tinylicious", "azure"] {
            for swiftCreates in [true, false] {
                try await exercise(kind: kind, port: 7083, swiftCreates: swiftCreates)
            }
        }
    }

    @MainActor private func detachedBlobs() async throws {
        let factory = try createDOProviderContainerRuntimeFactory(
            schema: ContainerSchema(initialObjects: ["text": SharedString.self, "map": SharedMap.self]), oldestSupportedClient: "2.0.0")
        let loader = try await createDetachedContainer(ICreateDetachedContainerProps(
            urlResolver: OdspDriverUrlResolver(),
            documentServiceFactory: OdspDocumentServiceFactory(
                getStorageToken: { _ in .response(token: "storage:swift", fromCache: nil) },
                getWebsocketToken: { _ in .response(token: "push:swift", fromCache: nil) }),
            runtimeFactory: factory, codeDetails: JSON.parse(#"{"package":"no-dynamic-package","config":{}}"#)), isolation: MainActor.shared)
        defer { loader.dispose(nil) }
        let container = try await createFluidContainer(container: loader)
        let map = try #require(container.initialObjects["map"] as? SharedMap)
        let bytes: [UInt8] = [0, 1, 127, 128, 255]
        let blob = try await loader.uploadBlob(bytes)
        var handle = JSObject<JSONValue>()
        handle["type"] = .string("__fluid_handle__")
        handle["url"] = .string(blob.absolutePath)
        try map.set("blob", .object(handle))
        try await loader.attach(createOdspCreateContainerRequest(siteUrl: "http://localhost:7085", driveId: "b!bG9jYWwtb2RzcA", filePath: "", fileName: UUID().uuidString))
        let id = try IOdspResolvedUrl(json: #require(loader.resolvedUrl).json).itemId
        let ts = try NodeProcess("TS blobs", ["src/create/cross-load.mjs", "odsp", "7085", id])
        defer { ts.stop() }
        _ = try await ts.nextLine()
        try ts.send(#"{"op":"blob"}"#)
        #expect(try JSON.parse(await ts.nextLine()).member("bytes") == .array(bytes.map { .number(Double($0)) }))
    }

    @MainActor private func exercise(kind: String, port: Int, swiftCreates: Bool) async throws {
        let schema = ContainerSchema(initialObjects: ["text": SharedString.self, "map": SharedMap.self])
        let odsp = OdspClient(properties: OdspClientProps(connection: OdspConnectionConfig(
            tokenProvider: LocalTokenProvider(user: "swift"), siteUrl: "http://localhost:\(port)", driveId: "b!bG9jYWwtb2RzcA", filePath: "")))
        let tiny = try TinyliciousClient(properties: TinyliciousClientProps(connection: TinyliciousConnectionConfig(port: port)))
        let azure = AzureClient(properties: AzureClientProps(connection: .local(AzureLocalConnectionConfig(
            endpoint: "http://localhost:\(port)", tokenProvider: InsecureTinyliciousTokenProvider()))))
        func load(_ id: String?) async throws -> FluidContainer {
            if kind == "odsp" {
                if let id { return try await odsp.getContainer(id, containerSchema: schema, isolation: MainActor.shared).container }
                return try await odsp.createContainer(schema, isolation: MainActor.shared).container
            }
            if kind == "azure" {
                if let id { return try await azure.getContainer(id, containerSchema: schema, oldestSupportedClient: "2.0.0", isolation: MainActor.shared).container }
                return try await azure.createContainer(schema, oldestSupportedClient: "2.0.0", isolation: MainActor.shared).container
            }
            if let id { return try await tiny.getContainer(id, containerSchema: schema, oldestSupportedClient: "2.0.0", isolation: MainActor.shared).container }
            return try await tiny.createContainer(schema, oldestSupportedClient: "2.0.0", isolation: MainActor.shared).container
        }
        let container: FluidContainer
        let ts: NodeProcess
        let initial: JSONValue
        if swiftCreates {
            container = try await load(nil)
            #expect(container.attachState == .detached)
            #expect(container.connectionState == .disconnected)
            let text = try #require(container.initialObjects["text"] as? SharedString)
            let map = try #require(container.initialObjects["map"] as? SharedMap)
            try text.insertText(0, "detached")
            try map.set("origin", .string("detached"))
            let id = try await container.attach()
            try await until("creator connected \(kind)") { container.connectionState == .connected ? () : nil }
            ts = try NodeProcess("TS load", ["src/create/cross-load.mjs", kind, String(port), id])
            initial = try JSON.parse(await ts.nextLine())
        } else {
            ts = try NodeProcess("TS create", ["src/create/cross-load.mjs", kind, String(port), "new"])
            initial = try JSON.parse(await ts.nextLine())
            container = try await load(initial.member("itemId").asString().description)
        }
        defer { container.dispose() }
        defer { ts.stop() }
        let text = try #require(container.initialObjects["text"] as? SharedString)
        let map = try #require(container.initialObjects["map"] as? SharedMap)
        #expect(text.getText() == "detached")
        #expect(try initial.member("text") == .string("detached"))
        #expect(try map.get("origin") == .string("detached"))
        try await until("connected \(kind)") { container.connectionState == .connected ? () : nil }
        try text.insertText(text.getLength(), " Swift")
        try map.set("swift", .number(1))
        try ts.send(#"{"op":"edit"}"#)
        _ = try await ts.nextLine()
        let deadline = ContinuousClock.now + .seconds(60)
        while true {
            try ts.send(#"{"op":"view"}"#)
            let view = try JSON.parse(await ts.nextLine())
            let entries = try view.member("map").asArray()
            if try view.member("text").asString() == text.getText(),
                text.getText() == "TS detached Swift", entries.count == 3,
                try map.get("ts") == .number(2), !container.isDirty,
                try view.member("dirty") == .bool(false) { break }
            guard ContinuousClock.now < deadline else { throw Timeout(description: "co-edit \(kind): \(view) / \(text.getText())") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let fresh = try await load(initial.member("itemId").asString().description)
        defer { fresh.dispose() }
        #expect((fresh.initialObjects["text"] as? SharedString)?.getText() == text.getText())
    }
}
