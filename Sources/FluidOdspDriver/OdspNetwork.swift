import FluidJS
import Foundation
import Synchronization

/// epochTracker.ts FetchType.
public enum OdspFetchType: String, Sendable {
    case blob, createBlob, createFile, joinSession, ops, test, snapshotTree, treesLatest
    case uploadSummary, push, versions, renameFile
}

public struct OdspRequest: Sendable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data
    public var timeoutMs: Double?
    public var fetchType: OdspFetchType
    /// `fetchReason` appended to X-RequestStats (epochTracker.ts formatClientCorrelationId).
    public var fetchReason: String?
    public init(url: String, method: String = "POST", headers: [String: String] = [:], body: Data = Data(), timeoutMs: Double? = 30000, fetchType: OdspFetchType = .test, fetchReason: String? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeoutMs = timeoutMs
        self.fetchType = fetchType
        self.fetchReason = fetchReason
    }
}

public struct OdspResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
    public func json() throws -> JSONValue { try JSON.parse(String(decoding: body, as: UTF8.self)) }
}

private let odspHTTPSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    // Foundation's six-connection default must not supersede EpochTracker's 24-request limiter.
    configuration.httpMaximumConnectionsPerHost = 64
    configuration.timeoutIntervalForResource = Double.greatestFiniteMagnitude
    return URLSession(configuration: configuration)
}()

