import FluidDriverDefinitions
import FluidJS
import Testing

@testable import FluidContainerLoader

private func client() throws -> IClient {
    try IClient(
        json: JSON.parse(
            #"{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"user":{"id":"u"},"scopes":[]}"#
        ))
}

private struct Failure: Error {}

/// A recorder that is only touched on the test's own executor.
private final class Recorder {
    var added: [JSString] = []
    var removed: [JSString] = []
    var errors = 0
}

@Suite("PresenceAudienceAdapter") struct PresenceAudienceAdapterTests {
    @Test func forwardsAddAndRemoveInOrderAndStopsAfterOff() throws {
        let audience = Audience()
        let recorder = Recorder()
        let adapter = PresenceAudienceAdapter(audience: audience) { _ in recorder.errors += 1 }
        let addToken = adapter.onAddMember { id, _ in recorder.added.append(id) }
        adapter.onRemoveMember { id in recorder.removed.append(id) }
        try audience.addMember("a", client())
        try audience.addMember("b", client())
        audience.removeMember("a")
        #expect(recorder.added == ["a", "b"])
        #expect(recorder.removed == ["a"])
        #expect(adapter.getMembers().keys.map(\.description) == ["b"])
        #expect(adapter.getMember("b") != nil)
        adapter.off(addToken)
        try audience.addMember("c", client())
        #expect(recorder.added == ["a", "b"])
    }

    @Test func throwingListenerReportsToTheContainer() throws {
        let audience = Audience()
        let recorder = Recorder()
        let adapter = PresenceAudienceAdapter(audience: audience) { _ in recorder.errors += 1 }
        adapter.onAddMember { _, _ in throw Failure() }
        try audience.addMember("a", client())
        #expect(recorder.errors == 1)
    }
}

@Suite("ContainerPresenceClock") struct ContainerPresenceClockTests {
    @Test func firedTimerHandsItsCallbackToTheExecutorOnce() async throws {
        let (fired, continuation) = AsyncStream<Int>.makeStream()
        let clock = ContainerPresenceClock { continuation.yield($0) }
        var ran = 0
        let handle = clock.setTimeout({ ran += 1 }, delay: 5)
        var iterator = fired.makeAsyncIterator()
        #expect(await iterator.next() == handle)
        try clock.takeCallback(handle)?()
        #expect(ran == 1)
        #expect(clock.takeCallback(handle) == nil)
    }

    @Test func clearedTimerNeverFires() async throws {
        let (fired, continuation) = AsyncStream<Int>.makeStream()
        let clock = ContainerPresenceClock { continuation.yield($0) }
        let cleared = clock.setTimeout({}, delay: 5)
        clock.clearTimeout(cleared)
        let kept = clock.setTimeout({}, delay: 20)
        var iterator = fired.makeAsyncIterator()
        #expect(await iterator.next() == kept)
        #expect(clock.takeCallback(cleared) == nil)
    }

    @Test func nowIsWholeEpochMilliseconds() {
        let clock = ContainerPresenceClock { _ in }
        let now = clock.now()
        #expect(now == now.rounded(.down))
        #expect(now > 1_700_000_000_000)
        #expect((0..<1).contains(clock.random()))
    }
}
