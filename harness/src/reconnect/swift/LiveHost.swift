import FluidContainerLoader
import FluidContainerDefinitions
import FluidDriverDefinitions
import FluidJS
import FluidMap
import FluidStatic
import FluidOdspDriver
import FluidRouterliciousDriver
import FluidTinyliciousDriver

private final class LiveEvents { var values: [String] = [] }

actor LiveHost {
    private var container: Container?
    private let events = LiveEvents()

    func handle(_ request: JSONValue) async throws -> JSONValue {
        let method = try request.member("method").asString()
        if method == "open" {
            let port = try request.member("port").asInt()
            let id = try request.member("id").asString().description
            let kind = try request.member("kind").asString()
            let resolver: any IUrlResolver
            let factory: any IDocumentServiceFactory
            let url: String
            if kind == "odsp" {
                resolver = OdspDriverUrlResolver()
                factory = OdspDocumentServiceFactory(
                    getStorageToken: { _ in .response(token: "storage:swift", fromCache: nil) },
                    getWebsocketToken: { _ in .response(token: "push:swift", fromCache: nil) })
                url = createOdspUrl(siteUrl: "http://localhost:\(port)", driveId: "b!bG9jYWwtb2RzcA", itemId: id, dataStorePath: "")
            } else {
                resolver = try InsecureTinyliciousUrlResolver(endpoint: "http://localhost:\(port)")
                factory = RouterliciousDocumentServiceFactory(tokenProvider: InsecureTinyliciousTokenProvider())
                url = id
            }
            container = try await loadExistingContainer(ILoadExistingContainerProps(
                request: IRequest(url: url), urlResolver: resolver, documentServiceFactory: factory,
                runtimeFactory: createDOProviderContainerRuntimeFactory(schema: ContainerSchema(initialObjects: ["map": SharedMap.self]), oldestSupportedClient: "2.0.0"),
                summaryMode: .disabled), isolation: self)
            container?.events.on { [events] event in
                switch event {
                case .connected: events.values.append("connected")
                case .disconnected: events.values.append("disconnected")
                case .closed: events.values.append("closed")
                default: break
                }
            }
        }
        guard let container else { throw JSONDecodingError("not opened") }
        guard let root = try await container.getEntryPoint() as? RootDataObject,
              let map = root.initialObjects["map"] as? SharedMap else { throw JSONDecodingError("map missing") }
        if method == "edit" {
            try map.set(request.member("key").asString(), request.member("value"))
            await container.endTurn()
        }
        var state = JSObject<JSONValue>()
        for (key, value) in map.entries() { state[key] = value ?? .null }
        var result = JSObject<JSONValue>()
        result["state"] = .object(state)
        result["connected"] = .bool(container.connectionState == .connected)
        result["clientId"] = container.clientId.map(JSONValue.string) ?? .null
        result["dirty"] = .bool(container.isDirty)
        result["events"] = .array(events.values.map { .string(JSString($0)) })
        return .object(result)
    }
}
