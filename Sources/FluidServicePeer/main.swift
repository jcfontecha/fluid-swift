import FluidContainerLoader
import FluidRouterliciousDriver
import FluidTinyliciousDriver
import FluidDriverDefinitions
import FluidJS
import Foundation

@main struct ServicePeer {
    static func main() async {
        var containers: [String: Container] = [:]
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
                    let storage = DocumentStorageService(endpoint: try params.member("endpoint").asString().description,
                        document: "summary-test", tokens: InsecureTinyliciousTokenProvider())
                    let handle = try await storage.uploadSummaryWithContext(SummaryTree(json: params.member("summary")),
                        context: ISummaryContext(json: params.member("context")), wholeSummary: true)
                    result = .string(handle)
                } else if method == "summaryTrace" {
                    result = try summaryTrace(params)
                } else if method == "open" || method == "openM2" {
                    let container = Container(
                        endpoint: try params.member("endpoint").asString().description,
                        document: try params.member("document").asString().description, loadRuntime: method == "openM2",
                        wholeSummary: try params.asObject()["wholeSummary"] == .bool(true), summaryMode: .disabled)
                    containers[key] = container
                    try await container.connect()
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
                    case "mapView": result = try await container.mapEntries()
                    case "mapEdit":
                        let operation = try params.member("op").asString()
                        let key = try params.member("key").asString()
                        let value = try params.asObject()["value"]
                        try await container.withMap { map in
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
                    default: throw JSONDecodingError("unknown method")
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
