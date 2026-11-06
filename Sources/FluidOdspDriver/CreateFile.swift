import FluidDriverDefinitions
import FluidJS
import Foundation

// Ports odsp-driver/src/createFile/createFile.ts and createNewContainerOnExistingFile.ts.
// Share-link creation (`createLinkType`, enableSingleRequestForShareLinkWithCreate) is not ported.

/// `/["*/:<>?\\|]+/` from createFile.ts.
private func isInvalidFileName(_ fileName: String) -> Bool {
    fileName.contains { "\"*/:<>?\\|".contains($0) }
}

/// encodeFilePath: a non-empty path gains a leading slash and is URI-component encoded.
private func encodeFilePath(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    return encodeOdspComponent(path.hasPrefix("/") ? path : "/" + path)
}

private func getNewFileItemPath(_ newFileInfo: INewFileInfo, encodedFilename: String) -> String {
    switch newFileInfo.location {
    case .filePath(let path): return "items/root:" + encodeFilePath(path) + "/" + encodedFilename
    case .parentFolderId(let id): return "items/" + encodeOdspComponent(id) + ":/" + encodedFilename
    }
}

/// createNewFluidFile: creates the file from the summary (or an empty `.tmp` file renamed after the
/// first summary), points the shared file entry at it and caches the summary as its snapshot.
func createNewFluidFile(network: OdspNetwork, newFileInfo: INewFileInfo, createNewSummary: ISummaryTree?, persistedCache: LocalPersistentCache, createNewCaching: Bool, resolvedUrl: IOdspResolvedUrl) async throws -> IOdspResolvedUrl {
    if isInvalidFileName(newFileInfo.filename) {
        throw OdspNetworkError("invalidFileNameError", canRetry: false)
    }
    let itemId: String
    var pendingRename: String?
    var summaryHandle = ""
    var cachedSummary: ISummaryTree?
    if let createNewSummary {
        let (content, mutated) = try await createNewFluidFileFromSummary(network: network, newFileInfo: newFileInfo, createNewSummary: createNewSummary)
        itemId = try content.member("itemId").asString().description
        summaryHandle = try content.member("id").asString().description
        cachedSummary = mutated
    } else {
        itemId = try await createNewEmptyFluidFile(network: network, newFileInfo: newFileInfo)
        pendingRename = newFileInfo.filename
    }
    let odspUrl = createOdspUrl(siteUrl: newFileInfo.siteUrl, driveId: newFileInfo.driveId, itemId: itemId, dataStorePath: "/")
    var headers = JSObject<JSONValue>()
    headers["X-CLP-Compliant-App"] = resolvedUrl.isClpCompliantApp.map { .bool($0) }
    var odspResolvedUrl = try OdspDriverUrlResolver().resolveOdspUrl(IRequest(url: odspUrl, headers: headers))
    // createFile.ts:115-116: the host's context and appName carry over to the created file.
    let hostFields = try resolvedUrl.json.asObject()
    odspResolvedUrl = try odspResolvedUrl.setting("context", hostFields["context"]).setting("appName", hostFields["appName"])
    // The new resolve has no container package name, so the create-new request's code hint wins.
    if odspResolvedUrl.containerPackageName == nil {
        odspResolvedUrl = try odspResolvedUrl.setting("codeHint", resolvedUrl.json.asObject()["codeHint"])
    }
    odspResolvedUrl = try odspResolvedUrl.setting("pendingRename", pendingRename.map { .string(JSString($0)) })
    network.updateResolvedUrl(odspResolvedUrl)
    if let cachedSummary, createNewCaching {
        let snapshot = try convertCreateNewSummaryTreeToTreeAndBlobs(cachedSummary, treeId: JSString(summaryHandle))
        try putCreateNewSnapshot(snapshot, network: network, persistedCache: persistedCache)
    }
    return odspResolvedUrl
}

/// EpochTracker.put of the create-new snapshot: it needs the epoch learned from the create call.
private func putCreateNewSnapshot(_ snapshot: CompactSnapshot, network: OdspNetwork, persistedCache: LocalPersistentCache) throws {
    guard let epoch = network.epochTracker.fluidEpoch else { throw JSONDecodingError("0x1dd") }
    let now = Date().timeIntervalSince1970 * 1000
    persistedCache.put(docId: network.fileEntry.docId, key: snapshotCacheKey, entry: .init(value: .snapshot(snapshot), fluidEpoch: epoch, cacheEntryTime: now), now: now)
}

/// createNewEmptyFluidFile: PUT an empty `<name>.tmp` and return its item ID.
func createNewEmptyFluidFile(network: OdspNetwork, newFileInfo: INewFileInfo) async throws -> String {
    let encodedFilename = encodeOdspComponent(newFileInfo.filename + ".tmp")
    let url = try getApiRoot(newFileInfo.siteUrl) + "/drives/" + newFileInfo.driveId + "/" + getNewFileItemPath(newFileInfo, encodedFilename: encodedFilename) + ":/content?@name.conflictBehavior=rename&select=id,name,parentReference"
    let response = try await network.authorized(url: url, method: "PUT", make: { auth, _ in
        var headers = try getHeadersWithAuth(auth)
        headers["Content-Type"] = "application/json"
        return OdspRequest(url: url, method: "PUT", headers: headers, timeoutMs: nil, fetchType: .createFile)
    }, fetchResponse: { request in
        try await runWithRetry(sleep: { try await Task.sleep(for: .milliseconds($0)) }, random: { Double.random(in: 0..<1) }) {
            try await network.fetch(request)
        }
    })
    guard case .string(let id) = try response.json().asObject()["id"], !id.description.isEmpty else {
        throw OdspNetworkError("incorrectServerResponse", canRetry: false)
    }
    return id.description
}

