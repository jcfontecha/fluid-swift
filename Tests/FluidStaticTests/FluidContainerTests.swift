import FluidContainerDefinitions
import FluidContainerLoader
import FluidContainerRuntime
import FluidDatastore
import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidMap
import FluidTestRuntimeUtils
import Foundation
import Testing

@testable import FluidStatic

/// A loader container stand-in with the synchronous IContainer surface. It records lifecycle
/// calls; `close` emits `closed`, as container.ts closeCore does.
final class FakeContainer: IContainer {
    var connectionState = ConnectionState.connected
    var isDirty = false
    var closed = false
    var attachState = AttachState.attached
    var clientId: JSString?
    let loaderAudience = Audience()
    var audience: any IAudience { loaderAudience }
    var readOnlyInfo = ReadOnlyInfo(readonly: false)
    var containerMetadata = JSObject<JSString>()
    let events = ListenerList<ContainerEvent>()
    var calls: [String] = []
    var closeErrors: [String] = []
    private let entryPoint: AnyObject

    init(entryPoint: AnyObject = NSObject()) {
        self.entryPoint = entryPoint
    }

    func connect() {
        calls.append("connect")
    }

    func disconnect() {
        calls.append("disconnect")
    }

    func close(_ error: (any Error)?) {
        calls.append("close")
        closeErrors.append(error.map { String(describing: $0) } ?? "nil")
        closed = true
        events.emit(.closed(error: error))
    }

    func dispose(_ error: (any Error)?) {
        calls.append("dispose")
    }

    nonisolated(nonsending) func getEntryPoint() async throws -> AnyObject {
        entryPoint
    }
}

/// The root data object of a captured TS fluid-static container (`{ map: SharedMap }`, at attach).
func capturedRootDataObject() throws -> RootDataObject {
    let url = try #require(Bundle.module.url(forResource: "m2-attach", withExtension: "json", subdirectory: "Fixtures"))
    let snapshot = try SummaryTree(json: JSON.parse(String(contentsOf: url, encoding: .utf8)))
    let runtime = try ContainerRuntime(
        sessionId: "00000000-0000-4000-8000-000000000001", clientId: "test",
        deltaManager: MockDeltaManager(), quorum: MockQuorumClients())
    try runtime.loadSnapshot(snapshot, factories: [SharedMap.getFactory(), SharedDirectory.getFactory()])
    return try RootDataObject(runtime: runtime)
}

private func names(_ event: FluidContainerEvent) -> String {
    switch event {
    case .connected: "connected"
    case .disconnected: "disconnected"
    case .saved: "saved"
    case .dirty: "dirty"
    case .disposed(let error): "disposed(\(error.map { String(describing: $0) } ?? "nil"))"
    }
}

@Suite struct FluidContainerTests {
    /// fluidContainer.ts `initialObjects`: the root data object's, keyed as the creator named them.
    @Test func initialObjectsAreTheRootDataObjects() async throws {
        let container = FakeContainer(entryPoint: try capturedRootDataObject())
        let fluidContainer = try await createFluidContainer(container: container)
        #expect(fluidContainer.initialObjects.entries.map(\.key) == ["map"])
        #expect(fluidContainer.initialObjects["map"] is SharedMap)
    }

    /// fluidContainer.ts assert 0xb9e.
    @Test func rejectsAnEntryPointThatIsNotARootDataObject() async throws {
        let container = FakeContainer()
        await #expect(throws: DatastoreError.self) {
            _ = try await createFluidContainer(container: container)
        }
        do {
            _ = try await createFluidContainer(container: container)
        } catch {
            #expect(String(describing: error) == "0xb9e: entryPoint must be of type IStaticEntryPoint")
        }
    }

    /// fluidContainer.ts constructor: connected, closed (as disposed), disconnected, saved and
    /// dirty are forwarded inline; the container's other events are not.
    @Test func forwardsTheFiveContainerEvents() async throws {
        let container = FakeContainer(entryPoint: try capturedRootDataObject())
        let fluidContainer = try await createFluidContainer(container: container)
        var received: [String] = []
        fluidContainer.events.on { received.append(names($0)) }
        container.events.emit(.connected(clientId: "client-1"))
        container.events.emit(.readonly(true))
        container.events.emit(.dirty)
        container.events.emit(.metadataUpdate(JSObject()))
        container.events.emit(.saved)
        container.events.emit(.disconnected)
        container.events.emit(.disposed(error: nil))
        container.events.emit(.closed(error: DatastoreError("boom")))
        #expect(received == ["connected", "dirty", "saved", "disconnected", "disposed(boom)"])
    }

    /// fluidContainer.ts `dispose`: closes the container (emitting disposed), then unsubscribes.
    @Test func disposeClosesTheContainerThenStopsForwarding() async throws {
        let container = FakeContainer(entryPoint: try capturedRootDataObject())
        let fluidContainer = try await createFluidContainer(container: container)
        var received: [String] = []
        fluidContainer.events.on { received.append(names($0)) }
        fluidContainer.dispose()
        #expect(container.calls == ["close"])
        #expect(container.closeErrors == ["nil"])
        #expect(fluidContainer.disposed)
        container.events.emit(.connected(clientId: "client-1"))
        #expect(received == ["disposed(nil)"])
    }

    /// fluidContainer.ts getters and `connect`/`disconnect` read and call the container directly.
    @Test func stateAndLifecycleCallsGoToTheContainer() async throws {
        let container = FakeContainer(entryPoint: try capturedRootDataObject())
        let fluidContainer = try await createFluidContainer(container: container)
        container.connectionState = .catchingUp
        container.isDirty = true
        #expect(fluidContainer.connectionState == .catchingUp)
        #expect(fluidContainer.isDirty)
        #expect(fluidContainer.attachState == .attached)
        #expect(!fluidContainer.disposed)
        fluidContainer.disconnect()
        fluidContainer.connect()
        #expect(container.calls == ["disconnect", "connect"])
    }

    /// fluidContainer.ts `attach`: a loaded container is not detached.
    @Test func attachRejectsALoadedContainer() async throws {
        let container = FakeContainer(entryPoint: try capturedRootDataObject())
        let fluidContainer = try await createFluidContainer(container: container)
        do {
            _ = try await fluidContainer.attach()
            Issue.record("attach succeeded")
        } catch {
            #expect(String(describing: error) == "Cannot attach container. Container is not in detached state.")
        }
    }
}
