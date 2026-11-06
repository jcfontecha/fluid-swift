import FluidJS
import Foundation

public struct OdspRequest: Sendable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data
    public init(url: String, method: String = "POST", headers: [String: String] = [:], body: Data = Data()) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
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

/// odspUtils.ts fetchHelper I/O edge. Wire JSON always uses FluidJS.
public func fetchHelper(_ request: OdspRequest, timeoutMs: Double = 30000) async throws -> OdspResponse {
    guard let url = URL(string: request.url) else { throw JSONDecodingError("invalid request URL") }
    var wire = URLRequest(url: url)
    if request.headers.keys.contains(where: { $0.lowercased() == "authorization" }) {
        wire.cachePolicy = .reloadIgnoringLocalCacheData
    }
    wire.httpMethod = request.method
    wire.httpBody = request.body
    wire.allHTTPHeaderFields = request.headers
    if request.headers.keys.contains(where: { $0.lowercased() == "authorization" }) {
        // WHATWG fetch's authenticated-request cache mode emits these under Node's oracle transport.
        if wire.value(forHTTPHeaderField: "Pragma") == nil { wire.setValue("no-cache", forHTTPHeaderField: "Pragma") }
        if wire.value(forHTTPHeaderField: "Cache-Control") == nil { wire.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
    }
    wire.timeoutInterval = timeoutMs / 1000
    let data: Data
    let response: URLResponse
    do { (data, response) = try await URLSession.shared.data(for: wire) }
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

/// Per-file HTTP coordinator; epoch state is applied before returning to its serial owner.
public final class OdspNetwork {
    private let resolvedUrl: IOdspResolvedUrl
    private var requestNumber = 1
    public let epochTracker: EpochTracker
    public var boundary: () -> String = { UUID().uuidString.lowercased() }
    public var send: (OdspRequest) async throws -> OdspResponse
    public var tokenFetcher: (TokenFetchOptions) async throws -> TokenResponse
    public init(resolvedUrl: IOdspResolvedUrl, epochTracker: EpochTracker, tokenFetcher: @escaping (TokenFetchOptions) async throws -> TokenResponse, send: @escaping (OdspRequest) async throws -> OdspResponse = { try await fetchHelper($0) }) {
        self.resolvedUrl = resolvedUrl
        self.epochTracker = epochTracker
        self.tokenFetcher = tokenFetcher
        self.send = send
    }
    public func authorized(url: String, method: String = "POST", make: (String, String) throws -> OdspRequest) async throws -> OdspResponse {
        try await getWithRetryForTokenRefresh { options in
            var options = options
            options.requestURL = url
            options.method = method
            options.siteUrl = self.resolvedUrl.siteUrl
            options.driveId = self.resolvedUrl.driveId
            options.itemId = self.resolvedUrl.itemId
            let response: TokenResponse
            do { response = try await self.tokenFetcher(options) }
            catch { throw OdspNetworkError("fetchTokenError", canRetry: false) }
            guard let auth = response.authorizationHeader else { throw OdspNetworkError("fetchTokenError", canRetry: false) }
            let request = try make(auth, self.boundary())
            return try await self.fetch(request)
        }
    }
    public func fetch(_ request: OdspRequest) async throws -> OdspResponse {
        var request = request
        let stats = "driverId=NORMALIZED, RequestNumber=\(requestNumber), driverVersion=3.11.0, isSummarizer=false"
        requestNumber += 1
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
        let response = try await send(request)
        if !(200..<300).contains(response.status) {
            throw try epochTracker.classify(status: response.status, headers: response.headers, body: String(decoding: response.body, as: UTF8.self))
        }
        if let epoch = response.headers["x-fluid-epoch"] { try epochTracker.validateEpoch(epoch) }
        return response
    }
}

/// odspDeltaStorageService.ts.
public final class OdspDeltaStorageService {
    private let deltaFeedUrl: String
    private let network: OdspNetwork
    public init(deltaFeedUrl: String, network: OdspNetwork) {
        self.deltaFeedUrl = deltaFeedUrl
        self.network = network
    }
    public func buildUrl(from: Int, to: Int) -> String {
        deltaFeedUrl + "?ump=1&filter=" + encodeOdspComponent("sequenceNumber ge \(from) and sequenceNumber le \(to - 1)")
    }
    public func get(from: Int, to: Int) async throws -> [JSONValue] {
        let url = buildUrl(from: from, to: to)
        let response = try await network.authorized(url: url) { auth, boundary in
            OdspRequest(url: url, headers: ["Content-Type": "multipart/form-data;boundary=" + boundary], body: odspMultipart(boundary: boundary, lines: ["Authorization: " + auth, "X-HTTP-Method-Override: GET"]))
        }
        let values = try response.json().member("value").asArray()
        if let first = values.first, try first.asObject()["op"] != nil { return try values.map { try $0.member("op") } }
        return values
    }
}

/// vroom.ts.
public func fetchJoinSession(resolved: IOdspResolvedUrl, network: OdspNetwork, requestSocketToken: Bool = true, displayName: String? = nil, disableJoinSessionRefresh: Bool = false) async throws -> JSONValue {
    let url = try getApiRoot(resolved.siteUrl) + "/drives/" + resolved.driveId + "/items/" + resolved.itemId + "/opStream/joinSession?ump=1"
    let response = try await network.authorized(url: url) { auth, boundary in
        var lines = ["Authorization: " + auth, "X-HTTP-Method-Override: POST", "Content-Type: application/json"]
        if !disableJoinSessionRefresh { lines.append("Prefer: FluidRemoveCheckAccess") }
        lines.append("Prefer: Return-Sensitivity-Labels")
        var body = JSObject<JSONValue>()
        if requestSocketToken { body["requestSocketToken"] = .bool(true) }
        if let displayName, !displayName.isEmpty { body["displayName"] = .string(JSString(displayName)) }
        return OdspRequest(url: url, headers: ["Content-Type": "multipart/form-data;boundary=" + boundary], body: odspMultipart(boundary: boundary, lines: lines, payload: body.isEmpty ? nil : JSON.stringify(.object(body))))
    }
    var body = try response.json().asObject()
    if case .string(let tenant) = body["runtimeTenantId"], tenant != "", body["tenantId"] == nil || body["tenantId"] == .string("") { body["tenantId"] = .string(tenant) }
    return .object(body)
}
