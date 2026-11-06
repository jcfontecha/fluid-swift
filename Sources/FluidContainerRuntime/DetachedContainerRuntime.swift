import FluidDatastore
import FluidDatastoreDefinitions
import FluidDriverDefinitions
import FluidJS

extension ContainerRuntime {
    /// containerRuntime.ts: new runtimes start disconnected and locally attached only.
    public func initializeDetached() throws {
        connected = false
        blobManager.attachState = .detached
        electedSummarizerData = object([("electionSequenceNumber", number(0))])
    }

    /// channelCollection.ts createDataStore: detached datastore IDs use the even compact namespace.
    public func createDetachedDataStore(packagePath: [JSString], factories: [ChannelFactory]) throws -> FluidDataStoreRuntime {
        try require(blobManager.attachState == .detached, "container must be detached")
        var value = channelCollection.datastoreIds.count * 2
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ(abcdefghijklmnopqrstuvwxyz)0123456789".utf16)
        var units: [UInt16] = []
        repeat {
            units.insert(alphabet[value % 64], at: 0)
            value = value / 64 - 1
        } while value != -1
        let id = JSString(utf16: ContiguousArray(units))
        let store = try FluidDataStoreRuntime(id: id, context: self)
        for factory in factories {
            try store.register(factory)
        }
        try store.setConnectionState(false, clientId: nil)
        try channelCollection.registerDatastore(store)
        setDatastoreSummaryAttributes(id, packagePath: packagePath, isRoot: false)
        return store
    }

    /// channelCollection.ts: a detached alias is applied immediately without a sequenced op.
    public func setDetachedAlias(_ alias: JSString, datastoreId: JSString) throws {
        try require(blobManager.attachState == .detached, "container must be detached")
        var entries = try aliases.asArray()
        try require(!entries.contains { (try? $0.asArray().first) == .string(alias) }, "alias already exists")
        let store = try channelCollection.getDatastore(datastoreId)
        store.makeVisibleAndAttachGraph()
        guard var attributes = try summaryState.datastoreAttributes[datastoreId]?.asObject() else {
            throw JSONDecodingError("missing datastore summary attributes")
        }
        attributes["isRootDataStore"] = .bool(true)
        summaryState.datastoreAttributes[datastoreId] = .object(attributes)
        entries.append(.array([.string(alias), .string(datastoreId)]))
        aliases = .array(entries)
    }

    /// containerRuntime.ts createSummary: finalize local allocations before the attach summary.
    public func createSummary(blobRedirectTable: [(JSString, JSString)]? = nil) throws -> SummaryTree {
        try require(blobManager.attachState == .detached, "container must be detached")
        if let blobRedirectTable {
            try blobManager.patchRedirectTable(blobRedirectTable)
        }
        let range = try idCompressor.takeNextCreationRange()
        try require(range.ids == nil || range.ids?.firstGenCount == 1, "0x93e: range taken while detached")
        try idCompressor.finalizeCreationRange(range)
        return try summarize(fullTree: true, trackState: false, runGC: false, attaching: true).summary
    }

    public func setAttachState(_ state: BlobManager.AttachState) throws {
        for id in channelCollection.datastoreIds {
            try channelCollection.getDatastore(id).setAttachState(state == .attaching ? .attaching : .attached)
        }
        try blobManager.setAttachState(state == .attaching ? .attaching : .attached)
    }
}
