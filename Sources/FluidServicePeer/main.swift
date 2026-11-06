import Foundation
import FluidJS
import FluidContainerLoader

@main struct ServicePeer {
    static func main() async {
        var containers: [String: ServiceContainer] = [:]
        while let line = readLine() {
            var id: JSONValue = .null
            var response = JSObject<JSONValue>(); response["jsonrpc"] = .string("2.0")
            do {
                let request = try JSON.parse(line); id = try request.member("id")
                let params = try request.member("params"), key = try params.member("client").asString().description
                let method = try request.member("method").asString()
                let result: JSONValue
                if method == "open" {
                    let container = ServiceContainer(endpoint: try params.member("endpoint").asString().description, document: try params.member("document").asString().description)
                    containers[key] = container; try await container.connect(); result = try await container.view()
                } else {
                    guard let container = containers[key] else { throw JSONDecodingError("unknown service client") }
                    switch method {
                    case "view": result = try await container.view()
                    case "disconnect": await container.disconnect(); result = .null
                    case "reconnect": try await container.connect(); result = .null
                    case "signal": try await container.signal(params.member("content").asString().description); result = .null
                    default: throw JSONDecodingError("unknown method")
                    }
                }
                response["result"] = result
            } catch {
                var failure = JSObject<JSONValue>(); failure["code"] = .number(-32000); failure["message"] = .string(JSString(String(describing: error))); response["error"] = .object(failure)
            }
            response["id"] = id
            FileHandle.standardOutput.write(Data((JSON.stringify(.object(response)) + "\n").utf8))
        }
        for container in containers.values { await container.disconnect() }
    }
}
