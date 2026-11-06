import Testing
import FluidJS
import FluidDatastore
import FluidTestRuntimeUtils

/// dataStoreRuntime.spec.ts: constructor validation and empty GC graph.
@Test func rejectsSlashInDatastoreID() throws {
    #expect(throws: (any Error).self) { try FluidDataStoreRuntime(id: "before/after", context: MockFluidDataStoreContext()) }
}
@Test func emptyGCDataContainsRoot() throws {
    let runtime = try FluidDataStoreRuntime(id: "store", context: MockFluidDataStoreContext())
    #expect(try runtime.getGCData() == JSON.parse("{\"gcNodes\":{\"/\":[]}}"))
}

import FluidCounter
import FluidMap
import FluidDriverDefinitions

func counterRuntime() throws -> FluidDataStoreRuntime {
    let runtime = try FluidDataStoreRuntime(id: "store", context: MockFluidDataStoreContext())
    try runtime.register(ChannelFactory(SharedCounter.self, snapshotFormatVersion: "0.1"))
    return runtime
}
@Test func channelValidationAndRegistry() throws {
    let runtime = try counterRuntime()
    #expect(throws: (any Error).self) { try runtime.createChannel("bad/id", type: SharedCounter.type) }
    #expect(throws: (any Error).self) { try runtime.createChannel("_reserved", type: SharedCounter.type) }
    #expect(throws: (any Error).self) { try runtime.createChannel("missing", type: "missing") }
    _ = try runtime.createChannel("counter", type: SharedCounter.type)
    #expect(throws: (any Error).self) { try runtime.createChannel("counter", type: SharedCounter.type) }
}
@Test func attachOmitsUnboundChannelsAndIncludesAttributes() throws {
    let runtime = try counterRuntime()
    _ = try runtime.createChannel("unbound", type: SharedCounter.type)
    _ = try runtime.createChannel("bound", type: SharedCounter.type)
    try runtime.bindChannel("bound")
    runtime.makeVisibleAndAttachGraph()
    let summary = try runtime.getAttachSummary()
    #expect(try summary.json.member("tree").asObject().keys == ["bound"])
    let attributes = try summary.json.member("tree").member("bound").member("tree").member(".attributes").member("content").asString()
    #expect(try JSON.parse(attributes.description).member("packageVersion") == .string("3.11.0"))
    #expect(throws: (any Error).self) { try runtime.summarize() }
}
@Test func disposedRuntimeRejectsCreationAndLookup() throws {
    let runtime = try counterRuntime()
    runtime.dispose()
    #expect(throws: (any Error).self) { try runtime.createChannel("x", type: SharedCounter.type) }
    #expect(throws: (any Error).self) { try runtime.getChannel("x") }
}
@Test func channelContextKeepsRemoteOpsLazy() throws {
    let first = try counterRuntime()
    _ = try first.createChannel("counter", type: SharedCounter.type)
    try first.bindChannel("counter")
    first.makeVisibleAndAttachGraph()
    let summary = try first.getAttachSummary()
    let runtime = try counterRuntime()
    try runtime.load(summary)
    #expect(runtime.contexts["counter"]?.isLoaded == false)
    let envelope = try JSON.parse("{\"type\":\"op\",\"clientId\":\"other\",\"sequenceNumber\":1}")
    let op = try JSON.parse("{\"address\":\"counter\",\"contents\":{\"type\":\"increment\",\"incrementAmount\":5}}")
    try runtime.processMessages(envelope: envelope, messages: [ChannelMessage(contents: op), ChannelMessage(contents: op)], local: false)
    #expect(runtime.contexts["counter"]?.isLoaded == false)
    let counter = try #require(runtime.getChannel("counter") as? SharedCounter)
    #expect(counter.value == 10)
}
@Test func rollbackAndStashMetadataAreNotWireData() throws {
    let runtime = try counterRuntime()
    let counter = try #require(runtime.createChannel("counter", type: SharedCounter.type) as? SharedCounter)
    try runtime.bindChannel("counter")
    try runtime.setAttachState(.attaching)
    try runtime.setAttachState(.attached)
    var messages: [DatastoreMessage] = []
    runtime.onSubmit = { messages.append($0) }
    try counter.increment(4)
    let message = try #require(messages.last)
    try runtime.rollback(message)
    #expect(counter.value == 0)
    #expect(runtime.pendingOpCount == 0)
    #expect(runtime.activeLocalOperationActivity == nil)
    #expect(throws: (any Error).self) { try runtime.applyStashedOp(message.json) }
    #expect(runtime.activeLocalOperationActivity == nil)
}

