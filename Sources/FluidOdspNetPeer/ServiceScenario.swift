import FluidDriverDefinitions
import FluidJS
import FluidOdspDriver
import Foundation
import Synchronization

// The Swift side of the ODSP 3 gate (harness/src/odsp-net/service): the same client steps as
// oracle.ts, through the Swift OdspDocumentServiceFactory, with the same outcome shape.

private let harnessClient = #"{"mode":"write","details":{"capabilities":{"interactive":true},"environment":"harness"},"permission":[],"user":{"id":"user"},"scopes":[]}"#

/// Thread-safe append-only log the token fetchers and the event reader write into.
private final class Log: Sendable {
    private let entries = Mutex<[JSONValue]>([])
    func append(_ value: JSONValue) {
        entries.withLock { $0.append(value) }
    }
    var values: [JSONValue] {
        entries.withLock { $0 }
    }
}

private func object(_ pairs: [(JSString, JSONValue?)]) -> JSONValue {
    var result = JSObject<JSONValue>()
    for (key, value) in pairs { result[key] = value }
    return .object(result)
}

private func string(_ value: String?) -> JSONValue? {
    value.map { .string(JSString($0)) }
}

private func hex(_ bytes: [UInt8]) -> JSONValue {
    .string(JSString(bytes.map { String(format: "%02x", $0) }.joined()))
}

private func bytes(_ hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        result.append(UInt8(hex[index..<next], radix: 16) ?? 0)
        index = next
    }
    return result
}

/// oracle.ts errorOutcome.
func errorOutcome(_ error: Error) -> JSONValue {
    if let error = error as? OdspNetworkError {
        return object([("errorType", string(error.errorType)), ("canRetry", .bool(error.canRetry)), ("statusCode", error.statusCode.map { .number(Double($0)) })])
    }
    if let error = error as? JSONDecodingError { return object([("error", string(error.description))]) }
    return object([("error", string(String(describing: error)))])
}

/// oracle.ts normalizeUuids: driver-generated UUIDs become their first-seen index in JSON text order.
private func normalizeUuids(_ value: JSONValue) throws -> JSONValue {
    let text = JSON.stringify(value)
    guard let pattern = try? NSRegularExpression(pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: [.caseInsensitive]) else { throw JSONDecodingError("bad pattern") }
    var seen: [String: String] = [:]
    var output = ""
    var last = text.startIndex
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let range = Range(match.range, in: text) else { continue }
        output += text[last..<range.lowerBound]
        let found = String(text[range])
        let name = seen[found] ?? "UUID-\(seen.count)"
        seen[found] = name
        output += name
        last = range.upperBound
    }
    output += text[last...]
    return try JSON.parse(output)
}

private func snapshotOutcome(_ snapshot: ISnapshot) throws -> JSONValue {
    let blobs = snapshot.blobContents.buffers.entries.map { id, buffer in JSONValue.array([.string(id), hex(buffer)]) }
    return try normalizeUuids(object([
        ("snapshotTree", snapshot.snapshotTree.json),
        ("blobContents", .array(blobs)),
        ("ops", .array(snapshot.ops.map(\.json))),
        ("sequenceNumber", snapshot.sequenceNumber.map { .number(Double($0)) }),
        ("latestSequenceNumber", snapshot.latestSequenceNumber.map { .number(Double($0)) }),
        ("snapshotFormatV", .number(Double(snapshot.snapshotFormatV))),
    ]))
}

private func tokenOptions(_ kind: String, _ options: TokenFetchOptions) -> JSONValue {
    let request = options.requestURL.map { url in object([("url", string(url)), ("method", string(options.method))]) }
    return object([("kind", string(kind)), ("refresh", .bool(options.refresh)), ("claims", string(options.claims)), ("tenantId", string(options.tenantId)), ("siteUrl", string(options.siteUrl)), ("driveId", string(options.driveId)), ("itemId", string(options.itemId)), ("request", request)])
}

private func protocolSummary(_ sequenceNumber: Int) -> String {
    let attributes = JSON.stringify(object([("minimumSequenceNumber", .number(Double(sequenceNumber))), ("sequenceNumber", .number(Double(sequenceNumber)))]))
    return #"{"type":1,"tree":{"attributes":{"type":2,"content":"# + JSON.stringify(.string(JSString(attributes))) + #"},"quorumMembers":{"type":2,"content":"[]"},"quorumProposals":{"type":2,"content":"[]"},"quorumValues":{"type":2,"content":"[]"}}}"#
}