/// renameEmptyFluidFile: PATCH the requested name onto the `.tmp` file; returns `{ id, name }`.
func renameEmptyFluidFile(network: OdspNetwork, odspParts: IOdspResolvedUrl, requestedFileName: String) async throws -> JSONValue {
    let url = try getApiRoot(odspParts.siteUrl) + "/drives/" + odspParts.driveId + "/items/" + odspParts.itemId + "?@name.conflictBehavior=rename"
    var body = JSObject<JSONValue>()
    body["name"] = .string(JSString(requestedFileName))
    let response = try await network.authorized(url: url, method: "PATCH", make: { auth, _ in
        var headers = try getHeadersWithAuth(auth)
        headers["Content-Type"] = "application/json"
        return OdspRequest(url: url, method: "PATCH", headers: headers, body: Data(JSON.stringify(.object(body)).utf8), timeoutMs: nil, fetchType: .renameFile)
    }, fetchResponse: { request in
        try await runWithRetry(sleep: { try await Task.sleep(for: .milliseconds($0)) }, random: { Double.random(in: 0..<1) }) {
            try await network.fetch(request)
        }
    })
    let content = try response.json()
    guard case .string(let id) = try content.asObject()["id"], !id.description.isEmpty else {
        throw OdspNetworkError("incorrectServerResponse", canRetry: false)
    }
    return content
}

/// createNewFluidFileFromSummary: POST the container snapshot to `<item path>:/opStream/snapshots/snapshot`.
func createNewFluidFileFromSummary(network: OdspNetwork, newFileInfo: INewFileInfo, createNewSummary: ISummaryTree) async throws -> (content: JSONValue, summary: ISummaryTree) {
    let encodedFilename = encodeOdspComponent(newFileInfo.filename)
    let baseUrl = try getApiRoot(newFileInfo.siteUrl) + "/drives/" + newFileInfo.driveId + "/" + getNewFileItemPath(newFileInfo, encodedFilename: encodedFilename)
    let (containerSnapshot, mutated) = try convertSummaryIntoContainerSnapshot(createNewSummary)
    let content = try await createNewFluidContainerCore(network: network, containerSnapshot: containerSnapshot, initialUrl: baseUrl + ":/opStream/snapshots/snapshot", fetchType: .createFile)
    guard case .string(let itemId) = try content.asObject()["itemId"], !itemId.description.isEmpty else {
        throw OdspNetworkError("incorrectServerResponse", canRetry: false)
    }
    return (content, mutated)
}

/// createNewContainerOnExistingFile: upload the detached summary into an existing item.
func createNewContainerOnExistingFile(network: OdspNetwork, fileInfo: IExistingFileInfo, createNewSummary: ISummaryTree?, persistedCache: LocalPersistentCache, createNewCaching: Bool, isClpCompliantApp: Bool?, eTag: String?) async throws -> IOdspResolvedUrl {
    guard let createNewSummary else { throw OdspNetworkError("usageError", canRetry: false) }
    let baseUrl = try getApiRoot(fileInfo.siteUrl) + "/drives/" + fileInfo.driveId + "/items/" + fileInfo.itemId
    let (containerSnapshot, mutated) = try convertSummaryIntoContainerSnapshot(createNewSummary)
    var additionalHeaders: [(String, String)] = []
    if let eTag { additionalHeaders.append(("If-Match", eTag)) }
    let content = try await createNewFluidContainerCore(network: network, containerSnapshot: containerSnapshot, initialUrl: baseUrl + "/opStream/snapshots/snapshot", fetchType: .uploadSummary, additionalHeaders: additionalHeaders)
    let summaryHandle = try content.member("id").asString()
    let odspUrl = createOdspUrl(siteUrl: fileInfo.siteUrl, driveId: fileInfo.driveId, itemId: fileInfo.itemId, dataStorePath: "/")
    var headers = JSObject<JSONValue>()
    headers["X-CLP-Compliant-App"] = isClpCompliantApp.map { .bool($0) }
    headers["eTag"] = eTag.map { .string(JSString($0)) }
    let odspResolvedUrl = try OdspDriverUrlResolver().resolveOdspUrl(IRequest(url: odspUrl, headers: headers))
    network.updateResolvedUrl(odspResolvedUrl)
    if createNewCaching {
        let snapshot = try convertCreateNewSummaryTreeToTreeAndBlobs(mutated, treeId: summaryHandle)
        try putCreateNewSnapshot(snapshot, network: network, persistedCache: persistedCache)
    }
    return odspResolvedUrl
}
