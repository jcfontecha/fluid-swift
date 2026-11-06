import FluidDriverDefinitions
import FluidJS
import Foundation

/// Ports container-loader/src/utils.ts IParsedUrl.
public struct IParsedUrl: Sendable, Equatable {
    /// The `tenantId/documentId` part of the path.
    public let id: String
    /// The deep-link path after it.
    public let path: String
    /// The query string, with its `?`, or empty.
    public let query: String
    /// The `version` query parameter: the snapshot version to load, nil for the latest.
    public let version: String?
}

/// Ports utils.ts `tryParseCompatibleResolvedUrl`: an absolute URL whose path is
/// `/{segment}/{segment}...` (regex `^\/([^/]*\/[^/]*)(\/?.*)$`); anything else is nil.
public func tryParseCompatibleResolvedUrl(_ url: String) -> IParsedUrl? {
    guard let components = URLComponents(string: url), components.scheme != nil, components.host != nil else {
        return nil
    }
    let pathname = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    guard pathname.hasPrefix("/") else { return nil }
    let afterRoot = pathname.dropFirst()
    guard let firstSlash = afterRoot.firstIndex(of: "/") else { return nil }
    let afterFirst = afterRoot[afterRoot.index(after: firstSlash)...]
    let secondSlash = afterFirst.firstIndex(of: "/") ?? afterFirst.endIndex
    let query = components.percentEncodedQuery.flatMap { $0.isEmpty ? nil : "?" + $0 } ?? ""
    return IParsedUrl(
        id: String(afterRoot[..<secondSlash]),
        path: String(afterFirst[secondSlash...]),
        query: query,
        version: components.queryItems?.first { $0.name == "version" }?.value)
}

/// Ports utils.ts `getProtocolSnapshotTree`: old documents keep the protocol blobs at the root.
public func getProtocolSnapshotTree(_ snapshot: ISnapshotTree) -> ISnapshotTree {
    snapshot.trees[".protocol"] ?? snapshot
}

/// Ports driver-utils/src/readAndParse.ts: a blob's UTF-8 text, parsed with JS JSON semantics.
func readAndParse(_ storage: any IDocumentStorageService, _ id: JSString?) async throws -> JSONValue {
    guard let id else { throw JSONDecodingError("Cannot read blob: undefined id") }
    let blob = try await storage.readBlob(id)
    return try JSON.parse(String(decoding: blob, as: UTF8.self))
}

/// Ports utils.ts `getDocumentAttributes`. No tree means sequence number 0; old documents keep
/// `.attributes` at the root instead of `.protocol/attributes`.
func getDocumentAttributes(_ storage: any IDocumentStorageService, _ tree: ISnapshotTree?) async throws -> IDocumentAttributes {
    guard let tree else {
        return try IDocumentAttributes(json: JSON.parse(#"{"minimumSequenceNumber":0,"sequenceNumber":0}"#))
    }
    let attributesHash: JSString?
    if let protocolTree = tree.trees[".protocol"] {
        attributesHash = protocolTree.blobs["attributes"]
    } else {
        attributesHash = tree.blobs[".attributes"]
    }
    return try IDocumentAttributes(json: await readAndParse(storage, attributesHash))
}

/// Ports driver-utils summaryForCreateNew.ts `isCombinedAppAndProtocolSummary`: exactly the
/// `.app` and `.protocol` trees.
func isCombinedAppAndProtocolSummary(_ summary: ISummaryTree) -> Bool {
    guard case .tree = summary.tree[".app"], case .tree = summary.tree[".protocol"] else { return false }
    return summary.tree.count == 2
}

/// Ports utils.ts `combineAppAndProtocolSummary`, asserts 0x5a8 and 0x5a9.
func combineAppAndProtocolSummary(_ appSummary: ISummaryTree, _ protocolSummary: ISummaryTree) throws -> ISummaryTree {
    guard !isCombinedAppAndProtocolSummary(appSummary) else {
        throw JSONDecodingError("0x5a8: app summary is already a combined tree!")
    }
    guard !isCombinedAppAndProtocolSummary(protocolSummary) else {
        throw JSONDecodingError("0x5a9: protocol summary is already a combined tree!")
    }
    var tree = JSObject<SummaryObject>()
    tree[".protocol"] = .tree(protocolSummary)
    tree[".app"] = .tree(appSummary)
    return ISummaryTree(tree: tree)
}
