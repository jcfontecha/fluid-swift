import FluidContainerDefinitions
import FluidContainerLoader
import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS
import Foundation
import Testing

@testable import FluidOdspClient

/// A loader container stand-in with the synchronous IContainer surface the services read.
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

    func connect() {}

    func disconnect() {}

    func close(_ error: (any Error)?) {
        closed = true
        events.emit(.closed(error: error))
    }

    func dispose(_ error: (any Error)?) {}

    nonisolated(nonsending) func getEntryPoint() async throws -> AnyObject {
        NSObject()
    }
}

private func names(_ event: OdspContainerServicesEvent) -> String {
    switch event {
    case .readOnlyStateChanged: "readOnlyStateChanged"
    case .sensitivityLabelsInfoChanged: "sensitivityLabelsInfoChanged"
    }
}

@Suite struct OdspContainerServicesTests {
    /// odspContainerServices.ts: `readonly` and a `metadataUpdate` carrying
    /// `sensitivityLabelsInfo` are forwarded; other metadata updates are not.
    @Test func forwardsReadOnlyAndSensitivityLabelChanges() throws {
        let container = FakeContainer()
        let services = try OdspContainerServices(container: container)
        var received: [String] = []
        services.events.on { received.append(names($0)) }
        container.events.emit(.readonly(true))
        var other = JSObject<JSString>()
        other["title"] = "notes"
        container.events.emit(.metadataUpdate(other))
        var labels = JSObject<JSString>()
        labels["sensitivityLabelsInfo"] = "confidential"
        container.events.emit(.metadataUpdate(labels))
        #expect(received == ["readOnlyStateChanged", "sensitivityLabelsInfoChanged"])
    }

    /// odspContainerServices.ts `dispose`: idempotent, and stops forwarding.
    @Test func disposeStopsForwarding() throws {
        let container = FakeContainer()
        let services = try OdspContainerServices(container: container)
        var received: [String] = []
        services.events.on { received.append(names($0)) }
        services.dispose()
        services.dispose()
        container.events.emit(.readonly(true))
        #expect(services.disposed)
        #expect(received.isEmpty)
    }

    /// odspContainerServices.ts getters read the container's current state.
    @Test func readsReadOnlyStateAndSensitivityLabels() throws {
        let container = FakeContainer()
        let services = try OdspContainerServices(container: container)
        #expect(services.getReadOnlyState() == false)
        #expect(services.getSensitivityLabelsInfo() == nil)
        container.readOnlyInfo = ReadOnlyInfo(readonly: true, permissions: true)
        container.containerMetadata["sensitivityLabelsInfo"] = "confidential"
        #expect(services.getReadOnlyState() == true)
        #expect(services.getSensitivityLabelsInfo() == "confidential")
    }

    /// The audience's members are ODSP members (odspAudience.ts) of interactive clients.
    @Test func audienceMembersAreOdspMembers() throws {
        let container = FakeContainer()
        try container.loaderAudience.addMember("c1", IClient(json: JSON.parse("""
            {"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"scopes":[],\
            "user":{"id":"ada","oid":"ada-oid","name":"Ada","email":"ada@example.com"}}
            """)))
        let services = try OdspContainerServices(container: container)
        let ada = try #require(try services.audience.getMembers().get("ada"))
        #expect(ada.id == "ada-oid")
        #expect(ada.name == "Ada")
        #expect(ada.connections.map(\.id) == ["c1"])
    }
}
