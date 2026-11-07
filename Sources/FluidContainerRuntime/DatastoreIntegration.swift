import FluidJS
import FluidDatastore
import FluidDriverDefinitions

extension ChannelCollection {
    /// Installs the real datastore layer behind the H4 routing seam.
    public func registerDatastore(_ runtime: FluidDataStoreRuntime) throws {
        try require(datastores[runtime.id] == nil, "datastore already registered")
        datastores[runtime.id] = runtime
        datastoreOrder.append(runtime.id)
        contexts?.insert(runtime.id)
        let id = runtime.id
        runtime.onChannelDirty = { [weak self] channel in self?.onDatastoreChannelDirty(id, channel) }
        runtime.onSubmit = { [weak self] message in
            self?.datastoreOutbound.append((id, message))
            self?.onSubmitDatastoreMessage()
        }
        runtime.onSubmitSignal = { [weak self] type, content, target in
            guard let self else { throw JSONDecodingError("datastore host released") }
            try self.onSubmitDatastoreSignal(id, type, content, target)
        }
    }
    func metadataToken(_ metadata: (any ChannelOpMetadata)?) -> JSONValue? {
        guard let metadata else { return nil }
        nextDatastoreMetadata += 1
        datastoreMetadata[nextDatastoreMetadata] = metadata
        return .number(Double(nextDatastoreMetadata))
    }
    func drainDatastoreMessages(_ submit: (JSONValue, JSONValue?) throws -> Void) throws {
        while !datastoreOutbound.isEmpty {
            let (id, message) = datastoreOutbound[0]
            // channelCollection.ts wrapContextForInnerChannel constructs content before type.
            // Reconnect resubmission must preserve these bytes, not the datastore's local shape.
            let fluidDataStoreContent = object([("content", message.content), ("type", .string(message.type))])
            let contents = object([("address", .string(id)), ("contents", fluidDataStoreContent)])
            try submit(object([("type", string("component")), ("contents", contents)]), metadataToken(message.metadata))
            datastoreOutbound.removeFirst()
        }
    }
    func reSubmitDatastore(_ op: JSONValue, metadata: JSONValue?) throws -> Bool {
        guard try op.member("type") == string("component") else { return false }
        let envelope = try op.member("contents")
        let id = try envelope.member("address").asString()
        guard let runtime = datastores[id] else { return false }
        let content = try envelope.member("contents")
        let token = try metadata.map { try $0.asInt() }
        let md = token.flatMap { datastoreMetadata.removeValue(forKey: $0) }
        try runtime.reSubmit(DatastoreMessage(type: content.member("type").asString(), content: content.member("content"), metadata: md))
        return true
    }
    public func rollbackDatastore(_ op: JSONValue, metadata: JSONValue?) throws {
        let envelope = try op.member("contents")
        let id = try envelope.member("address").asString()
        guard let runtime = datastores[id] else { throw JSONDecodingError("missing datastore") }
        let content = try envelope.member("contents")
        let token = try metadata.map { try $0.asInt() }
        let md = token.flatMap { datastoreMetadata.removeValue(forKey: $0) }
        try runtime.rollback(DatastoreMessage(type: content.member("type").asString(), content: content.member("content"), metadata: md))
    }
    func applyDatastoreStash(_ op: JSONValue) throws -> JSONValue? {
        let envelope = try op.member("contents")
        let id = try envelope.member("address").asString()
        guard let runtime = datastores[id] else { throw JSONDecodingError("missing datastore") }
        return try metadataToken(runtime.applyStashedOp(envelope.member("contents")))
    }
    func ownsDatastoreOp(_ op: JSONValue) throws -> Bool {
        guard try op.member("type") == string("component") else { return false }
        return try datastores[op.member("contents").member("address").asString()] != nil
    }
    func setDatastoreConnectionState(_ connected: Bool, clientId: JSString) throws {
        for runtime in datastores.values { try runtime.setConnectionState(connected, clientId: clientId) }
    }
    /// dataStoreContext.ts summarizeInternal: .channels first, then .component.
    public func summarizeDatastore(_ id: JSString, packagePath: [JSString], isRoot: Bool, attach: Bool = false) throws -> SummaryTree {
        guard let runtime = datastores[id] else { throw JSONDecodingError("missing datastore") }
        let summary = try attach ? runtime.getAttachSummary() : runtime.summarize()
        let attributes = object([("pkg", string(JSON.stringify(.array(packagePath.map(JSONValue.string))))), ("summaryFormatVersion", .number(2)), ("isRootDataStore", .bool(isRoot))])
        var entries = JSObject<SummaryObject>()
        entries[".channels"] = try SummaryObject(json: summary.json)
        entries[".component"] = .blob(ISummaryBlob(content: .text(JSString(JSON.stringify(attributes)))))
        return SummaryTree(tree: entries)
    }
}
