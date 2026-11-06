import FluidJS
import Foundation

/// fetchSnapshot.ts content negotiation and trees-latest request.
public struct SnapshotFetchResult {
    public let snapshot: CompactSnapshot
    public let cacheAllowed: Bool
    public let fluidEpoch: String?
}

nonisolated(nonsending) public func downloadSnapshot(resolved: IOdspResolvedUrl, network: OdspNetwork, options: JSObject<JSONValue> = .init(), loadingGroupIds: [String]? = nil, binaryOnly: Bool = false) async throws -> CompactSnapshot {
    try await fetchSnapshotCore(resolved: resolved, network: network, options: options, loadingGroupIds: loadingGroupIds, binaryOnly: binaryOnly).snapshot
}

nonisolated(nonsending) func fetchSnapshotCore(resolved: IOdspResolvedUrl, network: OdspNetwork, options: JSObject<JSONValue> = .init(), loadingGroupIds: [String]? = nil, binaryOnly: Bool = false, untracked: Bool = false, scenarioName: String? = nil) async throws -> SnapshotFetchResult {
    var url = resolved.snapshotStorageUrl + "/trees/latest?ump=1"
    for (key, value) in options.entries where key != "timeout" {
        let text: String
        if case .string(let string) = value { text = string.description } else { text = JSON.stringify(value) }
        url += "&" + encodeOdspComponent(key.description) + "=" + encodeOdspComponent(text)
    }
    if let loadingGroupIds { url += "&groupId=" + encodeOdspComponent(loadingGroupIds.joined(separator: ",")) }
    let fetchResponse: ((OdspRequest) async throws -> OdspResponse)?
    if untracked { fetchResponse = { request in try await network.fetchWithoutEpoch(request) } }
    else { fetchResponse = nil }
    var lines = ["prefer: manualredirect"]
    // fetchSnapshot.ts:793: the epoch tracker adds ClpCompliantAppHeader, so only an untracked
    // request carries it here, whenever isClpCompliantApp is defined.
    if untracked, let isClpCompliantApp = resolved.isClpCompliantApp { lines.append("X-CLP-Compliant-App: " + String(isClpCompliantApp)) }
    let response = try await network.authorized(url: url, make: { auth, boundary in
        OdspRequest(url: url, headers: ["Content-Type": "multipart/form-data;boundary=" + boundary, "accept": (binaryOnly ? "" : "application/json, ") + "application/ms-fluid; v=1.0"], body: odspMultipart(boundary: boundary, lines: ["Authorization: " + auth, "X-HTTP-Method-Override: GET"] + lines), timeoutMs: try options["timeout"]?.asNumber(), fetchType: .treesLatest, fetchReason: scenarioName)
    }, fetchResponse: fetchResponse)
    guard !response.body.isEmpty else { throw OdspNetworkError("incorrectServerResponse", canRetry: false, statusCode: 712) }
    let type = response.headers["content-type"] ?? ""
    let cacheAllowed = response.headers["disablebrowsercachingofusercontent"] != "true" && loadingGroupIds?.isEmpty != false
    if type.contains("application/ms-fluid") { return SnapshotFetchResult(snapshot: try parseCompactSnapshotResponse(Array(response.body)).snapshot, cacheAllowed: cacheAllowed, fluidEpoch: response.headers["x-fluid-epoch"]) }
    if type.contains("application/json") { return SnapshotFetchResult(snapshot: try convertOdspSnapshotToSnapshotTreeAndBlobs(response.json()), cacheAllowed: cacheAllowed, fluidEpoch: response.headers["x-fluid-epoch"]) }
    throw OdspNetworkError("incorrectServerResponse", canRetry: false, statusCode: 712)
}

/// odspSnapshotParser.ts. Flat entries must be breadth-first; commit entries are ignored.
public func convertOdspSnapshotToSnapshotTreeAndBlobs(_ json: JSONValue) throws -> CompactSnapshot {
    let trees = try json.member("trees").asArray()
    guard let first = trees.first else { throw JSONDecodingError("missing root tree") }
    let root = try first.asObject()
    var nodes: [String: CompactSnapshotTree] = ["": CompactSnapshotTree(id: try first.member("id").asString())]
    var paths: [(String, String, String)] = []
    for entry in try first.member("entries").asArray() {
        let path = try entry.member("path").asString().description
        let index = path.lastIndex(of: "/")
        let parent = index.map { String(path[..<$0]) } ?? ""
        let name = index.map { String(path[path.index(after: $0)...]) } ?? path
        guard var node = nodes[parent] else { throw JSONDecodingError("missing parent tree") }
        switch try entry.member("type").asString() {
        case "tree":
            let fields = try entry.asObject()
            var tree = CompactSnapshotTree()
            if case .bool(let flag) = fields["unreferenced"] { tree.unreferenced = flag }
            if case .string(let group) = fields["groupId"] { tree.groupId = group }
            nodes[path] = tree
            node.trees[JSString(name)] = tree
            paths.append((path, parent, name))
        case "blob": node.blobs[JSString(name)] = try entry.member("id").asString()
        default: break
        }
        nodes[parent] = node
    }
    for (path, parent, name) in paths.reversed() {
        guard let child = nodes[path], var node = nodes[parent] else { throw JSONDecodingError("missing hierarchy node") }
        node.trees[JSString(name)] = child
        nodes[parent] = node
    }
    var blobs = JSMap<JSString, CompactSnapshotBlobContent>()
    for blob in try json.member("blobs").asArray() {
        let fields = try blob.asObject()
        let content = try blob.member("content").asString().description
        let bytes: [UInt8]
        if fields["encoding"] == .string("base64") {
            guard let data = Data(base64Encoded: content) else { throw JSONDecodingError("invalid base64 blob") }
            bytes = Array(data)
        } else {
            guard fields["encoding"] == nil else { throw JSONDecodingError("0x0a4") }
            bytes = Array(content.utf8)
        }
        blobs.set(try blob.member("id").asString(), .buffer(bytes[...]))
    }
    let fields = try json.asObject()
    let wrappers = try fields["ops"]?.asArray() ?? []
    let ops = try wrappers.map { try $0.member("op") }
    let sequence = try root["sequenceNumber"]?.asInt()
    let latest = try wrappers.last.map { try $0.member("sequenceNumber").asInt() } ?? sequence
    guard let tree = nodes[""] else { throw JSONDecodingError("missing root") }
    return CompactSnapshot(snapshotTree: tree, blobContents: blobs, ops: ops, sequenceNumber: sequence, latestSequenceNumber: latest)
}
