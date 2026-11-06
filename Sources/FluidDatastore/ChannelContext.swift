import FluidJS
import FluidDriverDefinitions
import FluidDatastoreDefinitions
import FluidSharedObjectBase

public struct DatastoreError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw DatastoreError(message) }
}
public protocol ChannelOpMetadata: AnyObject {}
private final class MetadataBox<M>: ChannelOpMetadata {
    let value: M
    init(_ value: M) { self.value = value }
}
public struct ChannelMessage {
    public let contents: JSONValue
    public let metadata: (any ChannelOpMetadata)?
    public let clientSequenceNumber: Int
    public init(contents: JSONValue, metadata: (any ChannelOpMetadata)? = nil, clientSequenceNumber: Int = 0) {
        self.contents = contents
        self.metadata = metadata
        self.clientSequenceNumber = clientSequenceNumber
    }
}

/// A typed factory bridge to IChannelFactory; metadata never enters the wire or a JSON codec.
public struct ChannelFactory {
    public let attributes: JSONValue
    let make: (JSString, SummaryTree?) throws -> ChannelInstance
    public init<M, C: SharedObjectCore<M>>(_ type: C.Type, snapshotFormatVersion: JSString) {
        attributes = dsObject([("type", .string(C.type)), ("snapshotFormatVersion", .string(snapshotFormatVersion)), ("packageVersion", .string("3.11.0"))])
        make = { id, summary in
            let channel = try summary.map { try C.load(id: id, summary: $0) } ?? C(id: id)
            return ChannelInstance(channel)
        }
    }
}
/// The IChannel surface with its metadata retained by generic closures, not untyped storage.
public final class ChannelInstance {
    public let channel: any Channel
    let connect: (FluidDataStoreRuntime, @escaping (JSONValue, any ChannelOpMetadata) -> Void) -> Void
    let process: (JSONValue, [ChannelMessage], Bool) throws -> Void
    let resubmit: (JSONValue, any ChannelOpMetadata) throws -> Void
    let rollback: (JSONValue, any ChannelOpMetadata) throws -> Void
    let stash: (JSONValue) throws -> Void
    let bind: () -> Void
    let connection: (Bool) -> Void
    let summary: () -> SummaryTree
    init<M>(_ channel: SharedObjectCore<M>) {
        self.channel = channel
        connect = { runtime, submit in channel.connect(runtime) { submit($0, MetadataBox($1)) } }
        process = { envelope, messages, local in
            let contents = try messages.map { entry in
                var fields = try envelope.asObject()
                fields["contents"] = entry.contents
                fields["clientSequenceNumber"] = .number(Double(entry.clientSequenceNumber))
                fields["referenceSequenceNumber"] = fields["referenceSequenceNumber"] ?? .number(0)
                fields["minimumSequenceNumber"] = fields["minimumSequenceNumber"] ?? .number(0)
                var md: M?
                if let metadata = entry.metadata {
                    guard let typed = metadata as? MetadataBox<M> else { throw DatastoreError("metadata type mismatch") }
                    md = typed.value
                }
                return SharedObjectCore<M>.Content(message: try SequencedMessage(json: .object(fields)), metadata: md)
            }
            try channel.processMessages(contents, local: local)
        }
        resubmit = { contents, md in
            guard let typed = md as? MetadataBox<M> else { throw DatastoreError("metadata type mismatch") }
            try channel.reSubmitCore(contents, localOpMetadata: typed.value)
        }
        rollback = { contents, md in
            guard let typed = md as? MetadataBox<M> else { throw DatastoreError("metadata type mismatch") }
            try channel.rollback(contents, localOpMetadata: typed.value)
        }
        stash = channel.applyStashedOp
        bind = { channel.bindToContext() }
        connection = channel.setConnectionState
        summary = channel.summarize
    }
}

