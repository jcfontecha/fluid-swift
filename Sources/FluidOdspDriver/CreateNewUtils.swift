import FluidDriverDefinitions
import FluidJS
import Foundation

// Ports odsp-driver/src/createFile/createNewUtils.ts and the driver-utils summaryForCreateNew.ts
// helpers it uses.

/// summaryForCreateNew.ts isCombinedAppAndProtocolSummary: exactly a ".app" and a ".protocol" tree.
func isCombinedAppAndProtocolSummary(_ summary: ISummaryTree) -> Bool {
    guard case .tree = summary.tree[".app"], case .tree = summary.tree[".protocol"] else { return false }
    return summary.tree.count == 2
}

/// summaryForCreateNew.ts getDocAttributesFromProtocolSummary: `JSON.parse` of the attributes blob.
func getDocAttributesFromProtocolSummary(_ protocolSummary: ISummaryTree) throws -> JSONValue {
    guard case .blob(let blob) = protocolSummary.tree["attributes"], case .text(let content) = blob.content else {
        throw JSONDecodingError("TypeError: attributes blob content is not a string")
    }
    return try JSON.parse(content.description)
}

/// The cached snapshot of a create-new summary: every blob gets a fresh UUID; handles and
/// attachments cannot appear in a detached summary.
func convertCreateNewSummaryTreeToTreeAndBlobs(_ summary: ISummaryTree, treeId: JSString) throws -> CompactSnapshot {
    guard case .tree(let protocolSummary) = summary.tree[".protocol"] else { throw JSONDecodingError("TypeError: missing .protocol tree") }
    let sequenceNumber = try getDocAttributesFromProtocolSummary(protocolSummary).member("sequenceNumber").asInt()
    var blobContents = JSMap<JSString, CompactSnapshotBlobContent>()
    var snapshotTree = try convertCreateNewSummaryTreeToTreeAndBlobsCore(summary, &blobContents)
    snapshotTree.id = treeId
    return CompactSnapshot(snapshotTree: snapshotTree, blobContents: blobContents, ops: [], sequenceNumber: sequenceNumber, latestSequenceNumber: sequenceNumber)
}

private func convertCreateNewSummaryTreeToTreeAndBlobsCore(_ summary: ISummaryTree, _ blobs: inout JSMap<JSString, CompactSnapshotBlobContent>) throws -> CompactSnapshotTree {
    var treeNode = CompactSnapshotTree(unreferenced: summary.unreferenced, groupId: summary.groupId)
    for (key, summaryObject) in summary.tree.entries {
        switch summaryObject {
        case .tree(let subtree):
            treeNode.trees[key] = try convertCreateNewSummaryTreeToTreeAndBlobsCore(subtree, &blobs)
        case .blob(let blob):
            let contentBuffer: [UInt8]
            switch blob.content {
            case .text(let text): contentBuffer = Array(text.description.utf8)
            case .binary(let bytes): contentBuffer = bytes
            }
            let blobId = JSString(UUID().uuidString.lowercased())
            treeNode.blobs[key] = blobId
            blobs.set(blobId, .buffer(contentBuffer[...]))
        case .handle(let handle):
            throw JSONDecodingError("No \(handle.type) should be present for detached summary!")
        case .attachment(let attachment):
            throw JSONDecodingError("No \(attachment.type) should be present for detached summary!")
        }
    }
    return treeNode
}

/// The container payload for create-new: ".protocol" then ".app", with the attributes blob
/// re-serialized. TS mutates the caller's protocol tree; the mutated summary is returned so the
/// cached snapshot sees the same attributes content.
func convertSummaryIntoContainerSnapshot(_ createNewSummary: ISummaryTree) throws -> (payload: JSONValue, summary: ISummaryTree) {
    guard isCombinedAppAndProtocolSummary(createNewSummary),
          case .tree(let appSummary) = createNewSummary.tree[".app"],
          case .tree(let protocolSummary) = createNewSummary.tree[".protocol"] else {
        throw JSONDecodingError("App and protocol summary required for create new path!!")
    }
    let documentAttributes = try getDocAttributesFromProtocolSummary(protocolSummary)
    var protocolTree = protocolSummary.tree
    protocolTree["attributes"] = .blob(ISummaryBlob(content: .text(JSString(JSON.stringify(documentAttributes)))))
    let mutatedProtocol = ISummaryTree(tree: protocolTree)
    var converted = JSObject<SummaryObject>()
    converted[".protocol"] = .tree(mutatedProtocol)
    converted[".app"] = .tree(appSummary)
    let snapshotTree = try convertSummaryToSnapshotTreeForCreateNew(ISummaryTree(tree: converted))
    var payload = JSObject<JSONValue>()
    payload["entries"] = try snapshotTree.member("entries")
    payload["message"] = .string("app")
    payload["sequenceNumber"] = try documentAttributes.member("sequenceNumber")
    payload["type"] = .string("container")
    var original = createNewSummary.tree
    original[".protocol"] = .tree(mutatedProtocol)
    return (.object(payload), ISummaryTree(tree: original))
}

