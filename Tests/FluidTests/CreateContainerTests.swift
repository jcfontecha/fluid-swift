import Foundation
import Testing

@testable import Fluid

/// The schema the creation tests share with ts-load-client.mjs.
struct TextAndMap: ContainerSchema {
    let text: SharedString
    let map: SharedMap<String>

    init(_ objects: InitialObjects) {
        text = objects["text"]
        map = objects["map"]
    }
}

/// Nothing listens on port 1, so every request to it is refused.
private let unreachable = URL(string: "http://localhost:1")!

private struct OdspTokens: OdspTokenProvider {
    func fetchStorageToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
        TokenResponse(token: "storage:swift")
    }

    func fetchWebsocketToken(siteUrl: String, refresh: Bool) async throws -> TokenResponse {
        TokenResponse(token: "push:swift")
    }
}

private struct AzureTokens: AzureTokenProvider {
    func fetchOrdererToken(tenantID: String, documentID: String?, refresh: Bool) async throws -> TokenResponse {
        TokenResponse(token: "token")
    }

    func fetchStorageToken(tenantID: String, documentID: String, refresh: Bool) async throws -> TokenResponse {
        TokenResponse(token: "token")
    }
}

/// Creation runs no network call: a detached container's objects take edits before any service
/// is reachable.
@MainActor
struct CreateContainerTests {
    private func expectDetachedAndEditable(_ container: FluidContainer<TextAndMap>) {
        #expect(container.status.name == "detached")
        let text = container.initialObjects.text
        let map = container.initialObjects.map
        text.insert("hello", at: 0)
        text.replace(0..<1, with: "H")
        map["title"] = "Notes"
        #expect(text.string == "Hello")
        #expect(map["title"] == "Notes")
        #expect(map.keys == ["title"])
        #expect(container.status.name == "detached")
    }

    @Test func odspCreatesADetachedContainer() async {
        let client = OdspClient(siteURL: unreachable, driveID: "b!bG9jYWwtb2RzcA", tokenProvider: OdspTokens())
        expectDetachedAndEditable(await client.createContainer(schema: TextAndMap.self, isolation: MainActor.shared))
    }

    @Test func tinyliciousCreatesADetachedContainer() async {
        let client = TinyliciousClient(port: 1)
        expectDetachedAndEditable(await client.createContainer(schema: TextAndMap.self, isolation: MainActor.shared))
    }

    @Test func azureCreatesADetachedContainer() async {
        let client = AzureClient(localEndpoint: unreachable, tokenProvider: AzureTokens())
        expectDetachedAndEditable(await client.createContainer(schema: TextAndMap.self, isolation: MainActor.shared))
    }

    /// container.ts attach: a failed attach closes the container with the error.
    @Test func failedAttachClosesTheContainer() async {
        let client = OdspClient(siteURL: unreachable, driveID: "b!bG9jYWwtb2RzcA", tokenProvider: OdspTokens())
        let container = await client.createContainer(schema: TextAndMap.self, isolation: MainActor.shared)
        container.initialObjects.text.insert("unsaved", at: 0)
        let recorder = StatusRecorder(container)
        do {
            _ = try await container.attach()
            Issue.record("attach to an unreachable service must throw")
        } catch {}
        guard case .closed(let error) = container.status else {
            Issue.record("expected closed, got \(container.status)")
            return
        }
        #expect(error != nil)
        // A view that reads status after each change sees the attach, then the closure.
        for _ in 0..<100 where recorder.seen.last != "closed" {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.seen == ["attaching", "closed"])
    }
}
