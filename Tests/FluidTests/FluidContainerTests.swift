import FluidContainerDefinitions
import FluidContainerLoader
import FluidContainerRuntime
import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidMap
import FluidSequence
import FluidTestRuntimeUtils
import Foundation
import Testing

@testable import Fluid
@testable import FluidStatic

/// A loader container stand-in (as in FluidStaticTests): `close` emits `closed`, as container.ts
/// closeCore does.
private final class FakeContainer: IContainer {
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
    var closeCount = 0
    private let entryPoint: AnyObject

    init(entryPoint: AnyObject) {
        self.entryPoint = entryPoint
    }

    func connect() {}

    func disconnect() {}

    func close(_ error: (any Error)?) {
        closeCount += 1
        closed = true
        events.emit(.closed(error: error))
    }

    func dispose(_ error: (any Error)?) {}

    nonisolated(nonsending) func getEntryPoint() async throws -> AnyObject {
        entryPoint
    }
}

private struct Boom: Error {}

/// The captured TS container's schema: one SharedMap named "map".
private struct MapSchema: Fluid.ContainerSchema {
    let map: Fluid.SharedMap<Int>

    init(_ objects: Fluid.InitialObjects) {
        map = objects["map"]
    }
}

private struct WrongKind: Fluid.ContainerSchema {
    let map: Fluid.SharedString

    init(_ objects: Fluid.InitialObjects) {
        map = objects["map"]
    }
}

private struct MissingKey: Fluid.ContainerSchema {
    let map: Fluid.SharedMap<Int>
    let text: Fluid.SharedString

    init(_ objects: Fluid.InitialObjects) {
        map = objects["map"]
        text = objects["text"]
    }
}

/// A fake loader container over the root data object of a captured TS fluid-static container
/// (`{ map: SharedMap }`, at attach).
private func fakeContainer() throws -> FakeContainer {
    let url = try #require(Bundle.module.url(forResource: "m2-attach", withExtension: "json", subdirectory: "Fixtures"))
    let snapshot = try SummaryTree(json: JSON.parse(String(contentsOf: url, encoding: .utf8)))
    let runtime = try ContainerRuntime(
        sessionId: "00000000-0000-4000-8000-000000000001", clientId: "test",
        deltaManager: MockDeltaManager(), quorum: MockQuorumClients())
    try runtime.loadSnapshot(snapshot, factories: [FluidMap.SharedMap.getFactory(), SharedDirectory.getFactory()])
    return FakeContainer(entryPoint: try RootDataObject(runtime: runtime))
}

@MainActor
struct FluidContainerTests {
    @Test func resolvesTypedInitialObjects() async throws {
        let fake = try fakeContainer()
        let container = try Fluid.FluidContainer<MapSchema>(port: await createFluidContainer(container: fake))
        container.initialObjects.map["a"] = 1
        #expect(container.initialObjects.map["a"] == 1)
    }

