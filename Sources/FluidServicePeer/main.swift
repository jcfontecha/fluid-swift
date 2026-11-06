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

/// tinylicious-client: the tinylicious resolver for the endpoint, over a routerlicious factory with
/// the insecure tinylicious token provider. Each client gets its own factory, as each TS client does.
private func load(_ params: JSONValue, loadRuntime: Bool) async throws -> Container {
    let endpoint = try params.member("endpoint").asString().description
    let document = try params.member("document").asString().description
    return try await loadExistingContainer(ILoadExistingContainerProps(
        request: IRequest(url: document), urlResolver: InsecureTinyliciousUrlResolver(endpoint: endpoint),
        documentServiceFactory: RouterliciousDocumentServiceFactory(tokenProvider: InsecureTinyliciousTokenProvider()),
        runtimeFactory: runtimeFactory(), summaryMode: .disabled, loadRuntime: loadRuntime))
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

@main struct ServicePeer {
    static func main() async {
        var containers: [String: Container] = [:]
        var presenceLogs: [String: PresenceLog] = [:]
        while let line = readLine() {
            var id: JSONValue = .null
            var response = JSObject<JSONValue>()
            response["jsonrpc"] = .string("2.0")
            do {
                let request = try JSON.parse(line)
                id = try request.member("id")
                let params = try request.member("params")
                let key = try params.member("client").asString().description
                let method = try request.member("method").asString()
                let result: JSONValue
                if method == "uploadSummary" {
                    result = try await uploadSummary(params)
                } else if method == "summaryTrace" {
                    result = try summaryTrace(params)
                } else if method == "open" || method == "openM2" {
                    let container = try await load(params, loadRuntime: method == "openM2")
                    containers[key] = container
                    result = try await container.view()
                } else {
                    guard let container = containers[key] else {
                        throw JSONDecodingError("unknown service client")
                    }
                    switch method {
                    case "generateSummary": result = try await container.generateSummary()
                    case "summarizerView": result = try await container.summarizerView()
                    case "stopSummarizer":
                        await container.stopSummarizer()
                        result = .null
                    case "submitSummary":
                        try await container.submitSummarizerMessage(params.member("contents"))
                        result = .null
                    case "enableSummaries":
                        await container.enableSummaries()
                        result = .null
                    case "summarize": result = try await container.summarize()
                    case "mapView":
                        result = try await container.withEntryPoint { entryPoint in
                            var values = JSObject<JSONValue>()
                            for (key, value) in try initialMap(entryPoint).entries() { values[key] = value ?? .null }
                            return .object(values)
                        }
                    case "mapEdit":
                        let operation = try params.member("op").asString()
                        let key = try params.member("key").asString()
                        let value = try params.asObject()["value"]
                        try await container.withEntryPoint { entryPoint in
                            let map = try initialMap(entryPoint)
                            switch operation {
                            case "set": try map.set(key, value)
                            case "delete": _ = try map.delete(key)
                            case "clear": try map.clear()
                            default: throw JSONDecodingError("unknown map operation")
                            }
                        }
                        result = .null
                    case "view": result = try await container.view()
                    case "disconnect":
                        await container.disconnect()
                        result = .null
                    case "reconnect":
                        try await container.connect()
                        result = .null
                    case "signal":
                        try await container.signal(params.member("content").asString().description)
                        result = .null
                    default:
                        guard let presence = try await presenceMethod(method.description, params, key, container, &presenceLogs)
                        else { throw JSONDecodingError("unknown method") }
                        result = presence
                    }
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
        for container in containers.values { await container.disconnect() }
    }
}
