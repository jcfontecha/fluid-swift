import FluidContainerLoader
import FluidDriverDefinitions
import FluidJS
import FluidMap
import FluidRouterliciousDriver
import FluidStatic
import FluidTinyliciousDriver
import Foundation

/// The service harnesses' schema (harness/src/service*.ts): one SharedMap named "map", created by
/// TS with compatibility "2.0.0".
private func runtimeFactory() throws -> DOProviderContainerRuntimeFactory {
    try createDOProviderContainerRuntimeFactory(
        schema: ContainerSchema(initialObjects: ["map": SharedMap.self]), oldestSupportedClient: "2.0.0")
}

/// fluid-static: the root data object is the container's entry point.
private func initialMap(_ entryPoint: AnyObject) throws -> SharedMap {
    guard let root = entryPoint as? RootDataObject, let map = root.initialObjects["map"] as? SharedMap else {
        throw JSONDecodingError("initialObject is not a SharedMap")
    }
    return map
}

/// The whole-summary upload contract (harness/src/service-m3-upload.ts), through the storage
/// endpoint the tinylicious resolver gives the recording server.
private func uploadSummary(_ params: JSONValue) async throws -> JSONValue {
    let resolver = try InsecureTinyliciousUrlResolver(endpoint: params.member("endpoint").asString().description)
    guard let resolved = try await resolver.resolve(IRequest(url: "summary-test")),
        let storageUrl = resolved.endpoints["storageUrl"]
    else { throw JSONDecodingError("unresolved summary-test") }
    let storage = RestClient(
        service: .storage, baseUrl: storageUrl.description, tenantId: "tinylicious", documentId: "summary-test",
        tokens: InsecureTinyliciousTokenProvider())
    let context = try ISummaryContext(json: params.member("context"))
    return .string(try await WholeSummaryUploadManager(manager: storage).writeSummaryTree(
        SummaryTree(json: params.member("summary")), parentHandle: context.ackHandle))
}

/// Owns every service client's container (ARCHITECTURE.md section 2): each container's event loop
/// and every request against it run on this actor, so the blocking `readLine()` on the main thread
/// never starves them. Requests arrive one at a time and each is one turn: its edits leave through
/// the container's turn-based flush, which `endTurn` waits for before the reply, as a TS client's
/// microtask flush runs before its next request.
private actor PeerHost {
    private var containers: [String: Container] = [:]
    private var presenceLogs: [String: PresenceLog] = [:]

    /// tinylicious-client: the tinylicious resolver for the endpoint, over a routerlicious factory
    /// with the insecure tinylicious token provider. Each client gets its own factory, as each TS
    /// client does.
    private func load(_ params: JSONValue, loadRuntime: Bool) async throws -> Container {
        let endpoint = try params.member("endpoint").asString().description
        let document = try params.member("document").asString().description
        return try await loadExistingContainer(ILoadExistingContainerProps(
            request: IRequest(url: document), urlResolver: InsecureTinyliciousUrlResolver(endpoint: endpoint),
            documentServiceFactory: RouterliciousDocumentServiceFactory(tokenProvider: InsecureTinyliciousTokenProvider()),
            runtimeFactory: runtimeFactory(), summaryMode: .disabled, loadRuntime: loadRuntime), isolation: self)
    }

    func handle(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let key = try params.member("client").asString().description
        do {
            let result = try await perform(method, params, key: key)
            await containers[key]?.endTurn()
            return result
        } catch {
            await containers[key]?.endTurn()
            throw error
        }
    }

    private func perform(_ method: String, _ params: JSONValue, key: String) async throws -> JSONValue {
        if method == "open" || method == "openM2" {
            let container = try await load(params, loadRuntime: method == "openM2")
            containers[key] = container
            return try container.view()
        }
        guard let container = containers[key] else {
            throw JSONDecodingError("unknown service client")
        }
        switch method {
        case "generateSummary": return try container.generateSummary()
        case "summarizerView": return try await container.summarizerView()
        case "stopSummarizer":
            await container.stopSummarizer()
            return .null
        case "submitSummary":
            try await container.submitSummarizerMessage(params.member("contents"))
            return .null
        case "enableSummaries":
            container.enableSummaries()
            return .null
        case "summarize": return try await container.summarize()
        case "mapView":
            var values = JSObject<JSONValue>()
            for (key, value) in try initialMap(await container.getEntryPoint()).entries() { values[key] = value ?? .null }
            return .object(values)
        case "mapEdit":
            let operation = try params.member("op").asString()
            let key = try params.member("key").asString()
            let value = try params.asObject()["value"]
            let map = try initialMap(await container.getEntryPoint())
            switch operation {
            case "set": try map.set(key, value)
            case "delete": _ = try map.delete(key)
            case "clear": try map.clear()
            default: throw JSONDecodingError("unknown map operation")
            }
            return .null
        case "view": return try container.view()
        case "disconnect":
            container.disconnect()
            return .null
        case "reconnect":
            container.connect()
            return .null
        case "signal":
            try container.signal(params.member("content").asString().description)
            return .null
        default:
            guard let presence = try presenceMethod(method, params, key, container, &presenceLogs)
            else { throw JSONDecodingError("unknown method") }
            return presence
        }
    }

    func disconnectAll() {
        for container in containers.values { container.disconnect() }
    }
}

@main struct ServicePeer {
    static func main() async {
        let host = PeerHost()
        while let line = readLine() {
            var id: JSONValue = .null
            var response = JSObject<JSONValue>()
            response["jsonrpc"] = .string("2.0")
            do {
                let request = try JSON.parse(line)
                id = try request.member("id")
                let params = try request.member("params")
                let method = try request.member("method").asString().description
                let result: JSONValue
                if method == "uploadSummary" {
                    result = try await uploadSummary(params)
                } else if method == "summaryTrace" {
                    result = try summaryTrace(params)
                } else {
                    result = try await host.handle(method, params)
                }
                response["result"] = result
            } catch {
                var failure = JSObject<JSONValue>()
                failure["code"] = .number(-32000)
                failure["message"] = .string(JSString(String(describing: error)))
                response["error"] = .object(failure)
            }
            response["id"] = id
            FileHandle.standardOutput.write(Data((JSON.stringify(.object(response)) + "\n").utf8))
        }
        await host.disconnectAll()
    }
}
