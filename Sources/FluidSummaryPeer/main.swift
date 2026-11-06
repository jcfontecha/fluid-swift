import Foundation
import FluidJS
import FluidContainerRuntime
import FluidDriverDefinitions
import FluidDatastore
import FluidMap
import FluidCounter
import FluidTestRuntimeUtils

func run(_ input: JSONValue) throws -> JSONValue {
    let seed = try input.member("seed").asInt()
    if let baseline = try input.asObject()["baseline"] {
        let runtime = try ContainerRuntime(sessionId: "00000000-0000-4000-8000-000000000001", clientId: "reader", deltaManager: MockDeltaManager(), quorum: MockQuorumClients())
        try runtime.loadSnapshot(SummaryTree(json: baseline), factories: [ChannelFactory(SharedMap.self, snapshotFormatVersion: "0.2"), ChannelFactory(SharedDirectory.self, snapshotFormatVersion: "0.1"), ChannelFactory(SharedCounter.self, snapshotFormatVersion: "0.1")])
        if let messages = try input.asObject()["messages"] {
            for message in try messages.asArray() { _ = try runtime.process(message) }
        }
        let full = try runtime.summarize(fullTree: input.member("fullTree") == .bool(true), trackState: true)
        var output = JSObject<JSONValue>()
        output["full"] = full.json
        output["gc"] = try runtime.getGCData()
        var state: [JSONValue] = []
        for id in runtime.channelCollection.datastoreIds.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
            let store = try runtime.channelCollection.getDatastore(id)
            var channels: [JSONValue] = []
            for name in store.contexts.keys.sorted(by: { $0.utf16.lexicographicallyPrecedes($1.utf16) }) {
                let channel = try store.getChannel(name)
                var entry = JSObject<JSONValue>()
                entry["id"] = .string(name)
                let entries: [(JSString, JSONValue?)]
                if let counter = channel as? SharedCounter {
                    entry["value"] = .number(counter.value)
                    channels.append(.object(entry))
                    continue
                } else if let map = channel as? SharedMap { entries = map.entries() }
                else if let directory = channel as? SharedDirectory { entries = try directory.entries() }
                else { throw JSONDecodingError("unexpected channel") }
                entry["entries"] = .array(entries.sorted { $0.0.utf16.lexicographicallyPrecedes($1.0.utf16) }.map { .array([.string($0.0), $0.1 ?? .null]) })
                channels.append(.object(entry))
            }
            var entry = JSObject<JSONValue>()
            entry["id"] = .string(id)
            entry["channels"] = .array(channels)
            state.append(.object(entry))
        }
        output["state"] = .array(state)
        return .object(output)
    }
    var nodes = JSObject<JSONValue>()
    nodes["/"] = .array([.string("/a")])
    for name in ["a", "b", "c", "A", "z", "10", "2", "é", "É", "🙂"] {
        guard let code = name.utf16.first else { throw JSONDecodingError("empty node name") }
        nodes[JSString("/" + name)] = .array((seed + Int(code)) % 3 == 0 ? [.string("/b"), .string("/missing")] : [])
    }
    var graphObject = JSObject<JSONValue>()
    graphObject["gcNodes"] = .object(nodes)
    let graph = JSONValue.object(graphObject)
    let collector = GarbageCollector()
    try collector.collectGarbage(graph, timestamp: Double(seed + 100))
    let first = try collector.summarize(fullTree: false, trackState: true)
    let unacked = try collector.summarize(fullTree: false, trackState: true)
    collector.refreshLatestSummary()
    let incremental = try collector.summarize(fullTree: false, trackState: true)
    let full = try collector.summarize(fullTree: true, trackState: false)
    var result = JSObject<JSONValue>()
    result["mark"] = try runGarbageCollection(graph).json
    result["first"] = first.json
    result["unacked"] = unacked.json
    result["incremental"] = incremental.json
    result["full"] = full.json
    return .object(result)
}
setbuf(stdout, nil)
while let line = readLine() {
    do { print(JSON.stringify(try run(JSON.parse(line)))) }
    catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}