import FluidContainerRuntime
@Test func containerCollectionRoutesRealChannelsAndWrapsSummary() throws {
    let runtime = try counterRuntime()
    let counter = try #require(runtime.createChannel("counter", type: SharedCounter.type) as? SharedCounter)
    try runtime.bindChannel("counter")
    try runtime.setAttachState(.attaching)
    try runtime.setAttachState(.attached)
    let collection = ChannelCollection()
    try collection.registerDatastore(runtime)
    let envelope = try JSON.parse("{\"type\":\"component\",\"clientId\":\"other\",\"sequenceNumber\":1}")
    let content = try JSON.parse("{\"contents\":{\"address\":\"store\",\"contents\":{\"type\":\"op\",\"content\":{\"address\":\"counter\",\"contents\":{\"type\":\"increment\",\"incrementAmount\":5}}}}}")
    try collection.processMessages(envelope: envelope, messagesContent: [content], local: false)
    #expect(counter.value == 5)
    let full = try collection.summarizeDatastore("store", packagePath: ["test"], isRoot: true)
    #expect(try full.json.member("tree").asObject().keys == [".channels", ".component"])
    #expect(try full.readAndParse(".component").member("summaryFormatVersion") == .number(2))
}
@Test func attachedChannelCreationEmitsAttachAndWaitsForAck() throws {
    let runtime = try counterRuntime()
    try runtime.setAttachState(.attaching)
    try runtime.setAttachState(.attached)
    _ = try runtime.createChannel("late", type: SharedCounter.type)
    var messages: [DatastoreMessage] = []
    runtime.onSubmit = { messages.append($0) }
    try runtime.bindChannel("late")
    let attach = try #require(messages.last)
    #expect(attach.type == "attach")
    #expect(throws: (any Error).self) { try runtime.summarize() }
    let envelope = try JSON.parse("{\"type\":\"attach\",\"clientId\":\"client\",\"sequenceNumber\":1}")
    try runtime.processMessages(envelope: envelope, messages: [ChannelMessage(contents: attach.content)], local: true)
    #expect(runtime.pendingOpCount == 0)
    #expect(try runtime.summarize().json.member("tree").asObject().keys == ["late"])
}
@Test func generatedIDsUseDisjointCompactNamespaces() throws {
    let runtime = try counterRuntime()
    _ = try runtime.createChannel(type: SharedCounter.type)
    _ = try runtime.createChannel(type: SharedCounter.type)
    #expect(runtime.contexts["_A"] != nil)
    #expect(runtime.contexts["_C"] != nil)
    try runtime.setAttachState(.attaching)
    try runtime.setAttachState(.attached)
    runtime.generateDocumentUniqueId = { .number(0) }
    _ = try runtime.createChannel(type: SharedCounter.type)
    #expect(runtime.contexts["_B"] != nil)
}
@Test func detachedReloadAttachSummaryDoesNotRealizeChannel() throws {
    let first = try counterRuntime()
    _ = try first.createChannel("counter", type: SharedCounter.type)
    try first.bindChannel("counter")
    first.makeVisibleAndAttachGraph()
    let summary = try first.getAttachSummary()
    let runtime = try counterRuntime()
    try runtime.load(summary, local: true)
    #expect(runtime.contexts["counter"]?.isLoaded == false)
    #expect(try runtime.getAttachSummary() == summary)
    #expect(runtime.contexts["counter"]?.isLoaded == false)
}
@Test func handlePathsPreserveLoneSurrogates() throws {
    let id = JSString(utf16: [0xd800])
    let runtime = try FluidDataStoreRuntime(id: id, context: MockFluidDataStoreContext())
    try runtime.register(ChannelFactory(SharedCounter.self, snapshotFormatVersion: "0.1"))
    _ = try runtime.createChannel(id, type: SharedCounter.type)
    let handle = try runtime.handle(id)
    #expect(handle.absolutePath.utf16 == [47, 0xd800, 47, 0xd800])
}
@Test func datastoreOpsTraverseContainerOutboxAndLocalAck() throws {
    let store = try counterRuntime()
    let counter = try #require(store.createChannel("counter", type: SharedCounter.type) as? SharedCounter)
    try store.bindChannel("counter")
    try store.setAttachState(.attaching)
    try store.setAttachState(.attached)
    let container = try ContainerRuntime(sessionId: "10000000-0000-4000-8000-000000000001", clientId: "client", deltaManager: MockDeltaManager(), quorum: MockQuorumClients())
    try container.channelCollection.registerDatastore(store)
    var wire: [JSONValue] = []
    container.onSubmit = { batch, _, _ in wire.append(contentsOf: batch) }
    try counter.increment(6)
    try container.flush()
    let first = try #require(wire.first)
    let contents = try JSON.parse(first.member("contents").asString().description)
    #expect(try contents.member("type") == .string("component"))
    var message = try JSON.parse("{\"type\":\"op\",\"clientId\":\"client\",\"clientSequenceNumber\":1,\"sequenceNumber\":1,\"minimumSequenceNumber\":0,\"referenceSequenceNumber\":0,\"timestamp\":0}").asObject()
    message["contents"] = contents
    message["metadata"] = try first.asObject()["metadata"]
    _ = try container.process(.object(message))
    #expect(counter.value == 6)
    #expect(store.pendingOpCount == 0)
    var signals: [JSONValue] = []
    container.onSubmitSignal = { signal, _ in signals.append(signal) }
    try store.submitSignal("cursor", content: .number(2))
    try container.flush()
    #expect(signals.count == 1)
    #expect(try signals[0].member("address") == .string("store"))
}
@Test func registryUnderstandsShortNamesAndLegacyURLs() throws {
    let factory = ChannelFactory(SharedCounter.self, snapshotFormatVersion: "0.1")
    let registry = LegacyTypeAwareRegistry([SharedCounter.type: factory])
    #expect(registry.get("counter") != nil)
    #expect(registry.get("https://graph.microsoft.proxy/types/counter") != nil)
    #expect(registry.get("https://unrelated.test/types/counter") == nil)
}
@Test func storedHandleBindsAnOtherwiseUnboundChannel() throws {
    let runtime = try counterRuntime()
    try runtime.register(ChannelFactory(SharedMap.self, snapshotFormatVersion: "0.2"))
    let map = try #require(runtime.createChannel("map", type: SharedMap.type) as? SharedMap)
    _ = try runtime.createChannel("counter", type: SharedCounter.type)
    try map.set("counter", runtime.serializeHandle("counter", bindTo: "map"))
    try runtime.bindChannel("map")
    runtime.makeVisibleAndAttachGraph()
    let summary = try runtime.getAttachSummary()
    #expect(try summary.json.member("tree").asObject().keys == ["map", "counter"])
    #expect(try runtime.getAttachGCData().member("gcNodes").member("/map") == JSON.parse("[\"/store/counter\",\"/store\"]"))
}
@Test func emptyHandlePathUsesItsRoutingContext() throws {
    let root = try FluidDataStoreRuntime(id: "", context: MockFluidDataStoreContext())
    #expect(root.absolutePath == "")
    let runtime = try counterRuntime()
    _ = try runtime.createChannel("", type: SharedCounter.type)
    #expect(try runtime.handle("").absolutePath == "/store")
}

@Test func runtimeReadsDeltaManagerAndQuorumFromItsContext() throws {
    let context = MockFluidDataStoreContext()
    context.mockDeltaManager.lastSequenceNumber = 5
    context.mockDeltaManager.minimumSequenceNumber = 2
    let runtime = try FluidDataStoreRuntime(id: "store", context: context)
    #expect(runtime.deltaManager.lastSequenceNumber == 5)
    #expect(runtime.deltaManager.minimumSequenceNumber == 2)
    context.mockDeltaManager.minimumSequenceNumber = 4
    #expect(runtime.deltaManager.minimumSequenceNumber == 4)
    #expect(runtime.deltaManager.active)
    #expect(runtime.getQuorum() === context.quorum)
}
