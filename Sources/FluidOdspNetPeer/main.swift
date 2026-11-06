import FluidDriverDefinitions
import FluidJS
import FluidOdspDriver
import Foundation

func treeJSON(_ tree: CompactSnapshotTree) -> JSONValue {
    var object = JSObject<JSONValue>()
    if let id = tree.id { object["id"] = .string(id) }
    var blobs = JSObject<JSONValue>()
    for (key, value) in tree.blobs.entries { blobs[key] = .string(value) }
    object["blobs"] = .object(blobs)
    var trees = JSObject<JSONValue>()
    for (key, value) in tree.trees.entries { trees[key] = treeJSON(value) }
    object["trees"] = .object(trees)
    if let flag = tree.unreferenced { object["unreferenced"] = .bool(flag) }
    if let group = tree.groupId { object["groupId"] = .string(group) }
    return .object(object)
}

while let line = readLine() {
    do {
        let input = try JSON.parse(line)
        if try input.asObject()["retry"] == .bool(true) {
            var elapsed = 0.0
            var times: [JSONValue] = []
            var canRetry = true
            do {
                let _: Int = try await runWithRetry(sleep: { elapsed += $0 }, random: { 0 }) {
                    times.append(.number(elapsed))
                    var error = OdspNetworkError("throttlingError", canRetry: true, statusCode: 409)
                    error.odsp409Error = true
                    error.retryAfterMs = 1000
                    throw error
                }
            } catch let error as OdspNetworkError { canRetry = error.canRetry }
            var result = JSObject<JSONValue>()
            result["attemptTimes"] = .array(times)
            result["canRetry"] = .bool(canRetry)
            FileHandle.standardOutput.write(Data((JSON.stringify(.object(result)) + "\n").utf8))
            continue
        }
        let url = try input.member("url").asString().description
        let tracker = EpochTracker()
        let seed = try input.member("seed").asInt()
        if seed % 4 == 0 && seed % 9 >= 7 { try tracker.validateEpoch("E") }
        let origin = try input.member("origin").asString().description
        let resource = try OdspDriverUrlResolver().resolve(origin + "?driveId=d&itemId=i&path=")
        let network = OdspNetwork(resolvedUrl: resource, epochTracker: tracker, tokenFetcher: { options in .token(options.refresh ? "refreshed" : "initial") })
        let storage = OdspDeltaStorageService(deltaFeedUrl: url, network: network)
        var output = JSObject<JSONValue>()
        do {
            let kind = try input.member("kind").asInt()
            let origin = try input.member("origin").asString().description
            let resolved = try OdspDriverUrlResolver().resolve(origin + "?driveId=d&itemId=i&path=")
            if kind == 1 {
                output["join"] = try await fetchJoinSession(resolved: resolved, network: network, displayName: "Guest")
            } else if kind == 2 {
                let snapshot = try await downloadSnapshot(resolved: resolved, network: network)
                var value = JSObject<JSONValue>()
                value["tree"] = treeJSON(snapshot.snapshotTree)
                if let seq = snapshot.sequenceNumber { value["sequenceNumber"] = .number(Double(seq)) }
                value["ops"] = .array(snapshot.ops)
                value["blobs"] = .array(try snapshot.blobContents.entries.map { id, content in
                    guard case .buffer(let bytes) = content else { throw JSONDecodingError("expected buffer") }
                    return .array([.string(id), .string(JSString(bytes.map { String(format: "%02x", $0) }.joined()))])
                })
                output["snapshot"] = .object(value)
            } else if kind == 3 {
                let tree = try ISummaryTree(json: JSON.parse("{\"type\":1,\"tree\":{\"text\":{\"type\":2,\"content\":\"hello\"},\"binary\":{\"type\":2,\"content\":{\"0\":0,\"1\":255}},\"reuse\":{\"type\":3,\"handleType\":1,\"handle\":\"/old\"},\"attachment\":{\"type\":4,\"id\":\"attachment\"}}}"))
                var context = JSObject<JSONValue>()
                context["ackHandle"] = .string("parent")
                context["referenceSequenceNumber"] = try input.member("seed")
                let upload = OdspSummaryUploadManager(snapshotStorageUrl: resolved.snapshotStorageUrl, network: network)
                output["summary"] = .string(JSString(try await upload.writeSummaryTree(tree, context: ISummaryContext(json: .object(context)), relayTenantId: "t", relaySessionId: "session")))
            } else {
                output["messages"] = .array(try await storage.get(from: input.member("from").asInt(), to: input.member("to").asInt()))
            }
        } catch let error as OdspNetworkError {
            output["errorType"] = .string(JSString(error.errorType))
            output["canRetry"] = .bool(error.canRetry)
            if let status = error.statusCode { output["statusCode"] = .number(Double(status)) }
            if let delay = error.retryAfterMs { output["retryAfterMs"] = .number(delay) }
            if let epoch = error.serverEpoch { output["serverEpoch"] = .string(JSString(epoch)) }
            if let claims = error.claims { output["claims"] = .string(JSString(claims)) }
            if let tenant = error.tenantId { output["tenantId"] = .string(JSString(tenant)) }
        }
        output["cacheClears"] = .number(Double(tracker.cacheClearCount))
        FileHandle.standardOutput.write(Data((JSON.stringify(.object(output)) + "\n").utf8))
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}