/// oracle.ts uploadSummary.
private func uploadSummary(_ scenario: JSONValue) throws -> (summary: SummaryTree, context: ISummaryContext) {
    let server = try scenario.member("server")
    let latest = try server.member("sequenceNumber").asInt() + server.member("snapshotOps").asInt() + server.member("restOps").asInt() + scenario.member("submits").asInt()
    let seed = try scenario.member("seed").asInt()
    let kind = try scenario.member("kind").asString()
    let appWithoutHandle = #"{"type":1,"tree":{".metadata":{"type":2,"content":"{\"summaryFormatVersion\":1}"},"data":{"type":2,"content":{"0":0,"1":128,"2":255}}}}"#
    let app = #"{"type":1,"tree":{".metadata":{"type":2,"content":"{\"summaryFormatVersion\":1}"},"data":{"type":2,"content":{"0":0,"1":128,"2":255}},"reuse":{"type":3,"handleType":1,"handle":"/.channels/old"}}}"#
    let summaryText: String
    let ackHandle: JSONValue?
    let referenceSequenceNumber: Int
    if kind == "createEmpty" {
        summaryText = #"{"type":1,"tree":{".protocol":"# + protocolSummary(0) + #",".app":"# + appWithoutHandle + "}}"
        ackHandle = nil
        referenceSequenceNumber = 0
    } else if try scenario.member("summary").asString() == "container" {
        summaryText = #"{"type":1,"tree":{".protocol":"# + protocolSummary(latest) + #",".app":"# + app + "}}"
        ackHandle = .string(JSString("ack-\(seed)"))
        referenceSequenceNumber = latest
    } else {
        summaryText = #"{"type":1,"tree":{".channels":{"type":1,"tree":{"channel":{"type":2,"content":"text"}},"unreferenced":true}}}"#
        ackHandle = .string(JSString("ack-\(seed)"))
        referenceSequenceNumber = latest
    }
    let context = try ISummaryContext(json: object([("ackHandle", ackHandle), ("referenceSequenceNumber", .number(Double(referenceSequenceNumber)))]))
    return (try SummaryTree(json: JSON.parse(summaryText)), context)
}

/// oracle.ts createNewSummary.
private let createNewSummaryText = #"{"type":1,"tree":{".app":{"type":1,"tree":{".metadata":{"type":2,"content":"{\"createContainerRuntimeVersion\":\"3.11.0\"}"},".channels":{"type":1,"tree":{"root":{"type":2,"content":{"0":1,"1":2,"2":3}}},"groupId":"g"}}},".protocol":{"type":1,"tree":{"attributes":{"type":2,"content":"{ \"minimumSequenceNumber\": 0, \"sequenceNumber\": 0, \"term\": 1 }"},"quorumMembers":{"type":2,"content":"[]"},"quorumProposals":{"type":2,"content":"[]"},"quorumValues":{"type":2,"content":"[[\"code\",{\"key\":\"code\",\"value\":{\"package\":\"p\"},\"approvalSequenceNumber\":0,\"commitSequenceNumber\":0,\"sequenceNumber\":0}]]"}}}}}"#