    @Test func wrongKindIsASchemaMismatchAndClosesTheContainer() async throws {
        let fake = try fakeContainer()
        let port = try await createFluidContainer(container: fake)
        #expect(throws: FluidError.schemaMismatch(key: "map")) {
            _ = try Fluid.FluidContainer<WrongKind>(port: port)
        }
        #expect(fake.closeCount == 1)
    }

    @Test func missingKeyIsASchemaMismatch() async throws {
        let port = try await createFluidContainer(container: try fakeContainer())
        #expect(throws: FluidError.schemaMismatch(key: "text")) {
            _ = try Fluid.FluidContainer<MissingKey>(port: port)
        }
    }

    @Test func statusFollowsTheConnection() async throws {
        let fake = try fakeContainer()
        fake.connectionState = .catchingUp
        let container = try Fluid.FluidContainer<MapSchema>(port: await createFluidContainer(container: fake))
        guard case .connecting = container.status else {
            Issue.record("expected connecting, got \(container.status)")
            return
        }
        let observed = ChangeCounter { _ = container.status }
        fake.connectionState = .connected
        fake.events.emit(.connected(clientId: "client-1"))
        guard case .connected = container.status else {
            Issue.record("expected connected, got \(container.status)")
            return
        }
        fake.connectionState = .disconnected
        fake.events.emit(.disconnected)
        guard case .disconnected = container.status else {
            Issue.record("expected disconnected, got \(container.status)")
            return
        }
        #expect(observed.count == 2)
    }

    @Test func closedStatusCarriesTheError() async throws {
        let fake = try fakeContainer()
        let container = try Fluid.FluidContainer<MapSchema>(port: await createFluidContainer(container: fake))
        let observed = ChangeCounter { _ = container.status }
        fake.close(Boom())
        guard case .closed(let error) = container.status else {
            Issue.record("expected closed, got \(container.status)")
            return
        }
        #expect(error is Boom)
        #expect(observed.count == 1)
    }

    @Test func isDirtyIsObserved() async throws {
        let fake = try fakeContainer()
        let container = try Fluid.FluidContainer<MapSchema>(port: await createFluidContainer(container: fake))
        let observed = ChangeCounter { _ = container.isDirty }
        fake.isDirty = true
        fake.events.emit(.dirty)
        #expect(container.isDirty)
        fake.isDirty = false
        fake.events.emit(.saved)
        #expect(!container.isDirty)
        #expect(observed.count == 2)
    }

    @Test func attachMovesFromDetachedThroughAttachingToConnecting() async throws {
        let fake = try fakeContainer()
        fake.attachState = .detached
        fake.connectionState = .disconnected
        var container: Fluid.FluidContainer<MapSchema>?
        var duringAttach: [String] = []
        let port = try await createFluidContainer(container: fake, attach: {
            // container.ts attach: attaching, then attached and connecting.
            fake.attachState = .attaching
            duringAttach.append(container?.status.name ?? "none")
            fake.attachState = .attached
            fake.connectionState = .establishingConnection
            return "new-id"
        })
        container = try Fluid.FluidContainer(port: port)
        let created = try #require(container)
        #expect(created.status.name == "detached")
        let observed = ChangeCounter { _ = created.status }
        #expect(try await created.attach() == "new-id")
        #expect(duringAttach == ["attaching"])
        #expect(created.status.name == "connecting")
        #expect(observed.count == 2)
    }

    /// fluidContainer.ts `attach`: a container that is not detached cannot attach, and stays open.
    @Test func attachOnAnAttachedContainerThrows() async throws {
        let fake = try fakeContainer()
        let container = try Fluid.FluidContainer<MapSchema>(port: await createFluidContainer(container: fake, attach: { "id" }))
        do {
            _ = try await container.attach()
            Issue.record("attach on an attached container must throw")
        } catch {}
        #expect(container.status.name == "connected")
        #expect(fake.closeCount == 0)
    }

    /// There is no dispose: releasing the last reference closes the container.
    @Test func releasingTheContainerClosesIt() async throws {
        let fake = try fakeContainer()
        var container: Fluid.FluidContainer<MapSchema>? = try Fluid.FluidContainer(port: await createFluidContainer(container: fake))
        #expect(container != nil)
        container = nil
        #expect(fake.closeCount == 1)
        #expect(fake.closed)
    }
}

struct ContainerSchemaTests {
    private struct Checklist: Fluid.ContainerSchema {
        let title: Fluid.SharedString
        let items: Fluid.SharedMap<String>

        init(_ objects: Fluid.InitialObjects) {
            title = objects["title"]
            items = objects["items"]
        }
    }

    /// The port schema lists each key with its channel class, in the order the init reads them.
    @Test func recordsKeysAndKindsInReadOrder() {
        let schema = InitialObjects.schema(of: Checklist.self)
        let entries = schema.initialObjects.entries
        #expect(entries.map(\.key) == ["title", "items"])
        #expect(ObjectIdentifier(entries[0].value) == ObjectIdentifier(FluidSequence.SharedString.self))
        #expect(ObjectIdentifier(entries[1].value) == ObjectIdentifier(FluidMap.SharedMap.self))
    }
}
