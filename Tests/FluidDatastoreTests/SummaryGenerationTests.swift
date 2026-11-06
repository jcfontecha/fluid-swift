import Testing
import FluidJS
import FluidDatastore
import FluidContainerRuntime
import FluidCounter
import FluidTestRuntimeUtils

@Test func revertedLocalEditStillInvalidatesSummaryHandle() throws {
    let container = try ContainerRuntime(sessionId: "00000000-0000-4000-8000-000000000001", clientId: "writer", deltaManager: MockDeltaManager(), quorum: MockQuorumClients())
    let store = try FluidDataStoreRuntime(id: "store", context: container)
    try store.register(ChannelFactory(SharedCounter.self, snapshotFormatVersion: "0.1"))
    let counter = try #require(store.createChannel("counter", type: SharedCounter.type) as? SharedCounter)
    try store.bindChannel("counter")
    store.makeVisibleAndAttachGraph()
    try store.setAttachState(.attaching)
    try store.setAttachState(.attached)
    try container.channelCollection.registerDatastore(store)
    container.setDatastoreSummaryAttributes("store", packagePath: ["test"], isRoot: true)
    _ = try container.summarize(fullTree: true, runGC: false)
    container.refreshLatestSummary()
    let unchanged = try container.summarize(runGC: false)
    #expect(try unchanged.summary.json.member("tree").member(".channels").member("tree").member("store").member("type") == .number(3))
    try counter.increment(1)
    try counter.increment(-1)
    let changed = try container.summarize(runGC: false)
    let storeTree = try changed.summary.json.member("tree").member(".channels").member("tree").member("store")
    #expect(try storeTree.member("type") == .number(1))
    #expect(try storeTree.member("tree").member(".channels").member("tree").member("counter").member("type") == .number(1))
}