private func waitFor(_ events: Log, _ predicate: (JSONValue) -> Bool) async throws {
    for _ in 0..<500 {
        if events.values.contains(where: predicate) { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw JSONDecodingError("timed out waiting for a socket event")
}

private func eventJSON(_ event: DocumentDeltaConnectionEvent) -> JSONValue {
    switch event {
    case .op(let documentId, let messages):
        return .array([.string("op"), .string(documentId), .array(messages.map(\.json))])
    case .signal(let signals):
        // The connection emits one signal unwrapped and several as an array.
        let payload: JSONValue = signals.count == 1 ? signals[0].json : .array(signals.map(\.json))
        return .array([.string("signal"), payload])
    case .nack(let documentId, let nacks):
        return .array([.string("nack"), .string(documentId), .array(nacks.map(\.json))])
    case .disconnect(let reason):
        return .array([.string("disconnect"), errorOutcome(reason)])
    case .pong(let latency):
        return .array([.string("pong"), .number(latency)])
    }
}

/// oracle.ts clpHeaders: the `X-CLP-Compliant-App` resolve header, when the scenario sets one.
private func clpHeaders(_ scenario: JSONValue) throws -> JSObject<JSONValue>? {
    let clp = try scenario.member("clp")
    guard clp != .null else { return nil }
    var headers = JSObject<JSONValue>()
    headers["X-CLP-Compliant-App"] = clp
    return headers
}

/// Runs one oracle.ts scenario through the Swift factory.
func runServiceScenario(_ scenario: JSONValue) async throws -> JSONValue {
    let tokens = Log()
    let steps = Log()
    let events = Log()
    var out = JSObject<JSONValue>()
    let getStorageToken: TokenFetcher = { options in
        tokens.append(tokenOptions("storage", options))
        return .token(options.refresh ? "refreshed" : "initial")
    }
    var getWebsocketToken: TokenFetcher?
    if try scenario.member("websocketToken") == .bool(true) {
        getWebsocketToken = { @Sendable options in
            tokens.append(tokenOptions("websocket", options))
            return .token("push-token")
        }
    }
    let factory = OdspDocumentServiceFactory(getStorageToken: getStorageToken, getWebsocketToken: getWebsocketToken)
    let resolver = OdspDriverUrlResolver()
    let origin = try scenario.member("origin").asString().description
    let driveId = try scenario.member("driveId").asString().description
    let kind = try scenario.member("kind").asString()
    let seed = try scenario.member("seed").asInt()
    var service: (any IDocumentService)?
    var connection: (any IDocumentDeltaConnection)?
    var reader: Task<Void, Never>?
    do {
        if kind == "load" {
            let url = createOdspUrl(siteUrl: origin, driveId: driveId, itemId: try scenario.member("itemId").asString().description, dataStorePath: "")
            guard let resolvedUrl = try await resolver.resolve(IRequest(url: url, headers: try clpHeaders(scenario))) else { throw JSONDecodingError("unresolved") }
            out["resolvedUrl"] = resolvedUrl.json
            out["absoluteUrl"] = string(try await resolver.getAbsoluteUrl(resolvedUrl, relativeUrl: "/store/x"))
            service = try await factory.createDocumentService(resolvedUrl, clientIsSummarizer: false)
        } else {
            let created = createOdspCreateContainerRequest(siteUrl: origin, driveId: driveId, filePath: try scenario.member("filePath").asString().description, fileName: try scenario.member("fileName").asString().description)
            var headers = created.headers ?? JSObject()
            for (key, value) in try clpHeaders(scenario)?.entries ?? [] { headers[key] = value }
            let request = IRequest(url: created.url, headers: headers)
            out["createRequest"] = object([("url", string(request.url)), ("headers", request.headers.map { .object($0) })])
            guard var resolvedUrl = try await resolver.resolve(request) else { throw JSONDecodingError("unresolved") }
            out["createResolvedUrl"] = resolvedUrl.json
            if try scenario.member("hostContext") == .bool(true) {
                resolvedUrl = try getOdspResolvedUrl(resolvedUrl).setting("context", .string(JSString("context-\(seed)"))).setting("appName", .string("harness-app")).resolvedUrl
            }
            let summary = kind == "create" ? try SummaryTree(json: JSON.parse(createNewSummaryText)) : nil
            service = try await factory.createContainer(summary, resolvedUrl: resolvedUrl, clientIsSummarizer: false)
            out["resolvedUrl"] = service?.resolvedUrl.json
        }
        guard let service else { throw JSONDecodingError("no service") }
        if let policies = service.policies {
            out["policies"] = object([("storageOnly", policies.storageOnly.map { .bool($0) }), ("summarizeProtocolTree", policies.summarizeProtocolTree.map { .bool($0) }), ("supportGetSnapshotApi", policies.supportGetSnapshotApi.map { .bool($0) })])
        }
        let storage = try await service.connectToStorage()
        if try scenario.member("loadPath").asString() == "versions" {
            let versions = try await storage.getVersions(nil, count: 1, scenarioName: nil, fetchSource: nil)
            steps.append(.array([.string("latestVersion"), .array(versions.map(\.json))]))
            let tree = try await storage.getSnapshotTree(versions.first, scenarioName: nil)
            steps.append(.array([.string("versionTree"), try normalizeUuids(tree?.json ?? .null)]))
        } else {
            let snapshot = try await storage.getSnapshot(nil)
            steps.append(.array([.string("snapshot"), try snapshotOutcome(snapshot)]))
        }
        for id in try scenario.member("readBlobs").asArray() {
            steps.append(.array([.string("readBlob"), id, hex(try await storage.readBlob(id.asString()))]))
        }
        if try scenario.member("snapshotTree") == .bool(true) {
            let tree = try await storage.getSnapshotTree(nil, scenarioName: nil)
            steps.append(.array([.string("snapshotTree"), try normalizeUuids(tree?.json ?? .null)]))
        }
        let versionCount = try scenario.member("versions").asInt()
        if versionCount > 0 {
            let versionId: JSString? = versionCount == 1 ? nil : JSString("snap-\(seed)")
            let versions = try await storage.getVersions(versionId, count: versionCount, scenarioName: "harnessVersions", fetchSource: nil)
            steps.append(.array([.string("versions"), .array(versions.map(\.json))]))
        }
        let connect = { () async throws -> any IDocumentDeltaConnection in
            let created = try await service.connectToDeltaStream(try IClient(json: JSON.parse(harnessClient)))
            let details = try created.details.json.asObject()
            steps.append(.array([.string("connected"), object([
                ("clientId", details["clientId"]),
                ("mode", details["mode"]),
                ("existing", details["existing"]),
                ("version", details["version"]),
                ("serviceConfiguration", details["serviceConfiguration"]),
                ("checkpointSequenceNumber", details["checkpointSequenceNumber"]),
                ("initialMessages", details["initialMessages"]),
                ("initialSignals", details["initialSignals"]),
                ("initialClients", details["initialClients"]),
            ])]))
            reader = Task {
                do {
                    for try await event in created.events { events.append(eventJSON(event)) }
                } catch {
                    events.append(.array([.string("streamError"), errorOutcome(error)]))
                }
            }
            return created
        }
        let connectMode = try scenario.member("connect").asString()
        if connectMode == "before" { connection = try await connect() }
        let deltaStorage = try await service.connectToDeltaStorage()
        let fetchTo = try scenario.member("fetchTo")
        let stream = deltaStorage.fetchMessages(try scenario.member("fetchFrom").asInt(), to: fetchTo == .null ? nil : try fetchTo.asInt(), cachedOnly: false, fetchReason: "harness")
        var batches: [JSONValue] = []
        for try await batch in stream { batches.append(.array(batch.map(\.json))) }
        steps.append(.array([.string("deltas"), .array(batches)]))
        if connectMode == "after" { connection = try await connect() }
        if let connection {
            let server = try scenario.member("server")
            let latest = try server.member("sequenceNumber").asInt() + server.member("snapshotOps").asInt() + server.member("restOps").asInt()
            let submits = try scenario.member("submits").asInt()
            if submits > 0 {
                for index in 1...submits {
                    let message = try IDocumentMessage(json: object([("clientSequenceNumber", .number(Double(index))), ("referenceSequenceNumber", .number(Double(latest))), ("type", .string("op")), ("contents", object([("submit", .number(Double(index)))]))]))
                    connection.submit([message])
                    try await waitFor(events) { JSON.stringify($0).hasPrefix(#"["op""#) && JSON.stringify($0).contains("\"submit\":\(index)") }
                }
            }
            if try scenario.member("signal") == .bool(true) {
                try connection.submitSignal(#"{"type":"hello"}"#, targetClientId: nil)
                try await waitFor(events) { JSON.stringify($0).hasPrefix(#"["signal""#) && JSON.stringify($0).contains("hello") }
            }
        }
        if try scenario.member("summary").asString() != "none" {
            let (summary, context) = try uploadSummary(scenario)
            steps.append(.array([.string("upload"), .string(try await storage.uploadSummaryWithContext(summary, context: context))]))
        }
        if case .string(let blob) = try scenario.member("createBlob") {
            steps.append(.array([.string("createBlob"), try await storage.createBlob(bytes(blob.description)).json]))
        }
        if kind != "load" { out["finalResolvedUrl"] = service.resolvedUrl.json }
    } catch {
        steps.append(.array([.string("error"), errorOutcome(error)]))
    }
    if let connection {
        await connection.dispose()
        try await waitFor(events) { JSON.stringify($0).hasPrefix(#"["disconnect""#) }
    }
    await reader?.value
    service?.dispose(nil)
    out["tokens"] = .array(tokens.values)
    out["steps"] = .array(steps.values)
    out["events"] = .array(events.values)
    return .object(out)
}
