import Foundation
import FluidContainerRuntime
import FluidJS
import FluidDatastore
import FluidCounter
import FluidMap
import FluidDriverDefinitions
import FluidSharedObjectBase
import FluidTestRuntimeUtils

func object(_ entries: [(JSString, JSONValue)]) -> JSONValue {
    var result = JSObject<JSONValue>()
    for (key, value) in entries { result[key] = value }
    return .object(result)
}
func run(_ scenario: JSONValue) throws -> JSONValue {
    let seed = try scenario.member("seed").asInt()
    let runtime = try FluidDataStoreRuntime(id: "store", context: MockFluidDataStoreContext())
    try runtime.register(ChannelFactory(SharedMap.self, snapshotFormatVersion: "0.2"))
    try runtime.register(ChannelFactory(SharedDirectory.self, snapshotFormatVersion: "0.1"))
    try runtime.register(ChannelFactory(SharedCounter.self, snapshotFormatVersion: "0.1"))
    guard let map = try runtime.createChannel("map", type: SharedMap.type) as? SharedMap,
          let directory = try runtime.createChannel("directory", type: SharedDirectory.type) as? SharedDirectory,
          let counter = try runtime.createChannel("counter", type: seed % 2 == 0 ? "counter" : SharedCounter.type) as? SharedCounter else { throw DatastoreError("factory type mismatch") }
    try map.set("seed", .number(Double(seed)))
    try directory.set("seed", .number(Double(seed)))
    try counter.increment(Double(seed % 17))
    for i in 0..<8 {
        let key = JSString(String((seed * 17 + i * 7) % 11))
        let text = i % 2 == 0 ? JSString(utf16: [108, 111, 110, 101, 0xd800]) : JSString("emoji🙂")
        try map.set(key, object([("n", .number(Double(seed - i))), ("text", .string(text))]))
        if (seed + i) % 3 == 0 { _ = try map.delete(key) }
    }
    try map.set("ref", runtime.serializeHandle("counter", bindTo: "map"))
    for id: JSString in ["map", "directory"] { try runtime.bindChannel(id) }
    runtime.makeVisibleAndAttachGraph()
    let attach = try runtime.getAttachSummary()
    try runtime.setAttachState(.attaching)
    try runtime.setAttachState(.attached)
    var wire: [DatastoreMessage] = []
    runtime.onSubmit = { wire.append($0) }
    try counter.increment(9)
    guard let rolled = wire.popLast() else { throw DatastoreError("missing rollback op") }
    try runtime.rollback(rolled)
    try map.set("counter", runtime.serializeHandle("counter", bindTo: "map"))
    try counter.increment(3)
    try directory.set("hello", .string(JSString("value\(seed)")))
    guard let last = wire.popLast() else { throw DatastoreError("missing resubmit op") }
    try runtime.setConnectionState(false, clientId: "client")
    try runtime.setConnectionState(true, clientId: "client")
    try runtime.reSubmit(last)
    var sequenceNumber = 0
    func envelope(_ type: JSString, _ client: JSString) -> JSONValue {
        sequenceNumber += 1
        return object([("type", .string(type)), ("clientId", .string(client)), ("sequenceNumber", .number(Double(sequenceNumber))), ("minimumSequenceNumber", .number(0)), ("referenceSequenceNumber", .number(0)), ("timestamp", .number(0))])
    }
    let submitted = wire
    for (i, message) in submitted.enumerated() {
        try runtime.processMessages(envelope: envelope(message.type, "client"), messages: [ChannelMessage(contents: message.content, metadata: message.metadata, clientSequenceNumber: i + 1)], local: true)
    }
    try runtime.processMessages(envelope: envelope("op", "other"), messages: [1, 2].map { amount in
        ChannelMessage(contents: object([("address", .string("counter")), ("contents", object([("type", .string("increment")), ("incrementAmount", .number(Double(amount)))]))]), clientSequenceNumber: amount)
    }, local: false)
    var signals: [JSONValue] = []
    var signalWire: [JSONValue] = []
    runtime.onSubmitSignal = { type, content, target in
        var fields = JSObject<JSONValue>()
        fields["type"] = .string(type)
        fields["content"] = content
        fields["targetClientId"] = target.map(JSONValue.string)
        signalWire.append(.object(fields))
    }
    try runtime.submitSignal("cursor", content: .number(Double(seed)), targetClientId: seed % 2 == 0 ? "target" : nil)
    runtime.onSignal = { signals.append(object([("message", $0), ("local", .bool($1))])) }
    runtime.processSignal(object([("clientId", .string("other")), ("type", .string("test")), ("content", .number(Double(seed)))]), local: false)
    let summary = try runtime.summarize()
    let gc = try runtime.getGCData()
    let reload = try FluidDataStoreRuntime(id: "store", context: MockFluidDataStoreContext())
    try reload.register(ChannelFactory(SharedMap.self, snapshotFormatVersion: "0.2"))
    try reload.register(ChannelFactory(SharedDirectory.self, snapshotFormatVersion: "0.1"))
    try reload.register(ChannelFactory(SharedCounter.self, snapshotFormatVersion: "0.1"))
    try reload.load(summary)
    try reload.setAttachState(.attaching)
    try reload.setAttachState(.attached)
    reload.onSubmit = { wire.append($0) }
    try reload.processMessages(envelope: envelope("op", "other"), messages: [ChannelMessage(contents: object([("address", .string("counter")), ("contents", object([("type", .string("increment")), ("incrementAmount", .number(7))]))]), clientSequenceNumber: 1)], local: false)
    let stashed = object([("type", .string("op")), ("content", object([("address", .string("counter")), ("contents", object([("type", .string("increment")), ("incrementAmount", .number(4))]))]))])
    let stashedMetadata = try reload.applyStashedOp(stashed)
    try reload.reSubmit(DatastoreMessage(type: "op", content: stashed.member("content"), metadata: stashedMetadata))
    let reloadedSummary = try reload.summarize()
    let reloadedGC = try reload.getGCData()
    guard let late = try runtime.createChannel("late", type: SharedCounter.type) as? SharedCounter else { throw DatastoreError("factory type mismatch") }
    try late.increment(2)
    try runtime.bindChannel("late")
    guard let attachMessage = wire.last else { throw DatastoreError("missing attach message") }
    try reload.processMessages(envelope: envelope(attachMessage.type, "other"), messages: [ChannelMessage(contents: attachMessage.content, clientSequenceNumber: 1)], local: false)
    let stashRuntime = try FluidDataStoreRuntime(id: "store", context: MockFluidDataStoreContext())
    try stashRuntime.register(ChannelFactory(SharedCounter.self, snapshotFormatVersion: "0.1"))
    try stashRuntime.setAttachState(.attaching)
    try stashRuntime.setAttachState(.attached)
    _ = try stashRuntime.applyStashedOp(attachMessage.json)
    guard let stashedLate = try stashRuntime.getChannel("late") as? SharedCounter, stashedLate.value == 2 else { throw DatastoreError("stash attach failed") }
    let lateSummary = try reload.summarize()
    let collection = ChannelCollection()
    try collection.registerDatastore(reload)
    let fullSummary = try collection.summarizeDatastore("store", packagePath: ["test"], isRoot: true)
    return try object([("wire", .array(wire.map { object([("type", .string("component")), ("contents", object([("address", .string("store")), ("contents", $0.json)]))]) })), ("attach", attach.json), ("summary", summary.json), ("gc", gc), ("reloadedSummary", reloadedSummary.json), ("reloadedGC", reloadedGC), ("lateSummary", lateSummary.json), ("fullSummary", fullSummary.json), ("signals", .array(signals)), ("signalWire", .array(signalWire)), ("storedHandle", map.get("counter")?.member("url") ?? .null), ("handles", .array(["map", "directory", "counter"].map { .string(try runtime.handle($0).absolutePath) })), ("state", object([("counter", .number(counter.value)), ("map", map.get("seed") ?? .null), ("directory", directory.get("hello") ?? .null)]))])
}
while let line = readLine() {
    do { FileHandle.standardOutput.write(Data((JSON.stringify(try run(JSON.parse(line))) + "\n").utf8)) }
    catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}
