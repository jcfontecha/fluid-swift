import FluidDriverDefinitions
import FluidJS
import FluidOdspDriver
import Foundation
import Synchronization

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

actor JoinNetwork {
    private let network: OdspNetwork
    private let resolved: IOdspResolvedUrl
    init(origin: String) throws {
        resolved = try OdspDriverUrlResolver().resolve(origin + "?driveId=d&itemId=i&path=")
        network = OdspNetwork(resolvedUrl: resolved, epochTracker: EpochTracker(), tokenFetcher: { _ in .token("initial") })
    }
    func limit(url: String) async throws { _ = try await network.fetch(OdspRequest(url: url)) }
    func validateEpoch(_ epoch: String?) throws { try network.epochTracker.validateEpoch(epoch) }
    func fetch(requestSocketToken: Bool, displayName: String?) async throws -> JSONValue {
        try await fetchJoinSession(resolved: resolved, network: network, requestSocketToken: requestSocketToken, displayName: displayName)
    }
}

actor SnapshotPutProbe {
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?
    func put() {
        finished = true
        waiter?.resume()
        waiter = nil
    }
    func wait() async {
        if finished { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

actor PrefetchPutGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var finished = false
    func put() async throws {
        entered = true
        waiting?.resume()
        waiting = nil
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release(fail: Bool) {
        finished = true
        if fail { continuation?.resume(throwing: JSONDecodingError("persisted put failed")) }
        else { continuation?.resume() }
        continuation = nil
    }
}
actor PrefetchClock {
    private var elapsed = 0.0
    private var deadline: Double?
    private var sleeper: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func sleep(_ delay: Double) async {
        deadline = elapsed + delay
        waiting?.resume()
        waiting = nil
        await withCheckedContinuation { sleeper = $0 }
    }
    func waitUntilScheduled() async {
        if deadline != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func advance(_ delta: Double) {
        elapsed += delta
        if let deadline, elapsed >= deadline {
            sleeper?.resume()
            sleeper = nil
            self.deadline = nil
        }
    }
}

actor RedemptionAttempts {
    private(set) var count = 0
    func record() { count += 1 }
}
actor RedemptionPeer {
    private let network: OdspNetwork
    private let origin: String
    init(origin: String, mode: String, clock: PrefetchClock, attempts: RedemptionAttempts) throws {
        self.origin = origin
        let resolved = try OdspDriverUrlResolver().resolve(origin + "?driveId=d&itemId=i&path=")
        let tracker = EpochTrackerWithRedemption(sleep: { delay in
            if mode == "timeout" { await clock.sleep(delay) }
            else { try await Task.sleep(for: .milliseconds(delay)) }
        })
        network = OdspNetwork(resolvedUrl: resolved, epochTracker: tracker, tokenFetcher: { _ in .token("initial") }, send: { request in
            if request.url.hasSuffix("/join") { await attempts.record() }
            return try await fetchHelper(request)
        })
    }
    func perform(_ type: OdspFetchType) async throws -> JSONValue {
        var result = JSObject<JSONValue>()
        do {
            let path = type == .joinSession ? "/redeem/join" : "/redeem/tree"
            _ = try await network.fetch(OdspRequest(url: origin + path, method: "GET", fetchType: type))
            result["ok"] = .bool(true)
        } catch let error as OdspNetworkError {
            result["errorType"] = .string(JSString(error.errorType))
            result["canRetry"] = .bool(error.canRetry)
            if let code = error.statusCode { result["statusCode"] = .number(Double(code)) }
        }
        return .object(result)
    }
}

func flushOutcome(_ factory: OdspSocketIOFactory, _ id: UUID) async throws -> JSONValue {
    do {
        _ = try await factory.flush(id)
        var object = JSObject<JSONValue>()
        object["ok"] = .bool(true)
        return .object(object)
    } catch let error as JSONDecodingError {
        var object = JSObject<JSONValue>()
        object["error"] = .string(JSString(error.description))
        return .object(object)
    }
}

while let line = readLine() {
    do {
        let input = try JSON.parse(line)
        if let mode = try input.asObject()["redemption"]?.asString().description {
            let clock = PrefetchClock()
            let attempts = RedemptionAttempts()
            let peer = try RedemptionPeer(origin: input.member("origin").asString().description, mode: mode, clock: clock, attempts: attempts)
            let join = Task { try await peer.perform(.joinSession) }
            var output = JSObject<JSONValue>()
            if mode == "timeout" {
                await clock.waitUntilScheduled()
                await clock.advance(14999)
                output["before"] = .number(Double(await attempts.count))
                await clock.advance(1)
                output["join"] = try await join.value
            } else {
                let tree = Task { try await peer.perform(.treesLatest) }
                output["join"] = try await join.value
                output["tree"] = try await tree.value
            }
            FileHandle.standardOutput.write(Data((JSON.stringify(.object(output)) + "\n").utf8))
            continue
        }
        if try input.asObject()["redirect"] == .bool(true) {
            let origin = try input.member("origin").asString().description
            let resolved = try OdspDriverUrlResolver().resolve(origin + "?driveId=d&itemId=i&path=")
            let tracker = EpochTracker()
            let network = OdspNetwork(resolvedUrl: resolved, epochTracker: tracker, tokenFetcher: { _ in .token("initial") })
            var result = JSObject<JSONValue>()
            do { _ = try await network.fetch(OdspRequest(url: origin + "/redirect")) }
            catch let error as OdspNetworkError {
                result["errorType"] = .string(JSString(error.errorType))
                result["canRetry"] = .bool(error.canRetry)
                if let status = error.statusCode { result["statusCode"] = .number(Double(status)) }
                if let site = error.redirectUrl?.siteUrl { result["redirectSiteUrl"] = .string(JSString(site)) }
            }
            result["cacheClears"] = .number(Double(tracker.cacheClearCount))
            FileHandle.standardOutput.write(Data((JSON.stringify(.object(result)) + "\n").utf8))
            continue
        }
        if try input.asObject()["limit"] == .bool(true) {
            let origin = try input.member("origin").asString().description
            let network = try JoinNetwork(origin: origin)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<48 { group.addTask { try await network.limit(url: origin + "/limit") } }
                try await group.waitForAll()
            }
            FileHandle.standardOutput.write(Data("{\"done\":48}\n".utf8))
            continue
        }
        if let cases = try input.asObject()["epochCache"]?.asArray() {
            var results: [JSONValue] = []
            for item in cases {
                let fields = try item.asObject()
                var puts: [JSONValue] = []
                let tracker = EpochTracker(now: { 432000000 }, cacheGet: { _ in fields["value"] }, cachePut: { entry, value in
                    var put = JSObject<JSONValue>()
                    put["type"] = .string(JSString(entry.type))
                    put["key"] = .string(JSString(entry.key))
                    put["docId"] = .string("doc")
                    put["value"] = value
                    puts.append(.object(put))
                })
                if let epoch = try fields["epoch"]?.asString().description { try tracker.validateEpoch(epoch) }
                let entry = EpochTracker.Entry(type: try item.member("type").asString().description, key: "key")
                let value = await tracker.get(entry)
                if let value = fields["put"] { try await tracker.put(entry, value: value) }
                var result = JSObject<JSONValue>()
                result["value"] = value ?? .null
                result["epoch"] = tracker.fluidEpoch.map { .string(JSString($0)) } ?? .null
                result["clears"] = .number(Double(tracker.cacheClearCount))
                result["puts"] = .array(puts)
                results.append(.object(result))
            }
            FileHandle.standardOutput.write(Data((JSON.stringify(.array(results)) + "\n").utf8))
            continue
        }
        if try input.asObject()["prefetch"] == .bool(true) {
            guard case .bool(let failPut) = try input.member("failPut") else { throw JSONDecodingError("invalid failPut") }
            let origin = try input.member("origin").asString().description
            let resolved = try OdspDriverUrlResolver().resolve(origin + "?driveId=d&itemId=i&path=")
            let network = OdspNetwork(resolvedUrl: resolved, epochTracker: EpochTracker(), tokenFetcher: { _ in .token("initial") })
            let put = PrefetchPutGate()
            let clock = PrefetchClock()
            let storage = OdspDocumentStorageService(resolved: resolved, network: network, cachePut: { _ in try await put.put() }, sleep: { await clock.sleep($0) })
            let result = await storage.prefetchLatestSnapshot()
            guard await storage.hasPrefetchedSnapshot else { throw JSONDecodingError("prefetch not published") }
            let snapshot = try await storage.getSnapshot()
            await put.waitUntilEntered()
            let publishedBeforePut = await !put.finished
            await put.release(fail: failPut)
            let success = await result.value
            if success { await clock.waitUntilScheduled() }
            await clock.advance(4999)
            let beforeFiveSeconds = await storage.hasPrefetchedSnapshot
            await clock.advance(1)
            if success {
                for _ in 0..<100 where await storage.hasPrefetchedSnapshot { await Task.yield() }
            }
            var output = JSObject<JSONValue>()
            if let seq = snapshot.sequenceNumber { output["sequenceNumber"] = .number(Double(seq)) }
            output["publishedBeforePut"] = .bool(publishedBeforePut)
            output["success"] = .bool(success)
            output["beforeFiveSeconds"] = .bool(beforeFiveSeconds)
            output["afterFiveSeconds"] = .bool(await storage.hasPrefetchedSnapshot)
            FileHandle.standardOutput.write(Data((JSON.stringify(.object(output)) + "\n").utf8))
            continue
        }
        if let kind = try input.asObject()["snapshotRace"]?.asString().description {
            let origin = try input.member("origin").asString().description
            let resolved = try OdspDriverUrlResolver().resolve(origin + "?driveId=d&itemId=i&path=")
            let network = OdspNetwork(resolvedUrl: resolved, epochTracker: EpochTracker(), tokenFetcher: { _ in .token("initial") })
            let put = SnapshotPutProbe()
            let storage = OdspDocumentStorageService(resolved: resolved, network: network, concurrentSnapshotFetch: true, cacheRead: {
                if kind == "networkFirst" || kind == "networkFailure" || kind == "bothFailureNetworkFirst" { try await Task.sleep(for: .milliseconds(25)) }
                if kind == "cacheMiss" { return nil }
                if kind == "cacheFailure" || kind.hasPrefix("bothFailure") { throw JSONDecodingError("cache failure") }
                let snapshot = CompactSnapshot(snapshotTree: .init(id: "cached"), blobContents: .init(), ops: [], sequenceNumber: 10)
                return .init(snapshot: snapshot, fluidEpoch: "E", cacheEntryTime: Date().timeIntervalSince1970 * 1000)
            }, cachePut: { _ in await put.put() })
            var result = JSObject<JSONValue>()
            do {
                let snapshot = try await storage.getSnapshot()
                if kind != "networkFailure" { await put.wait() }
                if let sequence = snapshot.sequenceNumber { result["sequenceNumber"] = .number(Double(sequence)) }
            } catch let error as OdspNetworkError {
                result["errorType"] = .string(JSString(error.errorType))
                result["canRetry"] = .bool(error.canRetry)
                if let code = error.statusCode { result["statusCode"] = .number(Double(code)) }
            } catch let error as JSONDecodingError {
                guard error.description == "cache failure" else { throw error }
                result["failure"] = .string("cache")
            }
            FileHandle.standardOutput.write(Data((JSON.stringify(.object(result)) + "\n").utf8))
            continue
        }
        if let kind = try input.asObject()["snapshotManager"]?.asString().description {
            let origin = try input.member("origin").asString().description
            let resolved = try OdspDriverUrlResolver().resolve(origin + "?driveId=d&itemId=i&path=")
            var timeouts: [JSONValue] = []
            let network = OdspNetwork(resolvedUrl: resolved, epochTracker: EpochTracker(), tokenFetcher: { _ in .token("initial") }, send: { request in
                if let timeout = request.timeoutMs { timeouts.append(.number(timeout)) }
                return try await fetchHelper(request)
            })
            let storage = OdspDocumentStorageService(resolved: resolved, network: network)
            var options = JSObject<JSONValue>()
            options["blobs"] = .number(2)
            if kind == "limited" { options["mds"] = .number(123) }
            if kind == "timeout" { options["timeout"] = .number(5000) }
            var result = JSObject<JSONValue>()
            do {
                let snapshot = try await storage.getSnapshot(noCache: true, summarizer: kind == "summarizer", options: options)
                if let sequence = snapshot.sequenceNumber { result["sequenceNumber"] = .number(Double(sequence)) }
                result["blobs"] = .number(Double(snapshot.blobContents.size))
            } catch let error as OdspNetworkError {
                result["errorType"] = .string(JSString(error.errorType))
                result["canRetry"] = .bool(error.canRetry)
                if let status = error.statusCode { result["statusCode"] = .number(Double(status)) }
            }
            result["timeouts"] = .array(timeouts)
            FileHandle.standardOutput.write(Data((JSON.stringify(.object(result)) + "\n").utf8))
            continue
        }
        if try input.asObject()["joinLive"] == .bool(true) {
            let clock = Mutex(0.0)
            let network = try JoinNetwork(origin: input.member("origin").asString().description)
            let stream = OdspDelayLoadedDeltaStream(hashedDocumentId: "doc", cache: OdspSessionJoinCache(), now: { clock.withLock { $0 } }, fetch: { requestSocketToken, displayName, _ in
                try await network.fetch(requestSocketToken: requestSocketToken, displayName: displayName)
            })
            let factory = OdspSocketIOFactory()
            let client = try JSON.parse("{\"mode\":\"write\",\"details\":{\"capabilities\":{\"interactive\":true},\"environment\":\"harness\"},\"permission\":[],\"user\":{\"id\":\"user\"},\"scopes\":[]}")
            let id = try await stream.connectToDeltaStream(client: client, factory: factory, displayName: "Guest", validateEpoch: { try await network.validateEpoch($0) })
            clock.withLock { $0 = 3570000 }
            _ = try await stream.joinSession(displayName: "Guest", refreshing: true, clientId: "client-session")
            do { _ = try await factory.flush(id) }
            catch is OdspNetworkError {}
            var result = JSObject<JSONValue>()
            result["disconnected"] = .bool(await stream.currentDeltaConnection == nil)
            result["timerCleared"] = .bool(await stream.refreshDeadline == nil)
            result["value"] = try await stream.joinSession(displayName: "Guest")
            await stream.clearJoinSessionTimer()
            try await factory.close()
            FileHandle.standardOutput.write(Data((JSON.stringify(.object(result)) + "\n").utf8))
            continue
        }
        if try input.asObject()["joinCache"] == .bool(true) {
            let clock = Mutex(0.0)
            let network = try JoinNetwork(origin: input.member("origin").asString().description)
            let stream = OdspDelayLoadedDeltaStream(hashedDocumentId: "doc", cache: OdspSessionJoinCache(), now: { clock.withLock { $0 } }, fetch: { requestSocketToken, displayName, _ in
                try await network.fetch(requestSocketToken: requestSocketToken, displayName: displayName)
            })
            var values: [JSONValue] = []
            for now in [0.0, 1000, 3569999, 3570000] {
                clock.withLock { $0 = now }
                var value = JSObject<JSONValue>()
                value["value"] = try await stream.joinSession(displayName: "Guest")
                value["refreshAfter"] = .number((await stream.refreshDeadline ?? now) - now)
                values.append(.object(value))
            }
            await stream.clearJoinSessionTimer()
            FileHandle.standardOutput.write(Data((JSON.stringify(.array(values)) + "\n").utf8))
            continue
        }
        if try input.asObject()["socket"] == .bool(true) {
            let factory = OdspSocketIOFactory()
            let client = try JSON.parse("{\"mode\":\"write\",\"details\":{\"capabilities\":{\"interactive\":true},\"environment\":\"harness\"},\"permission\":[],\"user\":{\"id\":\"user\"},\"scopes\":[]}")
            guard let url = URL(string: try input.member("origin").asString().description) else { throw JSONDecodingError("invalid URL") }
            let documentId = try input.member("documentId").asString().description
            var ids: [UUID] = []
            var events: [JSONValue] = []
            var output = JSObject<JSONValue>()
            do {
                if documentId == "parallel" {
                    async let one = factory.create(url: url, tenantId: "tenant", documentId: "parallel-first", token: .string("token"), client: client, nonce: "nonce-parallel-first")
                    async let two = factory.create(url: url, tenantId: "tenant", documentId: "parallel-second", token: .string("token"), client: client, nonce: "nonce-parallel-second")
                    let created = try await [one, two]
                    for id in created {
                        events.append(.array([.string("initial"), .array(try await factory.initialMessages(id)), .array(try await factory.initialSignals(id))]))
                    }
                    for id in created {
                        try await factory.dispose(id)
                        events += try await factory.takeEvents(id)
                    }
                    output["events"] = .array(events)
                    try await factory.close()
                    FileHandle.standardOutput.write(Data((JSON.stringify(.object(output)) + "\n").utf8))
                    continue
                }
                for document in [documentId, "second"] {
                    let id = try await factory.create(url: url, tenantId: "tenant", documentId: document, token: .string("token"), client: client, nonce: "nonce-" + document, epoch: ids.isEmpty ? nil : "E")
                    ids.append(id)
                    events.append(.array([.string("initial"), .array(try await factory.initialMessages(id)), .array(try await factory.initialSignals(id))]))
                }
                guard let first = ids.first else { throw JSONDecodingError("missing connection") }
                try await factory.submit(first, messages: [])
                try await factory.submitSignal(first, signals: [JSON.parse("{\"content\":\"outgoing\",\"targetClientId\":\"target\"}")])
                try await factory.requestOps(first, from: 1, to: 6)
                if documentId == "overlap" {
                    async let one = flushOutcome(factory, first)
                    async let two = flushOutcome(factory, first)
                    let results = try await [one, two].sorted { JSON.stringify($0) < JSON.stringify($1) }
                    for id in ids { try await factory.dispose(id) }
                    try await factory.close()
                    FileHandle.standardOutput.write(Data((JSON.stringify(.array(results)) + "\n").utf8))
                    continue
                }
                var result = try await factory.flush(first).asObject()
                result["nonce"] = .string("NONCE-2")
                for id in ids { events += try await factory.takeEvents(id) }
                events.append(.array([.string("flush"), .object(result)]))
                for id in ids {
                    try await factory.dispose(id)
                    events += try await factory.takeEvents(id)
                }
                let reused = try await factory.create(url: url, tenantId: "tenant", documentId: "reused", token: .string("token"), client: client, nonce: "nonce-reused", epoch: "E")
                events.append(.array([.string("initial"), .array(try await factory.initialMessages(reused)), .array(try await factory.initialSignals(reused))]))
                try await factory.dispose(reused)
                events += try await factory.takeEvents(reused)
                try await Task.sleep(for: .milliseconds(2100))
                let evicted = try await factory.create(url: url, tenantId: "tenant", documentId: "evicted", token: .string("token"), client: client, nonce: "nonce-evicted", epoch: "E")
                events.append(.array([.string("initial"), .array(try await factory.initialMessages(evicted)), .array(try await factory.initialSignals(evicted))]))
                try await factory.dispose(evicted)
                events += try await factory.takeEvents(evicted)
                output["events"] = .array(events)
            } catch let error as OdspNetworkError {
                output["errorType"] = .string(JSString(error.errorType))
                output["canRetry"] = .bool(error.canRetry)
                if let status = error.statusCode { output["statusCode"] = .number(Double(status)) }
            }
            try await factory.close()
            FileHandle.standardOutput.write(Data((JSON.stringify(.object(output)) + "\n").utf8))
            continue
        }
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
