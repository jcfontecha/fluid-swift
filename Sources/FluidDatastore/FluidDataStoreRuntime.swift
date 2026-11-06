import Foundation
import FluidJS
import FluidDriverDefinitions
import FluidDatastoreDefinitions
import FluidSharedObjectBase

public enum DocumentUniqueId {
    case number(Int)
    case uuid(JSString)
}

public struct DatastoreMessage {
    public init(type: JSString, content: JSONValue, metadata: (any ChannelOpMetadata)? = nil) {
        self.type = type
        self.content = content
        self.metadata = metadata
    }
    public let type: JSString
    public let content: JSONValue
    public let metadata: (any ChannelOpMetadata)?
    public var json: JSONValue { dsObject([("type", .string(type)), ("content", content)]) }
}
/// Ports packages/runtime/datastore/src/dataStoreRuntime.ts on the container's synchronous executor.
public final class FluidDataStoreRuntime: IFluidDataStoreRuntime {
    public let id: JSString
    public var clientId: JSString? = "client"
    public private(set) var connected = true
    public private(set) var attachState: AttachState = .detached
    public private(set) var disposed = false
    public private(set) var activeLocalOperationActivity: JSString?
    public private(set) var pendingOpCount = 0
    public private(set) var contexts: [JSString: ChannelContext] = [:]
    private var order: [JSString] = []
    private var factories: [JSString: ChannelFactory] = [:]
    private var pendingAttach: Set<JSString> = []
    private var visible = false
    public var generateDocumentUniqueId: () -> DocumentUniqueId = { .uuid(JSString(UUID().uuidString.lowercased())) }
    /// runtime-utils/utils.ts encodeCompactIdToString, with detached-even / attached-odd namespaces.
    @discardableResult public func createChannel(type: JSString) throws -> any Channel {
        var number = 2 * order.count
        if attachState != .detached {
            switch generateDocumentUniqueId() {
            case .number(let id): number = 2 * id + 1
            case .uuid(let id): return try createChannel(id, type: type, generated: true)
            }
        }
        try check(number >= 0, "invalid generated id")
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ(abcdefghijklmnopqrstuvwxyz)0123456789".utf16)
        var encoded: [UInt16] = []
        repeat {
            encoded.insert(alphabet[number % 64], at: 0)
            number = number / 64 - 1
        } while number != -1
        return try createChannel(JSString(utf16: ContiguousArray([95] + encoded)), type: type, generated: true)
    }
    public var onSubmit: (DatastoreMessage) -> Void = { _ in }
    public var onSignal: (JSONValue, Bool) -> Void = { _, _ in }
    public var onSubmitSignal: (JSString, JSONValue, JSString?) throws -> Void = { _, _, _ in }
    public var onOp: (JSONValue) -> Void = { _ in }
    public var onBunch: (JSString, Int) -> Void = { _, _ in }
    public var absolutePath: JSString { id.length == 0 ? "" : datastorePath("", id) }
    public init(id: JSString) throws {
        try check(!id.utf16.contains(47), "0x30e: datastore id cannot contain slashes")
        self.id = id
    }
    public func register(_ factory: ChannelFactory) throws {
        factories[try factory.attributes.member("type").asString()] = factory
    }
    private func verifyOpen() throws { try check(!disposed, "datastore disposed") }
    public func dispose() { disposed = true }
    @discardableResult public func createChannel(_ id: JSString, type: JSString) throws -> any Channel {
        try createChannel(id, type: type, generated: false)
    }
    private func createChannel(_ id: JSString, type: JSString, generated: Bool) throws -> any Channel {
        try verifyOpen()
        try check(!id.utf16.contains(47) && (generated || id.utf16.first != 95), "invalid channel id")
        try check(contexts[id] == nil, "0x179: channel already exists")
        guard let factory = LegacyTypeAwareRegistry(factories).get(type) else { throw DatastoreError("factory not registered") }
        let instance = try factory.make(id, nil)
        contexts[id] = LocalChannelContext(id: id, attributes: factory.attributes, instance: instance, visible: false, bound: false, load: { instance })
        order.append(id)
        return instance.channel
    }
    public func getChannel(_ id: JSString) throws -> any Channel {
        try verifyOpen()
        return try context(id).realize(self).channel
    }
    private func context(_ id: JSString) throws -> ChannelContext {
        guard let context = contexts[id] else { throw DatastoreError("0xa6b: channel context not found") }
        return context
    }
    public func bindChannel(_ id: JSString) throws {
        try verifyOpen()
        let context = try context(id)
        try check(!context.bound, "0x17b: channel already bound")
        context.bound = true
        context.instance?.bind()
        for referencedId in context.boundHandles {
            let referenced = try self.context(referencedId)
            if !referenced.bound { try bindChannel(referencedId) }
        }
        if attachState != .detached {
            var summary = try context.summary(self)
            summary = try addingBlob(summary, ".gcdata", dsObject([("gcNodes", dsObject([("/", .array(try channelRoutes(context).map(JSONValue.string)))]))]))
            let content = dsObject([("id", .string(id)), ("snapshot", try summaryToITree(summary)), ("type", try context.attributes.member("type"))])
            pendingAttach.insert(id)
            submit("attach", content, nil)
            context.visible = true
            try context.connect(self)
        }
    }
    public func makeVisibleAndAttachGraph() { visible = true }
    public func setAttachState(_ state: AttachState) throws {
        try verifyOpen()
        if state == .attaching {
            visible = true
            attachState = state
            for id in order {
                let context = try context(id)
                if context.bound {
                    context.visible = true
                    try context.connect(self)
                }
            }
        } else {
            try check(attachState == .attaching, "0x2d2: datastore not globally visible")
            attachState = state
        }
    }
    public func setConnectionState(_ connected: Bool, clientId: JSString?) throws {
        try verifyOpen()
        self.connected = connected
        self.clientId = clientId
        for context in contexts.values where context.visible { context.instance?.connection(connected) }
    }
    private func submit(_ type: JSString, _ content: JSONValue, _ metadata: (any ChannelOpMetadata)?) {
        pendingOpCount += 1
        onSubmit(DatastoreMessage(type: type, content: content, metadata: metadata))
    }
    func submitChannelOp(_ address: JSString, _ content: JSONValue, _ metadata: any ChannelOpMetadata) {
        submit("op", dsObject([("address", .string(address)), ("contents", content)]), metadata)
    }
    public func processMessages(envelope: JSONValue, messages: [ChannelMessage], local: Bool) throws {
        try verifyOpen()
        if local { pendingOpCount -= messages.count }
        switch try envelope.member("type").asString() {
        case "op":
            var address: JSString?
            var bunch: [ChannelMessage] = []
            func flush() throws {
                guard let address else { return }
                onBunch(address, bunch.count)
                try context(address).process(envelope, bunch, local)
                bunch.removeAll(keepingCapacity: true)
            }
            for message in messages {
                let next = try message.contents.member("address").asString()
                if next != address { try flush() }
                address = next
                bunch.append(ChannelMessage(contents: try message.contents.member("contents"), metadata: message.metadata, clientSequenceNumber: message.clientSequenceNumber))
            }
            try flush()
        case "attach":
            for message in messages {
                let id = try message.contents.member("id").asString()
                if local { try check(pendingAttach.remove(id) != nil, "0x17c: unexpected local attach") }
                else {
                    try check(contexts[id] == nil, "0x17d: unexpected remote attach")
                    let summary = try summaryFromITree(message.contents.member("snapshot"))
                    try loadContext(id, summary, local: false)
                }
            }
        default: break
        }
        for message in messages {
            var fields = try envelope.asObject()
            fields["contents"] = message.contents
            fields["clientSequenceNumber"] = .number(Double(message.clientSequenceNumber))
            onOp(.object(fields))
        }
    }
    public func processSignal(_ signal: JSONValue, local: Bool) { onSignal(signal, local) }
    public func submitSignal(_ type: JSString, content: JSONValue, targetClientId: JSString? = nil) throws {
        try onSubmitSignal(type, content, targetClientId)
    }
    public func reSubmit(_ message: DatastoreMessage) throws {
        try verifyOpen()
        pendingOpCount -= 1
        if message.type == "attach" { submit(message.type, message.content, message.metadata) }
        else {
            let context = try context(message.content.member("address").asString())
            guard let delta = context.delta, let md = message.metadata else { throw DatastoreError("0x18a: channel not loaded") }
            try delta.reSubmit(message.content.member("contents"), md)
        }
    }
    public func rollback(_ message: DatastoreMessage) throws {
        try verifyOpen()
        try check(activeLocalOperationActivity == nil, "0xca2: nested rollback")
        activeLocalOperationActivity = "rollback"
        defer { activeLocalOperationActivity = nil }
        pendingOpCount -= 1
        try check(message.type == "op", "cannot rollback attach")
        let context = try context(message.content.member("address").asString())
        guard let delta = context.delta, let md = message.metadata else { throw DatastoreError("0x2ee: channel not loaded") }
        try delta.rollback(message.content.member("contents"), md)
    }
    public func applyStashedOp(_ message: JSONValue) throws -> (any ChannelOpMetadata)? {
        try check(activeLocalOperationActivity == nil, "nested stash")
        activeLocalOperationActivity = "applyStashed"
        defer { activeLocalOperationActivity = nil }
        if try message.member("type").asString() == "attach" {
            let content = try message.member("content")
            let id = try content.member("id").asString()
            try loadContext(id, summaryFromITree(content.member("snapshot")), local: true)
            pendingAttach.insert(id)
            return nil
        }
        let content = try message.member("content")
        let context = try context(content.member("address").asString())
        try check(!(context is LocalChannelContext), "no stashed ops on local channel")
        _ = try context.realize(self)
        guard let delta = context.delta else { throw DatastoreError("missing delta connection") }
        return try delta.applyStashedOp(content.member("contents"))
    }
    public func getAttachSummary() throws -> SummaryTree {
        try check(visible && attachState == .detached, "0xc2c: datastore must be locally visible")
        var entries = JSObject<SummaryObject>()
        for id in order {
            let context = try context(id)
            if context.bound {
                if !context.isLoaded, let snapshot = context.baseSnapshot {
                    entries[id] = try asSummaryObject(snapshot)
                } else { entries[id] = try asSummaryObject(context.summary(self)) }
            }
        }
        return SummaryTree(tree: entries)
    }
    public func summarize() throws -> SummaryTree {
        var entries = JSObject<SummaryObject>()
        for id in order {
            let context = try context(id)
            try check(context.bound && context.visible && !pendingAttach.contains(id), "0x17f: detached channel in summary")
            entries[id] = try asSummaryObject(context.summary(self))
        }
        return SummaryTree(tree: entries)
    }
    public func load(_ summary: SummaryTree, local: Bool = false) throws {
        guard case .tree(let tree) = summary else { throw DatastoreError("expected summary tree") }
        for (id, value) in tree.tree.entries where id != "_search" {
            if case .tree(let subtree) = value { try loadContext(id, .tree(subtree), local: local) }
        }
        visible = true
    }
    private func loadContext(_ id: JSString, _ summary: SummaryTree, local: Bool) throws {
        let attributes = try summary.readAndParse(".attributes")
        let type = try attributes.member("type").asString()
        guard let factory = LegacyTypeAwareRegistry(factories).get(type) else { throw DatastoreError("factory not registered") }
        let loader = { try factory.make(id, summary) }
        let context: ChannelContext
        if local {
            context = RehydratedLocalChannelContext(id: id, attributes: attributes, instance: nil, visible: attachState != .detached, bound: true, load: loader)
        } else {
            context = RemoteChannelContext(id: id, attributes: attributes, instance: nil, visible: true, bound: true, load: loader)
        }
        context.baseSnapshot = summary
        contexts[id] = context
        order.append(id)
    }
    /// serializer.ts bindHandles / sharedObjectHandle.ts bind: preserve graph attachment at the native DDS boundary.
    public func serializeHandle(_ id: JSString, bindTo ownerId: JSString) throws -> JSONValue {
        let owner = try context(ownerId)
        let target = try context(id)
        if !owner.boundHandles.contains(id) { owner.boundHandles.append(id) }
        if owner.bound && !target.bound { try bindChannel(id) }
        return try FluidSerializer().encode(.handle(handle(id)))
    }
    public func handle(_ id: JSString) throws -> FluidHandle {
        _ = try context(id)
        return FluidHandle(absolutePath: id.length == 0 ? absolutePath : datastorePath(absolutePath, id))
    }
    private func channelRoutes(_ context: ChannelContext) throws -> [JSString] {
        let summary = try context.summary(self)
        var routes: [JSString] = []
        func visit(_ value: JSONValue) throws {
            switch value {
            case .object(let object):
                if object["type"] == .string("__fluid_handle__"), let url = object["url"] {
                    let path = try url.asString()
                    if !routes.contains(path) { routes.append(path) }
                } else { for (_, value) in object.entries { try visit(value) } }
            case .array(let values): for value in values { try visit(value) }
            default: break
            }
        }
        if case .tree(let tree) = summary {
            for (name, object) in tree.tree.entries where name != ".attributes" {
                if case .blob(let blob) = object { try visit(JSON.parse(blob.json.member("content").asString().description)) }
            }
        }
        return routes
    }
    public func getAttachGCData() throws -> JSONValue {
        try check(visible && attachState == .detached, "0xc2c: datastore must be locally visible")
        var nodes = JSObject<JSONValue>()
        for id in order {
            let context = try context(id)
            if context.bound && context.isLoaded {
                var routes = try channelRoutes(context)
                if !routes.contains(absolutePath) { routes.append(absolutePath) }
                nodes[datastorePath("", id)] = .array(routes.map(JSONValue.string))
            }
        }
        nodes["/"] = .array(order.map { .string(datastorePath(absolutePath, $0)) })
        return dsObject([("gcNodes", .object(nodes))])
    }
    public func getGCData() throws -> JSONValue {
        var nodes = JSObject<JSONValue>()
        for id in order {
            let context = try context(id)
            try check(context.bound && context.visible && !pendingAttach.contains(id), "0x17f: detached channel in GC")
            var routes = try channelRoutes(context)
            if !routes.contains(absolutePath) { routes.append(absolutePath) }
            nodes[datastorePath("", id)] = .array(routes.map(JSONValue.string))
        }
        nodes["/"] = .array(order.map { .string(datastorePath(absolutePath, $0)) })
        return dsObject([("gcNodes", .object(nodes))])
    }
}
func asSummaryObject(_ summary: SummaryTree) throws -> SummaryObject {
    try SummaryObject(json: summary.json)
}
func addingBlob(_ summary: SummaryTree, _ name: JSString, _ content: JSONValue) throws -> SummaryTree {
    guard case .tree(let tree) = summary else { throw DatastoreError("expected tree") }
    var entries = tree.tree
    entries[name] = .blob(ISummaryBlob(content: .text(JSString(JSON.stringify(content)))))
    return SummaryTree(tree: entries)
}
/// summaryUtils.ts convertSummaryTreeToITree; attributes and GC blobs retain exact strings.
public func summaryToITree(_ summary: SummaryTree) throws -> JSONValue {
    guard case .tree(let tree) = summary else { throw DatastoreError("expected tree") }
    let entries = try tree.tree.entries.map { key, value -> JSONValue in
        switch value {
        case .blob(let blob):
            return dsObject([("path", .string(key)), ("mode", .string("100644")), ("type", .string("Blob")), ("value", dsObject([("contents", try blob.json.member("content")), ("encoding", .string("utf-8"))]))])
        case .tree(let subtree):
            return dsObject([("path", .string(key)), ("mode", .string("040000")), ("type", .string("Tree")), ("value", try summaryToITree(.tree(subtree)))])
        default: throw DatastoreError("unsupported attach summary object")
        }
    }
    return dsObject([("entries", .array(entries))])
}
public func summaryFromITree(_ tree: JSONValue) throws -> SummaryTree {
    var entries = JSObject<SummaryObject>()
    for entry in try tree.member("entries").asArray() {
        let path = try entry.member("path").asString()
        let value = try entry.member("value")
        if try entry.member("type").asString() == "Tree" { entries[path] = try asSummaryObject(summaryFromITree(value)) }
        else { entries[path] = .blob(ISummaryBlob(content: .text(try value.member("contents").asString()))) }
    }
    return SummaryTree(tree: entries)
}

func datastorePath(_ base: JSString, _ child: JSString) -> JSString {
    var units = base.utf16
    units.append(47)
    units.append(contentsOf: child.utf16)
    return JSString(utf16: units)
}
