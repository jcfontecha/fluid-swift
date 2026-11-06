import FluidJS
import FluidDriverDefinitions

/// Container-owned summary bookkeeping from containerRuntime.ts. Upload/ack op orchestration is external.
final class ContainerSummaryState {
    var datastoreAttributes: [JSString: JSONValue] = [:]
    var nextSummaryNumber: Int?
    var baseline: SummaryTree?
    var pending: SummaryTree?
    var lastMessage: JSONValue?
    var nodes: [JSString: SummarizerNode] = [:]
    func node(_ path: JSString) -> SummarizerNode {
        if let node = nodes[path] { return node }
        let node = SummarizerNode()
        nodes[path] = node
        return node
    }
    func recordChange(_ op: JSONValue) throws {
        guard try op.member("type") == .string("component") else { return }
        let envelope = try op.member("contents")
        let store = try envelope.member("address").asString()
        node(store).recordChange()
        let content = try envelope.member("contents")
        // H1 runtime clients may carry opaque datastore payloads without installing a datastore.
        if case .object(let message) = content, message["type"] == .string("op") {
            let channel = try content.member("content").member("address").asString()
            node(JSString(store.description + "/" + channel.description)).recordChange()
        }
    }
}
extension ContainerRuntime {
    /// The loader supplies every sequenced message, including protocol-only messages.
    public func recordSummaryMessage(_ message: JSONValue) throws {
        var fields = JSObject<JSONValue>()
        for key: JSString in ["clientId", "clientSequenceNumber", "minimumSequenceNumber", "referenceSequenceNumber", "sequenceNumber", "timestamp", "type"] { fields[key] = try field(message, key) }
        summaryState.lastMessage = .object(fields)
    }
    /// Registers the dataStoreContext.ts package/root attributes used in .component.
    public func setDatastoreSummaryAttributes(_ id: JSString, packagePath: [JSString], isRoot: Bool) {
        summaryState.datastoreAttributes[id] = object([("pkg", string(JSON.stringify(.array(packagePath.map(JSONValue.string))))), ("summaryFormatVersion", number(2)), ("isRootDataStore", .bool(isRoot))])
    }
    public func getGCData() throws -> JSONValue {
        var nodes = JSObject<JSONValue>()
        var roots: [JSONValue] = []
        for id in channelCollection.datastoreIds {
            let data = try channelCollection.getDatastore(id).getGCData().member("gcNodes").asObject()
            for (path, routes) in data.entries {
                let prefixed = JSString("/" + id.description + (path == "/" ? "" : path.description))
                nodes[prefixed] = routes
            }
            if try summaryState.datastoreAttributes[id]?.member("isRootDataStore") == .bool(true) { roots.append(.string(JSString("/" + id.description))) }
        }
        nodes["/"] = .array(roots)
        for (id, routes) in try blobManager.getGCData().member("gcNodes").asObject().entries { nodes[id] = routes }
        return object([("gcNodes", .object(nodes))])
    }
    /// Ports containerRuntime.ts summarizeInternal/addContainerStateToSummary.
    public func summarize(fullTree: Bool = false, trackState: Bool = true, runGC: Bool = true, timestamp: Double? = nil) throws -> SummaryTreeWithStats {
        try require(!closed, "runtime closed")
        let gcAllowed: Bool
        if let metadata { gcAllowed = try (field(metadata, "gcFeature")?.asInt() ?? 0) > 0 }
        else { gcAllowed = true }
        if runGC && gcAllowed {
            let message = try summaryState.lastMessage ?? metadata.flatMap { try field($0, "lastMessage") ?? field($0, "message") }
            let time = try timestamp ?? message.flatMap { try field($0, "timestamp") }?.asNumber()
            guard let time else { throw JSONDecodingError("0x8a4: GC requires server timestamp") }
            try garbageCollector.collectGarbage(getGCData(), timestamp: time)
        }
        var stores = JSObject<SummaryObject>()
        for id in channelCollection.datastoreIds {
            guard let attributes = summaryState.datastoreAttributes[id] else { throw JSONDecodingError("missing datastore summary attributes") }
            let package = try JSON.parse(attributes.member("pkg").asString().description).asArray().map { try $0.asString() }
            let store = try channelCollection.summarizeDatastore(id, packagePath: package, isRoot: attributes.member("isRootDataStore") == .bool(true))
            if gcAllowed, let state = garbageCollector.state,
               try field(state.member("gcNodes").member(JSString("/" + id.description)), "unreferencedTimestampMs") != nil {
                var value = try store.json.asObject()
                value["unreferenced"] = .bool(true)
                stores[id] = try SummaryObject(json: .object(value))
            } else { stores[id] = try SummaryObject(json: store.json) }
        }
        var entries = JSObject<SummaryObject>()
        entries[".channels"] = .tree(ISummaryTree(tree: stores))
        var fields = JSObject<JSONValue>()
        let source = try metadata?.asObject() ?? JSObject()
        for key: JSString in ["createContainerRuntimeVersion", "createContainerTimestamp"] { fields[key] = source[key] }
        let summaryNumber = try summaryState.nextSummaryNumber ?? (source["summaryNumber"]?.asInt() ?? 0) + 1
        fields["summaryNumber"] = number(summaryNumber)
        summaryState.nextSummaryNumber = summaryNumber + 1
        fields["summaryFormatVersion"] = number(1)
        for key: JSString in ["gcFeature", "gcFeatureMatrix", "sessionExpiryTimeoutMs", "sweepEnabled", "tombstoneTimeoutMs", "telemetryDocumentId", "message", "lastMessage", "documentSchema"] { fields[key] = source[key] }
        func addBlob(_ name: JSString, _ value: JSONValue) {
            entries[name] = .blob(ISummaryBlob(content: .text(JSString(JSON.stringify(value)))))
        }
        if let message = summaryState.lastMessage {
            let explicit = try source["documentSchema"].flatMap { try field($0.member("runtime"), "explicitSchemaControl") } == .bool(true)
            fields[explicit ? "lastMessage" : "message"] = message
        }
        addBlob(".metadata", .object(fields))
        let compressorMode = try source["documentSchema"].flatMap { try field($0.member("runtime"), "idCompressorMode") }
        if compressorMode != nil {
            addBlob(".idCompressor", string(try idCompressor.serialize(false)))
        }
        if let recent = duplicateBatchDetector.getRecentBatchInfoForSummary() { addBlob(".recentBatchInfo", recent) }
        if try !aliases.asArray().isEmpty { addBlob(".aliases", aliases) }
        if let electedSummarizerData { addBlob(".electedSummarizer", electedSummarizerData) }
        let blobs = try SummaryTree(json: blobManager.summarize().member("summary"))
        if case .tree(let tree) = blobs, !tree.tree.keys.isEmpty { entries[".blobs"] = .tree(tree) }
        if gcAllowed && garbageCollector.state != nil {
            entries["gc"] = try SummaryObject(json: garbageCollector.summarize(fullTree: fullTree, trackState: trackState).summary.json)
        }
        let materialized = SummaryTree(tree: entries)
        if trackState {
            summaryState.pending = materialized
            for node in summaryState.nodes.values { node.trackSummary() }
        }
        if trackState && !fullTree, let baseline = summaryState.baseline, case .tree(let previous) = baseline {
            // Container state is always authored. Only datastore/channel nodes participate in summarizer-node reuse.
            if case .tree(let oldStores) = previous.tree[".channels"] {
                var incrementalStores = stores
                for (id, store) in stores.entries {
                    if !summaryState.node(id).hasChanged && oldStores.tree[id] == store { incrementalStores[id] = try summaryHandle(JSString("/.channels/" + id.description)) }
                    else if case .tree(let newStore) = store, case .tree(let oldStore) = oldStores.tree[id],
                            case .tree(let channels) = newStore.tree[".channels"], case .tree(let oldChannels) = oldStore.tree[".channels"] {
                        var children = channels.tree
                        for (name, child) in children.entries where !summaryState.node(JSString(id.description + "/" + name.description)).hasChanged && oldChannels.tree[name] == child {
                            children[name] = try summaryHandle(JSString("/.channels/" + id.description + "/.channels/" + name.description))
                        }
                        var updated = newStore.tree
                        updated[".channels"] = .tree(ISummaryTree(tree: children))
                        incrementalStores[id] = .tree(ISummaryTree(tree: updated))
                    }
                }
                entries[".channels"] = .tree(ISummaryTree(tree: incrementalStores))
            }
        }
        return try SummaryTreeWithStats(SummaryTree(tree: entries))
    }
    /// Called only when a tracked generation is acknowledged; M3b owns the op flow.
    public func refreshLatestSummary() {
        summaryState.baseline = summaryState.pending
        summaryState.pending = nil
        for node in summaryState.nodes.values { node.refreshLatestSummary() }
        garbageCollector.refreshLatestSummary()
    }
}

extension ContainerRuntime {
    /// dataStoreContext.ts addedGCOutboundRoute: serialized handle registration is graph activity,
    /// even when another edit removes the reference before the next mark pass.
    func recordSummaryChange(_ op: JSONValue) throws {
        guard try op.member("type") == .string("component") else { return }
        let envelope = try op.member("contents")
        let store = try envelope.member("address").asString()
        guard channelCollection.datastoreIds.contains(store) else { return }
        try summaryState.recordChange(op)
        let content = try envelope.member("contents")
        guard case .object(let message) = content, message["type"] == .string("op") else { return }
        let channel = try content.member("content").member("address").asString()
        let from = JSString("/" + store.description + "/" + channel.description)
        func visit(_ value: JSONValue) throws {
            switch value {
            case .object(let fields):
                if fields["type"] == .string("__fluid_handle__"), let url = fields["url"] {
                    garbageCollector.addedOutboundReference(from: from, to: try url.asString())
                } else { for (_, child) in fields.entries { try visit(child) } }
            case .array(let values): for child in values { try visit(child) }
            default: break
            }
        }
        try visit(content)
    }
}