/// Ports channelDeltaConnection.ts, including stashed-op metadata expansion.
public final class ChannelDeltaConnection {
    let channel: ChannelInstance
    private var captured: [ChannelMessage]?
    var submitFn: (JSONValue, any ChannelOpMetadata) -> Void = { _, _ in }
    init(_ channel: ChannelInstance) { self.channel = channel }
    func submit(_ content: JSONValue, _ metadata: any ChannelOpMetadata) {
        if captured != nil { captured?.append(ChannelMessage(contents: content, metadata: metadata)) }
        else { submitFn(content, metadata) }
    }
    func applyStashedOp(_ contents: JSONValue) throws -> any ChannelOpMetadata {
        captured = []
        defer { captured = nil }
        try channel.stash(contents)
        return StashedOpMetadata(captured ?? [])
    }
    func expanded(_ contents: JSONValue, _ metadata: (any ChannelOpMetadata)?) -> [ChannelMessage] {
        if let stash = metadata as? StashedOpMetadata { return stash.messages }
        return [ChannelMessage(contents: contents, metadata: metadata)]
    }
    func process(_ envelope: JSONValue, _ messages: [ChannelMessage], _ local: Bool) throws {
        let expanded = messages.flatMap { entry in
            expanded(entry.contents, entry.metadata).map { ChannelMessage(contents: $0.contents, metadata: $0.metadata, clientSequenceNumber: entry.clientSequenceNumber) }
        }
        try channel.process(envelope, expanded, local)
    }
    func reSubmit(_ contents: JSONValue, _ metadata: any ChannelOpMetadata) throws {
        for message in expanded(contents, metadata) {
            guard let md = message.metadata else { throw DatastoreError("missing metadata") }
            try channel.resubmit(message.contents, md)
        }
    }
    func rollback(_ contents: JSONValue, _ metadata: any ChannelOpMetadata) throws {
        for message in expanded(contents, metadata) {
            guard let md = message.metadata else { throw DatastoreError("missing metadata") }
            try channel.rollback(message.contents, md)
        }
    }
}
private final class StashedOpMetadata: ChannelOpMetadata {
    let messages: [ChannelMessage]
    init(_ messages: [ChannelMessage]) { self.messages = messages }
}

/// Ports channelContext.ts's common context contract and deferred message replay.
open class ChannelContext {
    public let id: JSString
    public let attributes: JSONValue
    public private(set) var instance: ChannelInstance?
    var baseSnapshot: SummaryTree?
    var delta: ChannelDeltaConnection?
    var pending: [(JSONValue, [ChannelMessage], Bool)] = []
    let load: () throws -> ChannelInstance
    var visible: Bool
    var boundHandles: [JSString] = []
    var bound: Bool
    init(id: JSString, attributes: JSONValue, instance: ChannelInstance?, visible: Bool, bound: Bool, load: @escaping () throws -> ChannelInstance) {
        self.id = id
        self.attributes = attributes
        self.instance = instance
        self.visible = visible
        self.bound = bound
        self.load = load
    }
    public var isLoaded: Bool { instance != nil }
    func realize(_ runtime: FluidDataStoreRuntime) throws -> ChannelInstance {
        if let instance { return instance }
        let loaded = try load()
        instance = loaded
        try connect(runtime)
        for (envelope, messages, local) in pending { try delta?.process(envelope, messages, local) }
        pending.removeAll()
        return loaded
    }
    func connect(_ runtime: FluidDataStoreRuntime) throws {
        guard visible, delta == nil, let instance else { return }
        let connection = ChannelDeltaConnection(instance)
        delta = connection
        let id = self.id
        connection.submitFn = { [weak runtime] content, metadata in runtime?.submitChannelOp(id, content, metadata) }
        instance.connect(runtime) { [weak connection] content, metadata in connection?.submit(content, metadata) }
        instance.connection(runtime.connected)
    }
    func process(_ envelope: JSONValue, _ messages: [ChannelMessage], _ local: Bool) throws {
        try check(visible, "0x2d3: local channel not visible")
        if let delta { try delta.process(envelope, messages, local) }
        else {
            try check(!local, "0x195: unloaded channel received local op")
            pending.append((envelope, messages, local))
        }
    }
    func summary(_ runtime: FluidDataStoreRuntime) throws -> SummaryTree {
        let instance = try realize(runtime)
        guard case .tree(let tree) = instance.summary() else { throw DatastoreError("channel returned summary handle") }
        var entries = tree.tree
        entries[".attributes"] = .blob(ISummaryBlob(content: .text(JSString(JSON.stringify(attributes)))))
        return SummaryTree(tree: entries)
    }
}
/// Ports localChannelContext.ts LocalChannelContextBase.
open class LocalChannelContextBase: ChannelContext {}
/// Ports localChannelContext.ts LocalChannelContext.
public final class LocalChannelContext: LocalChannelContextBase {}
/// Ports localChannelContext.ts RehydratedLocalChannelContext.
public final class RehydratedLocalChannelContext: LocalChannelContextBase {}
/// Ports remoteChannelContext.ts RemoteChannelContext.
public final class RemoteChannelContext: ChannelContext {}

func dsObject(_ pairs: [(JSString, JSONValue)]) -> JSONValue {
    var value = JSObject<JSONValue>()
    for (key, entry) in pairs { value[key] = entry }
    return .object(value)
}
