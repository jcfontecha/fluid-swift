import FluidJS
import Foundation
import Testing
@testable import FluidOdspDriver

private actor DiscoveryProbe {
    var calls = 0
    func fetch() throws -> JSONValue {
        calls += 1
        return try JSON.parse("{\"id\":\"session\",\"tenantId\":\"tenant\",\"refreshSessionDurationSeconds\":30.025}")
    }
}

@Suite struct OdspDiscoveryTests {
    @Test func timerActuallyRefreshesAndDisconnectCancelsIt() async throws {
        let probe = DiscoveryProbe()
        let stream = OdspDelayLoadedDeltaStream(hashedDocumentId: "doc", cache: OdspSessionJoinCache(), fetch: { _, _, _, _ in try await probe.fetch() })
        await stream.connected(clientId: "client")
        _ = try await stream.joinSession()
        try await Task.sleep(for: .milliseconds(100))
        await stream.disconnected()
        // A refresh already past its client check finishes its fetch and re-arms (as in TS); the
        // next timer stops at the check. Count once that has settled.
        try await Task.sleep(for: .milliseconds(60))
        let count = await probe.calls
        #expect(count >= 2)
        #expect(await stream.refreshDeadline == nil)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await probe.calls == count)
    }

    @Test func staleRefreshDoesNotFetch() async throws {
        let probe = DiscoveryProbe()
        let stream = OdspDelayLoadedDeltaStream(hashedDocumentId: "doc", cache: OdspSessionJoinCache(), fetch: { _, _, _, _ in try await probe.fetch() })
        await stream.connected(clientId: "new-client")
        await #expect(throws: OdspNetworkError.self) {
            _ = try await stream.joinSession(refreshing: true, clientId: "old-client")
        }
        #expect(await probe.calls == 0)
    }

    @Test func nonAuthorizationDisconnectKeepsDiscovery() async throws {
        let probe = DiscoveryProbe()
        let stream = OdspDelayLoadedDeltaStream(hashedDocumentId: "doc", cache: OdspSessionJoinCache(), disableRefresh: true, now: { 0 }, fetch: { _, _, _, _ in try await probe.fetch() })
        _ = try await stream.joinSession()
        await stream.disconnected(error: OdspNetworkError("genericNetworkError", canRetry: true))
        _ = try await stream.joinSession()
        #expect(await probe.calls == 1)
        await stream.disconnected(error: OdspNetworkError("authorizationError", canRetry: true))
        _ = try await stream.joinSession()
        #expect(await probe.calls == 2)
    }
}
