import FluidJS
import FluidDatastore
import FluidDriverDefinitions
import FluidIdCompressor

extension ChannelCollection {
    public var datastoreIds: [JSString] { datastoreOrder }
    public func getDatastore(_ id: JSString) throws -> FluidDataStoreRuntime {
        guard let runtime = datastores[id] else { throw JSONDecodingError("missing datastore \(id)") }
        return runtime
    }
}

extension ContainerRuntime {
    /// Ports containerRuntime.ts loadRuntime and channelCollection.ts snapshot initialization.
    /// Storage resolves git handles before entering this synchronous load path.
    public func loadSnapshot(_ snapshot: SummaryTree, factories: [ChannelFactory]) throws {
        guard case .tree(let tree) = snapshot else { throw JSONDecodingError("unresolved snapshot") }
        if tree.tree[".metadata"] != nil {
            let metadata = try snapshot.readAndParse(".metadata")
            self.metadata = metadata
            let schema = try field(metadata, "documentSchema")
            let explicit = try schema.flatMap { try field($0, "runtime") }.flatMap { try field($0, "explicitSchemaControl") } == .bool(true)
            if let last = try field(metadata, explicit ? "lastMessage" : "message") {
                referenceSequenceNumber = try last.member("sequenceNumber").asInt()
            }
        }
        if tree.tree[".aliases"] != nil { aliases = try snapshot.readAndParse(".aliases") }
        if tree.tree[".electedSummarizer"] != nil {
            electedSummarizerData = try snapshot.readAndParse(".electedSummarizer")
        }
        if case .tree(let gc) = tree.tree["gc"] ?? tree.tree[".gc"] { gcSnapshot = .tree(gc) }
        if case .tree(let blobs) = tree.tree[".blobs"] {
            var ids: [JSString] = []
            var redirects: [(JSString, JSString)] = []
            for (name, value) in blobs.tree.entries {
                if name == ".redirectTable" {
                    for entry in try SummaryTree.tree(blobs).readAndParse(name).asArray() {
                        let pair = try entry.asArray()
                        try require(pair.count == 2, "invalid blob redirect")
                        redirects.append(try (pair[0].asString(), pair[1].asString()))
                    }
                } else if case .attachment(let attachment) = value { ids.append(attachment.id) }
                else { throw JSONDecodingError("expected blob attachment") }
            }
            blobManager.load(ids: ids, redirectTable: redirects)
        }
        blobManager.attachState = .attached
        if tree.tree[".idCompressor"] != nil {
            idCompressor = try IdCompressor.deserialize(snapshot.readAndParse(".idCompressor").asString().description, newSessionId: idCompressor.localSessionId)
        }
        if tree.tree[".recentBatchInfo"] != nil {
            duplicateBatchDetector = try DuplicateBatchDetector(batchIdsFromSnapshot: snapshot.readAndParse(".recentBatchInfo"))
        }
        guard case .tree(let stores) = tree.tree[".channels"] else {
            throw JSONDecodingError("missing runtime .channels")
        }
        for (id, value) in stores.tree.entries {
            guard case .tree(let store) = value else { throw JSONDecodingError("unresolved datastore") }
            let storeSummary = SummaryTree.tree(store)
            _ = try storeSummary.readAndParse(".component")
            guard case .tree(let channels) = store.tree[".channels"] else {
                throw JSONDecodingError("missing datastore .channels")
            }
            let runtime = try FluidDataStoreRuntime(id: id)
            for factory in factories { try runtime.register(factory) }
            try runtime.load(.tree(channels))
            try runtime.setAttachState(.attaching)
            try runtime.setAttachState(.attached)
            try runtime.setConnectionState(false, clientId: nil)
            try channelCollection.registerDatastore(runtime)
        }
        if case .tree(let protocolTree) = tree.tree[".protocol"] {
            let sequence = try SummaryTree.tree(protocolTree).readAndParse("attributes").member("sequenceNumber").asInt()
            try require(referenceSequenceNumber == sequence || metadata == nil, "runtime and protocol snapshot sequence mismatch")
            referenceSequenceNumber = sequence
        }
        connected = false
    }
}
