import FluidJS
import FluidDriverDefinitions

/// Ports runtime-utils/summaryUtils.ts calculateStats and mergeStats.
public struct SummaryStats: Equatable, Sendable {
    public var treeNodeCount = 0
    public var blobNodeCount = 0
    public var handleNodeCount = 0
    public var totalBlobSize = 0
    public var unreferencedBlobSize = 0
    public var json: JSONValue {
        object([("treeNodeCount", number(treeNodeCount)), ("blobNodeCount", number(blobNodeCount)), ("handleNodeCount", number(handleNodeCount)), ("totalBlobSize", number(totalBlobSize)), ("unreferencedBlobSize", number(unreferencedBlobSize))])
    }
    public init(_ summary: SummaryTree) throws {
        try visit(SummaryObject(json: summary.json), unreferenced: false)
    }
    private mutating func visit(_ value: SummaryObject, unreferenced: Bool) throws {
        switch value {
        case .tree(let tree):
            treeNodeCount += 1
            for (_, child) in tree.tree.entries { try visit(child, unreferenced: unreferenced || tree.unreferenced == true) }
        case .blob(let blob):
            blobNodeCount += 1
            let size: Int
            switch blob.content {
            case .text(let text): size = text.description.utf8.count
            case .binary(let bytes): size = bytes.count
            }
            totalBlobSize += size
            if unreferenced { unreferencedBlobSize += size }
        case .handle: handleNodeCount += 1
        case .attachment: break
        }
    }
}
public struct SummaryTreeWithStats: Sendable {
    public let summary: SummaryTree
    public let stats: SummaryStats
    public init(_ summary: SummaryTree) throws {
        self.summary = summary
        stats = try SummaryStats(summary)
    }
    public var json: JSONValue { object([("summary", summary.json), ("stats", stats.json)]) }
}
func summaryHandle(_ path: JSString, type: Int = 1) throws -> SummaryObject {
    .handle(try ISummaryHandle(json: object([("type", number(3)), ("handle", .string(path)), ("handleType", number(type))])))
}