private func convertSummaryToSnapshotTreeForCreateNew(_ summary: ISummaryTree) throws -> JSONValue {
    var entries: [JSONValue] = []
    for (key, summaryObject) in summary.tree.entries {
        guard !key.description.contains("/") else { throw JSONDecodingError("0x9cc") }
        var value: JSONValue
        var unreferenced: Bool?
        var groupId: JSString?
        switch summaryObject {
        case .tree(let subtree):
            value = try convertSummaryToSnapshotTreeForCreateNew(subtree)
            unreferenced = subtree.unreferenced
            groupId = subtree.groupId
        case .blob(let blob):
            var blobValue = JSObject<JSONValue>()
            blobValue["type"] = .string("blob")
            switch blob.content {
            case .text(let text):
                blobValue["content"] = .string(text)
                blobValue["encoding"] = .string("utf-8")
            case .binary(let bytes):
                blobValue["content"] = .string(JSString(Data(bytes).base64EncodedString()))
                blobValue["encoding"] = .string("base64")
            }
            value = .object(blobValue)
        case .handle:
            throw JSONDecodingError("No handle should be present for first summary!!")
        case .attachment:
            throw JSONDecodingError("Unknown tree type 4")
        }
        var entry = JSObject<JSONValue>()
        entry["path"] = .string(key)
        entry["type"] = .string(summaryObject.isTree ? "tree" : "blob")
        entry["value"] = value
        entry["unreferenced"] = unreferenced.map { .bool($0) }
        entry["groupId"] = groupId.map { .string($0) }
        entries.append(.object(entry))
    }
    var snapshotTree = JSObject<JSONValue>()
    snapshotTree["type"] = .string("tree")
    snapshotTree["entries"] = .array(entries)
    return .object(snapshotTree)
}

extension SummaryObject {
    /// gitHelper.ts getGitType: a tree, or a handle to one, is "tree"; everything else is "blob".
    var isTree: Bool {
        switch self {
        case .tree: return true
        case .handle(let handle): return handle.handleType == .tree
        case .blob, .attachment: return false
        }
    }
}

/// createNewFluidContainerCore: the auth header goes in a ump multipart body when it is a Bearer
/// token and the body fits 78 KB; otherwise a plain JSON POST with a second token fetch.
func createNewFluidContainerCore(network: OdspNetwork, containerSnapshot: JSONValue, initialUrl: String, fetchType: OdspFetchType, additionalHeaders: [(String, String)] = []) async throws -> JSONValue {
    try await getWithRetryForTokenRefresh { options in
        let snapshotBody = JSON.stringify(containerSnapshot)
        let formBoundary = network.boundary()
        // `new URL(initialUrl).searchParams.set("ump", "1")` on a URL without a query.
        let authInBodyUrl = initialUrl + "?ump=1"
        let authHeader = try await network.authorizationHeader(options, url: authInBodyUrl, method: "POST")
        var postBodyWithAuthHeaders = ["Authorization: " + authHeader, "X-HTTP-Method-Override: POST", "Content-Type: application/json"]
        for (key, value) in additionalHeaders { postBodyWithAuthHeaders.append(key + ": " + value) }
        let postBodyWithAuth = odspMultipart(boundary: formBoundary, lines: postBodyWithAuthHeaders, payload: snapshotBody)
        let request: OdspRequest
        if postBodyWithAuth.count <= maxUmpPostBodySize, authHeader.hasPrefix("Bearer") {
            request = OdspRequest(url: authInBodyUrl, headers: ["Content-Type": "multipart/form-data;boundary=" + formBoundary], body: postBodyWithAuth, timeoutMs: nil, fetchType: fetchType)
        } else {
            let authHeaderNoUmp = try await network.authorizationHeader(options, url: initialUrl, method: "POST")
            var headers: [String: String] = [:]
            for (key, value) in additionalHeaders { headers[key] = value }
            headers["Authorization"] = authHeaderNoUmp
            headers["Content-Type"] = "application/json"
            request = OdspRequest(url: initialUrl, headers: headers, body: Data(snapshotBody.utf8), timeoutMs: nil, fetchType: fetchType)
        }
        let response = try await runWithRetry(sleep: { try await Task.sleep(for: .milliseconds($0)) }, random: { Double.random(in: 0..<1) }) {
            try await network.fetch(request)
        }
        return try response.json()
    }
}