/// odspUtils.ts fetchHelper I/O edge. Wire JSON always uses FluidJS.
public func fetchHelper(_ request: OdspRequest) async throws -> OdspResponse {
    guard let url = URL(string: request.url) else { throw JSONDecodingError("invalid request URL") }
    var wire = URLRequest(url: url)
    let names = Set(request.headers.keys.map { $0.lowercased() })
    if names.contains("authorization") {
        wire.cachePolicy = .reloadIgnoringLocalCacheData
    }
    wire.httpMethod = request.method
    if request.method != "GET" || !request.body.isEmpty { wire.httpBody = request.body }
    wire.allHTTPHeaderFields = request.headers
    // WHATWG fetch (Node's oracle transport): a conditional header switches the cache mode to
    // no-store, which appends these unless already present.
    if !names.isDisjoint(with: ["if-modified-since", "if-none-match", "if-unmodified-since", "if-match", "if-range"]) {
        wire.cachePolicy = .reloadIgnoringLocalCacheData
        if wire.value(forHTTPHeaderField: "Pragma") == nil { wire.setValue("no-cache", forHTTPHeaderField: "Pragma") }
        if wire.value(forHTTPHeaderField: "Cache-Control") == nil { wire.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
    }
    wire.timeoutInterval = request.timeoutMs.map { $0 / 1000 } ?? Double.greatestFiniteMagnitude
    let data: Data
    let response: URLResponse
    do { (data, response) = try await odspHTTPSession.data(for: wire) }
    catch {
        let timeout = (error as? URLError)?.code == .timedOut
        throw OdspNetworkError(timeout ? "fetchTimeout" : "fetchFailure", canRetry: true)
    }
    guard let http = response as? HTTPURLResponse else { throw OdspNetworkError("incorrectServerResponse", canRetry: false, statusCode: 712) }
    var headers: [String: String] = [:]
    // Avoid Foundation's untyped allHeaderFields; these are the protocol-relevant response headers.
    for key in ["content-type", "x-fluid-epoch", "retry-after", "www-authenticate", "location", "disablebrowsercachingofusercontent"] {
        headers[key] = http.value(forHTTPHeaderField: key)
    }
    return OdspResponse(status: http.statusCode, headers: headers, body: data)
}

public func odspMultipart(boundary: String, lines: [String], payload: String? = nil) -> Data {
    let tail = payload.map { "\r\n" + $0 + "\r\n" } ?? ""
    return Data(((["--" + boundary] + lines + ["_post: 1"]).joined(separator: "\r\n") + "\r\n" + tail + "\r\n--" + boundary + "--").utf8)
}

/// driver-definitions IFileEntry: the file an epoch tracker and its cache entries belong to
/// (`docId` is the hashed document ID). Create-new and rename replace its resolved URL.
public final class OdspFileEntry: Sendable {
    private let state: Mutex<IOdspResolvedUrl>
    public init(_ resolvedUrl: IOdspResolvedUrl) {
        state = Mutex(resolvedUrl)
    }
    public var resolvedUrl: IOdspResolvedUrl {
        state.withLock { $0 }
    }
    public var docId: String {
        resolvedUrl.hashedDocumentId
    }
    public func update(_ resolvedUrl: IOdspResolvedUrl) {
        state.withLock { $0 = resolvedUrl }
    }
}

/// Per-file HTTP coordinator: the shared EpochTracker plus the file entry it tracks.
public final class OdspNetwork: Sendable {
    public let fileEntry: OdspFileEntry
    private let requestNumber = Mutex(1)
    public let epochTracker: EpochTracker
    public let boundary: @Sendable () -> String
    public let send: @Sendable (OdspRequest) async throws -> OdspResponse
    public let tokenFetcher: TokenFetcher
    public init(fileEntry: OdspFileEntry, epochTracker: EpochTracker, tokenFetcher: @escaping TokenFetcher, boundary: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }, send: @escaping @Sendable (OdspRequest) async throws -> OdspResponse = { try await fetchHelper($0) }) {
        self.fileEntry = fileEntry
        self.epochTracker = epochTracker
        self.tokenFetcher = tokenFetcher
        self.boundary = boundary
        self.send = send
    }
    public convenience init(resolvedUrl: IOdspResolvedUrl, epochTracker: EpochTracker, tokenFetcher: @escaping TokenFetcher, boundary: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }, send: @escaping @Sendable (OdspRequest) async throws -> OdspResponse = { try await fetchHelper($0) }) {
        self.init(fileEntry: OdspFileEntry(resolvedUrl), epochTracker: epochTracker, tokenFetcher: tokenFetcher, boundary: boundary, send: send)
    }
    public var resolvedUrl: IOdspResolvedUrl {
        fileEntry.resolvedUrl
    }
    public func updateResolvedUrl(_ resolvedUrl: IOdspResolvedUrl) {
        fileEntry.update(resolvedUrl)
    }
    nonisolated(nonsending) public func authorized(url: String, method: String = "POST", make: (String, String) throws -> OdspRequest, fetchResponse: ((OdspRequest) async throws -> OdspResponse)? = nil) async throws -> OdspResponse {
        try await getWithRetryForTokenRefresh { options in
            try await self.authorizedOnce(options, url: url, method: method, make: make, fetchResponse: fetchResponse)
        }
    }
    /// One token fetch and one request: callers that own the token-refresh retry (TS
    /// `getWithRetryForTokenRefresh` around joinSession) use this directly.
    nonisolated(nonsending) public func authorizedOnce(_ options: TokenFetchOptions, url: String, method: String = "POST", make: (String, String) throws -> OdspRequest, fetchResponse: ((OdspRequest) async throws -> OdspResponse)? = nil) async throws -> OdspResponse {
        let auth = try await authorizationHeader(options, url: url, method: method)
        let request = try make(auth, boundary())
        if let fetchResponse { return try await fetchResponse(request) }
        return try await fetch(request)
    }
    /// odspUtils.ts toInstrumentedOdspStorageTokenFetcher: the host fetcher receives the file's URL parts.
    nonisolated(nonsending) public func authorizationHeader(_ options: TokenFetchOptions, url: String, method: String) async throws -> String {
        var options = options
        options.requestURL = url
        options.method = method
        let resolved = resolvedUrl
        options.siteUrl = resolved.siteUrl
        options.driveId = resolved.driveId
        options.itemId = resolved.itemId
        let response: TokenResponse
        do { response = try await tokenFetcher(options) }
        catch { throw OdspNetworkError("fetchTokenError", canRetry: false) }
        guard let auth = response.authorizationHeader else { throw OdspNetworkError("fetchTokenError", canRetry: false) }
        return auth
    }
    nonisolated(nonsending) public func fetchWithoutEpoch(_ request: OdspRequest) async throws -> OdspResponse {
        let response = try await send(request)
        guard (200..<300).contains(response.status) else {
            throw try createOdspNetworkError(status: response.status, headers: response.headers, body: String(decoding: response.body, as: UTF8.self))
        }
        return response
    }
    nonisolated(nonsending) public func fetch(_ request: OdspRequest) async throws -> OdspResponse {
        try await epochTracker.fetch(type: request.fetchType) { try await self.fetchOnce(request) }
    }
    nonisolated(nonsending) private func fetchOnce(_ request: OdspRequest) async throws -> OdspResponse {
        var request = request
        let number = requestNumber.withLock { number in
            let current = number
            number += 1
            return current
        }
        var stats = "driverId=NORMALIZED, RequestNumber=\(number), driverVersion=3.11.0, isSummarizer=\(epochTracker.clientIsSummarizer)"
        if let reason = request.fetchReason { stats += ", fetchReason=" + reason }
        var protocolLines = ["X-RequestStats: " + stats]
        if let epoch = epochTracker.fluidEpoch { protocolLines.append("x-fluid-epoch: " + epoch) }
        if request.headers["Content-Type"]?.hasPrefix("multipart/") == true {
            let text = String(decoding: request.body, as: UTF8.self)
            guard let range = text.range(of: "\r\n"), text.hasPrefix("--") else { throw JSONDecodingError("0x21e") }
            request.body = Data((String(text[..<range.upperBound]) + protocolLines.joined(separator: "\r\n") + "\r\n" + text[range.upperBound...]).utf8)
        } else {
            request.headers["X-RequestStats"] = stats
            if let epoch = epochTracker.fluidEpoch { request.headers["x-fluid-epoch"] = epoch }
        }
        await epochTracker.rateLimiter.acquire()
        let response: OdspResponse
        do { response = try await send(request) }
        catch {
            await epochTracker.rateLimiter.release()
            throw error
        }
        await epochTracker.rateLimiter.release()
        if !(200..<300).contains(response.status) {
            var error = try epochTracker.classify(status: response.status, headers: response.headers, body: String(decoding: response.body, as: UTF8.self))
            if error.errorType == "fileNotFoundOrAccessDeniedError", let location = error.redirectLocation {
                error.redirectUrl = try patchOdspResolvedUrl(resolvedUrl, redirectLocation: location)
                error.errorType = "locationRedirection"
                try await epochTracker.removeEntries()
            }
            throw error
        }
        if let epoch = response.headers["x-fluid-epoch"] { try epochTracker.validateEpoch(epoch) }
        return response
    }
}

