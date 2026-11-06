import FluidCounter
import FluidJS
import FluidProtocol
import FluidTestRuntimeUtils
import Foundation

/// Swift peer for the differential harness: JSON-RPC 2.0 over stdio, one JSON object per line
/// (harness/PROTOCOL.md).
struct PeerError: Error, CustomStringConvertible {
    let description: String
}

final class Peer {
    private var clients: [JSString: MockContainerRuntime<SharedCounter>] = [:]

    private func client(_ params: JSONValue) throws -> MockContainerRuntime<SharedCounter> {
        let clientId = try params.member("clientId").asString()
        guard let runtime = clients[clientId] else { throw PeerError(description: "unknown client \(clientId)") }
        return runtime
    }

    private func outbound(_ runtime: MockContainerRuntime<SharedCounter>) -> JSONValue {
        var result = JSObject<JSONValue>()
        result["outbound"] = .array(runtime.takeOutbound().map(\.json))
        return .object(result)
    }

    func handle(_ method: JSString, _ params: JSONValue) throws -> JSONValue {
        switch method {
        case "hello":
            var result = JSObject<JSONValue>()
            result["implementation"] = .string("swift")
            result["ddsTypes"] = .array([.string(SharedCounter.type)])
            return .object(result)

        case "createClient":
            let clientId = try params.member("clientId").asString()
            guard clients[clientId] == nil else { throw PeerError(description: "duplicate client \(clientId)") }
            let ddsType = try params.member("ddsType").asString()
            guard ddsType == SharedCounter.type else { throw PeerError(description: "unsupported ddsType \(ddsType)") }
            let channelId = try params.member("channelId").asString()
            let summary = try params.member("summary")
            let channel = summary == .null
                ? SharedCounter(id: channelId)
                : try SharedCounter.load(id: channelId, summary: SummaryTree(json: summary))
            clients[clientId] = MockContainerRuntime(
                clientId: clientId,
                channel: channel,
                lastSequenceNumber: try params.member("sequenceNumber").asInt()
            )
            return .object(JSObject())

        case "edit":
            let runtime = try client(params)
            let edit = try params.member("edit")
            switch try edit.member("kind").asString() {
            case "increment":
                try runtime.channel.increment(try edit.member("amount").asNumber())
            case let kind:
                throw PeerError(description: "unsupported edit kind \(kind)")
            }
            return outbound(runtime)

        case "process":
            let runtime = try client(params)
            try runtime.process(SequencedMessage(json: params.member("message")))
            return outbound(runtime)

        case "state":
            var state = JSObject<JSONValue>()
            state["value"] = .number(try client(params).channel.value)
            var result = JSObject<JSONValue>()
            result["state"] = .object(state)
            return .object(result)

        case "summarize":
            var result = JSObject<JSONValue>()
            result["summary"] = try client(params).channel.summarize().json
            return .object(result)

        case "disposeClient":
            let clientId = try params.member("clientId").asString()
            guard clients.removeValue(forKey: clientId) != nil else {
                throw PeerError(description: "unknown client \(clientId)")
            }
            return .object(JSObject())

        default:
            throw PeerError(description: "unknown method \(method)")
        }
    }
}

func respond(id: JSONValue, _ outcome: Result<JSONValue, any Error>) {
    var response = JSObject<JSONValue>()
    response["jsonrpc"] = .string("2.0")
    response["id"] = id
    switch outcome {
    case .success(let result):
        response["result"] = result
    case .failure(let error):
        var errorObject = JSObject<JSONValue>()
        errorObject["code"] = .number(-32000)
        errorObject["message"] = .string(JSString(String(describing: error)))
        response["error"] = .object(errorObject)
    }
    FileHandle.standardOutput.write(Data((JSON.stringify(.object(response)) + "\n").utf8))
}

let peer = Peer()

while let line = readLine() {
    let request: JSONValue
    do {
        request = try JSON.parse(line)
    } catch {
        respond(id: .null, .failure(error))
        continue
    }
    let id = (try? request.member("id")) ?? .null
    respond(id: id, Result {
        try peer.handle(request.member("method").asString(), request.member("params"))
    })
}
