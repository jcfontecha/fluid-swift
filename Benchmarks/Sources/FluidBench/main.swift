import Foundation
import Darwin
import FluidJS
import FluidMap
import BenchCounter
import BenchSequence
import BenchMergeTree
import FluidIdCompressor
import FluidDriverDefinitions
import FluidDatastore
import FluidContainerRuntime
import BenchTestRuntimeUtils

func object(_ pairs: [(JSString, JSONValue)]) -> JSONValue {
    var o = JSObject<JSONValue>()
    for (k, v) in pairs { o[k] = v }
    return .object(o)
}
func number(_ i: Int) -> JSONValue { .number(Double(i)) }
func message(_ op: JSONValue, _ seq: Int, sender: String = "remote") -> JSONValue {
    object([("contents", op), ("type", .string("op")), ("clientId", .string(JSString(sender))),
            ("sequenceNumber", number(seq)), ("referenceSequenceNumber", number(seq - 1)),
            ("minimumSequenceNumber", number(max(0, seq - 64))), ("clientSequenceNumber", number(seq)),
            ("timestamp", number(0))])
}
struct Random {
    var state: UInt32 = 0x12345678
    mutating func next(_ bound: Int) -> Int {
        state = state &* 1664525 &+ 1013904223
        return Int(state) % bound
    }
}
func memory() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS)
    return info.resident_size_max
}
func measure(_ name: String, count: Int, _ body: () throws -> Int) rethrows {
    let baseline = memory()
    let clock = ContinuousClock()
    let start = clock.now
    let checksum = try body()
    let d = start.duration(to: clock.now).components
    let ms = Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    print("{\"workload\":\"\(name)\",\"count\":\(count),\"ms\":\(ms),\"peakRSSBytes\":\(memory()),\"setupPeakRSSBytes\":\(baseline),\"checksum\":\(checksum)}")
    fflush(stdout)
}
let name = CommandLine.arguments.dropFirst().first ?? "string-10000"
for _ in 0..<(CommandLine.arguments.contains("--profile") ? 30 : 1) {
do {
    if name.hasPrefix("string-") || name == "typing" {
        let size = name == "typing" ? 1_000_000 : Int(name.dropFirst(7))!
        let s = SharedString(id: "local")
        try s.insertText(0, JSString(String(repeating: "x", count: size)))
        s.bindToContext()
        s.attach()
        var rng = Random()
        let count = name == "typing" ? 100 : 3000
        try measure(name, count: count) {
            for i in 1...count {
                let pos = rng.next(s.client.length - 2)
                if name == "typing" {
                    let op = try s.client.insert(at: pos, text: "z")
                    try s.client.process(op, sender: "attached", sequence: i, referenceSequence: i - 1)
                    try s.client.advanceMinimum(to: max(0, i - 64))
                } else {
                    let op: JSONValue
                    switch i % 3 {
                    case 0: op = object([("type", number(0)), ("pos1", number(pos)), ("seg", .string("z"))])
                    case 1: op = object([("type", number(1)), ("pos1", number(pos)), ("pos2", number(pos + 1))])
                    default: op = object([("type", number(2)), ("pos1", number(pos)), ("pos2", number(pos + 1)), ("props", object([("bold", .bool(true))]))])
                    }
                    try s.process(SequencedMessage(json: message(op, i, sender: "remote\(i % 16)")), local: false, localOpMetadata: nil)
                }
            }
            precondition(s.client.length == size + (name == "typing" ? count : 0))
            return s.client.length
        }
    } else if name == "map-ops" {
        let map = SharedMap(id: "map")
        try measure(name, count: 10000) {
            for i in 1...10000 {
                let key = JSONValue.string(JSString("k\(i / 2)"))
                let op = i % 2 == 1
                    ? object([("type", .string("set")), ("key", key), ("value", object([("type", .string("Plain")), ("value", number(i))]))])
                    : object([("type", .string("delete")), ("key", .string(JSString("k\((i - 1) / 2)")))])
                try map.process(SequencedMessage(json: message(op, i)), local: false, localOpMetadata: nil)
            }
            precondition(map.size == 0)
            return map.size
        }
    } else if name == "map-summary" || name == "map-load" {
        let map = SharedMap(id: "map")
        for i in 0..<100000 { try map.set(JSString("k\(i)"), number(i)) }
        if name == "map-summary" {
            measure(name, count: 100000) {
                let summary = map.summarize()
                guard case .tree(let tree) = summary else { preconditionFailure("Expected full summary") }
                return tree.tree.count
            }
        } else {
            let summary = map.summarize()
            try measure(name, count: 100000) {
                let loaded = try SharedMap.load(id: "loaded", summary: summary)
                precondition(loaded.size == 100000)
                return loaded.size
            }
        }
    } else if name == "ids" {
        let c = try IdCompressor("00000000-0000-4000-8000-000000000001", writeVersion: 2)
        try measure(name, count: 100000) {
            var total = 0.0
            for _ in 0..<100 {
                var ids: [Double] = []
                for _ in 0..<1000 { ids.append(try c.generateCompressedId()) }
                try c.finalizeCreationRange(c.takeNextCreationRange())
                for id in ids {
                    let op = try c.normalizeToOpSpace(id)
                    total += try c.normalizeToSessionSpace(op, originSessionId: c.localSessionId)
                }
            }
            return Int(total)
        }
    } else if name == "container" {
        let path = ProcessInfo.processInfo.environment["FLUID_BENCH_FIXTURE"] ?? Bundle.main.bundlePath + "/container.json"
        let fixture = try JSON.parse(String(contentsOfFile: path, encoding: .utf8))
        let summary = try SummaryTree(json: fixture.member("summary"))
        let ops = try fixture.member("messages").asArray()
        try measure(name, count: ops.count) {
            let runtime = try ContainerRuntime(sessionId: "00000000-0000-4000-8000-000000000001", clientId: "reader", deltaManager: MockDeltaManager(), quorum: MockQuorumClients())
            try runtime.loadSnapshot(summary, factories: [ChannelFactory(SharedMap.self, snapshotFormatVersion: "0.2"), ChannelFactory(SharedDirectory.self, snapshotFormatVersion: "0.1"), ChannelFactory(SharedCounter.self, snapshotFormatVersion: "0.1")])
            for op in ops { _ = try runtime.process(op) }
            let store = try runtime.channelCollection.getDatastore("A")
            let map = try store.getChannel("map") as! SharedMap
            precondition(map.size == 103003 && map.get("catchup2999") == number(2999))
            return map.size
        }
    } else { fatalError("Unknown workload") }
} catch {
    fputs("\(name): \(error)\n", stderr)
    exit(1)
}

}
