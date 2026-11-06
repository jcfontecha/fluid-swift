import Foundation
import FluidJS
import FluidDriverDefinitions

public struct GCResult: Sendable {
    public let referencedNodeIds: [JSString]
    public let deletedNodeIds: [JSString]
    public var json: JSONValue {
        object([("referencedNodeIds", .array(referencedNodeIds.map(JSONValue.string))), ("deletedNodeIds", .array(deletedNodeIds.map(JSONValue.string)))])
    }
}
/// Ports gc/gcReferenceGraphAlgorithm.ts. Output follows graph order, not traversal order.
public func runGarbageCollection(_ data: JSONValue, roots: [JSString] = ["/"]) throws -> GCResult {
    let graph = try data.member("gcNodes").asObject()
    var visited: Set<JSString> = []
    var queue = roots
    var cursor = 0
    while cursor < queue.count {
        let id = queue[cursor]
        cursor += 1
        if !visited.insert(id).inserted { continue }
        if let routes = graph[id] { queue.append(contentsOf: try routes.asArray().map { try $0.asString() }) }
    }
    return GCResult(referencedNodeIds: graph.keys.filter { visited.contains($0) }, deletedNodeIds: graph.keys.filter { !visited.contains($0) })
}
/// Ports gc/gcSummaryStateTracker.ts (graph state only; sweep and tombstones are separate lanes).
public final class GCSummaryStateTracker {
    private var latest: String?
    private var pending: String?
    public init() {}
    public func summarize(_ state: JSONValue, trackState: Bool) throws -> SummaryTreeWithStats {
        let serialized = JSON.stringify(try generateSortedGCState(state))
        pending = serialized
        if trackState && latest == serialized {
            return try SummaryTreeWithStats(SummaryTree(json: summaryHandle("/gc").json))
        }
        return try SummaryTreeWithStats(.singleBlob("__gc_root", JSString(serialized)))
    }
    public func initializeBaseState(_ state: JSONValue) throws { latest = JSON.stringify(try generateSortedGCState(state)) }
    public func refreshLatestSummary() {
        latest = pending
        pending = nil
    }
}
/// Ports gc/garbageCollection.ts mark/reference tracking and summary generation, without sweep.
public final class GarbageCollector {
    public let summaryStateTracker = GCSummaryStateTracker()
    private var timestamps: [JSString: Double] = [:]
    private var previous: JSONValue?
    private var added: [(JSString, JSString)] = []
    public private(set) var state: JSONValue?
    public init() {}
    public func initializeBaseState(_ state: JSONValue) throws {
        self.state = state
        var graph = JSObject<JSONValue>()
        for (id, data) in try state.member("gcNodes").asObject().entries {
            graph[id] = try data.member("outboundRoutes")
            timestamps[id] = try field(data, "unreferencedTimestampMs")?.asNumber()
        }
        previous = object([("gcNodes", .object(graph))])
        try summaryStateTracker.initializeBaseState(state)
    }
    public func addedOutboundReference(from: JSString, to: JSString) { added.append((from, to)) }
    public func collectGarbage(_ data: JSONValue, timestamp: Double) throws {
        let graph = try data.member("gcNodes").asObject()
        if let previous {
            var union = try previous.member("gcNodes").asObject()
            for (id, routes) in graph.entries {
                let old = try union[id]?.asArray() ?? []
                union[id] = .array(old + (try routes.asArray()))
            }
            for (from, to) in added {
                union[from] = .array((try union[from]?.asArray() ?? []) + [.string(to)])
            }
            let transient = try runGarbageCollection(object([("gcNodes", .object(union))]), roots: ["/"] + added.map { $0.1 })
            for id in transient.referencedNodeIds { timestamps.removeValue(forKey: id) }
        }
        let mark = try runGarbageCollection(data)
        for id in mark.referencedNodeIds { timestamps.removeValue(forKey: id) }
        for id in mark.deletedNodeIds where timestamps[id] == nil { timestamps[id] = timestamp }
        var nodes = JSObject<JSONValue>()
        for (id, routes) in graph.entries {
            nodes[id] = object([("outboundRoutes", routes), ("unreferencedTimestampMs", timestamps[id].map(JSONValue.number))])
        }
        state = object([("gcNodes", .object(nodes))])
        previous = data
        added.removeAll(keepingCapacity: true)
    }
    public func summarize(fullTree: Bool, trackState: Bool) throws -> SummaryTreeWithStats {
        guard let state else { throw JSONDecodingError("GC has not run") }
        return try summaryStateTracker.summarize(state, trackState: trackState && !fullTree)
    }
    public func refreshLatestSummary() { summaryStateTracker.refreshLatestSummary() }
}

/// Ports gc/gcHelpers.ts generateSortedGCState. Node and route sorting are deliberately different.
public func generateSortedGCState(_ state: JSONValue) throws -> JSONValue {
    let graph = try state.member("gcNodes").asObject()
    var nodes = JSObject<JSONValue>()
    let locale = Locale(identifier: "en_US")
    for id in graph.keys.sorted(by: { $0.description.compare($1.description, options: [], locale: locale) == .orderedAscending }) {
        guard let node = graph[id] else { throw JSONDecodingError("missing GC node") }
        let routes = try node.member("outboundRoutes").asArray().map { try $0.asString() }.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        nodes[id] = try object([("outboundRoutes", .array(routes.map(JSONValue.string))), ("unreferencedTimestampMs", field(node, "unreferencedTimestampMs"))])
    }
    return object([("gcNodes", .object(nodes))])
}