/// odspDeltaStorageService.ts OdspDeltaStorageService.
public final class OdspDeltaStorageService: Sendable {
    private let deltaFeedUrl: String
    private let network: OdspNetwork
    public init(deltaFeedUrl: String, network: OdspNetwork) {
        self.deltaFeedUrl = deltaFeedUrl
        self.network = network
    }
    public func buildUrl(from: Int, to: Int) -> String {
        deltaFeedUrl + "?ump=1&filter=" + encodeOdspComponent("sequenceNumber ge \(from) and sequenceNumber le \(to - 1)")
    }
    /// Messages in [from, to); TS returns `{ messages, partialResult: false }`.
    public func get(from: Int, to: Int, fetchReason: String? = nil) async throws -> [JSONValue] {
        let url = buildUrl(from: from, to: to)
        let response = try await network.authorized(url: url) { auth, boundary in
            OdspRequest(url: url, headers: ["Content-Type": "multipart/form-data;boundary=" + boundary], body: odspMultipart(boundary: boundary, lines: ["Authorization: " + auth, "X-HTTP-Method-Override: GET"]), fetchType: .ops, fetchReason: fetchReason)
        }
        let values = try response.json().member("value").asArray()
        if let first = values.first, try first.asObject()["op"] != nil { return try values.map { try $0.member("op") } }
        return values
    }
}

/// vroom.ts. The caller owns the token-refresh retry (OdspDelayLoadedDeltaStream), so this makes one
/// token fetch; the request itself runs under retryUtils.ts runWithRetry.
nonisolated(nonsending) public func fetchJoinSession(resolved: IOdspResolvedUrl, network: OdspNetwork, options: TokenFetchOptions = TokenFetchOptions(), requestSocketToken: Bool = true, displayName: String? = nil, disableJoinSessionRefresh: Bool = false) async throws -> JSONValue {
    let url = try getApiRoot(resolved.siteUrl) + "/drives/" + resolved.driveId + "/items/" + resolved.itemId + "/opStream/joinSession?ump=1"
    let response = try await network.authorizedOnce(options, url: url, make: { auth, boundary in
        var lines = ["Authorization: " + auth, "X-HTTP-Method-Override: POST", "Content-Type: application/json"]
        if !disableJoinSessionRefresh { lines.append("Prefer: FluidRemoveCheckAccess") }
        lines.append("Prefer: Return-Sensitivity-Labels")
        var body = JSObject<JSONValue>()
        if requestSocketToken { body["requestSocketToken"] = .bool(true) }
        if let displayName, !displayName.isEmpty { body["displayName"] = .string(JSString(displayName)) }
        return OdspRequest(url: url, headers: ["Content-Type": "multipart/form-data;boundary=" + boundary], body: odspMultipart(boundary: boundary, lines: lines, payload: body.isEmpty ? nil : JSON.stringify(.object(body))), fetchType: .joinSession)
    }, fetchResponse: { request in
        try await runWithRetry(sleep: { try await Task.sleep(for: .milliseconds($0)) }, random: { Double.random(in: 0..<1) }) {
            try await network.fetch(request)
        }
    })
    var body = try response.json().asObject()
    if case .string(let tenant) = body["runtimeTenantId"], tenant != "", body["tenantId"] == nil || body["tenantId"] == .string("") { body["tenantId"] = .string(tenant) }
    return .object(body)
}
