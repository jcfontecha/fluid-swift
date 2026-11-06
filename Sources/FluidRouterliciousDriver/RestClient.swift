import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Foundation

/// Ports restWrapper.ts RouterliciousStorageRestWrapper and RouterliciousOrdererRestWrapper: the
/// request URL is the base URL concatenated with the path, and every request carries
/// `x-driver-version` and the service's Authorization header.
public actor RestClient {
    /// Which wrapper: storage authorizes with `Basic base64(tenantId:jwt)`, the orderer with `Basic jwt`.
    public enum Service: Sendable {
        case storage
        case orderer
    }

    let service: Service
    let baseUrl: String
    let tenantId: String
    let documentId: String
    let tokens: any ITokenProvider
    let useRestLess: Bool

    private var requestResolver: (@Sendable (String) async throws -> (String, String, Bool))?
    func setRequestResolver(_ resolver: @escaping @Sendable (String) async throws -> (String, String, Bool)) {
        requestResolver = resolver
    }
    private var token: ITokenResponse?
    private var retryCounts: [String: Int] = [:]

    func initializeToken(_ initial: ITokenResponse? = nil) async throws {
        if let initial { token = initial }
        else if token == nil { token = try await fetchToken(refresh: false) }
    }

    public init(service: Service, baseUrl: String, tenantId: String, documentId: String, tokens: any ITokenProvider, useRestLess: Bool = false) {
        self.useRestLess = useRestLess
        self.service = service
        self.baseUrl = baseUrl
        self.tenantId = tenantId
        self.documentId = documentId
        self.tokens = tokens
    }

    func get(_ path: String) async throws -> JSONValue {
        try await request(path, body: nil)
    }

    func post(_ path: String, body: JSONValue) async throws -> JSONValue {
        try await request(path, body: body)
    }

    private func request(_ path: String, body: JSONValue?, canRetry: Bool = true) async throws -> JSONValue {
        let requestBase: String
        let requestPath: String
        if let requestResolver {
            let (base, resolved, reset) = try await requestResolver(path)
            requestBase = base
            requestPath = resolved
            if reset { token = nil }
        } else {
            requestBase = baseUrl
            requestPath = path
        }
        guard let url = URL(string: requestBase + requestPath + (retryCounts[path].map { (path.contains("?") ? "&" : "?") + "retry=\($0)" } ?? "")) else {
            throw JSONDecodingError("invalid REST URL")
        }
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = Data(JSON.stringify(body).utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("3.11.0", forHTTPHeaderField: "x-driver-version")
        let auth = try await authorization()
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        if useRestLess {
            // URLSearchParams uses form encoding, not encodeURIComponent.
            func form(_ value: String) -> String {
                let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*-._")
                return value.addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(of: "%20", with: "+")
            }
            var fields = ["method=" + (body == nil ? "GET" : "POST"), "header=" + form("x-driver-version: 3.11.0"), "header=" + form("Authorization: " + auth)]
            if let body { fields.append("body=" + form(JSON.stringify(body))) }
            request.httpMethod = "POST"
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "x-driver-version")
            request.setValue("application/x-www-form-urlencoded;restless", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(fields.joined(separator: "&").utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw JSONDecodingError("REST \(path): not an HTTP response")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(response.statusCode) else {
            retryCounts[path, default: 0] += 1
            let fields = (try? JSON.parse(text).asObject()) ?? JSObject<JSONValue>()
            if response.statusCode == 401, canRetry {
                token = try await fetchToken(refresh: true)
                return try await self.request(path, body: body, canRetry: false)
            }
            if response.statusCode == 429, case .number(let seconds) = fields["retryAfter"], seconds > 0 {
                try await Task.sleep(for: .seconds(seconds))
                return try await self.request(path, body: body)
            }
            var payload = JSObject<JSONValue>()
            if case .number(let seconds) = fields["retryAfter"] { payload["retryAfterMs"] = .number(seconds * 1000) }
            payload["endpointReached"] = .bool(true)
            payload["code"] = .number(Double(response.statusCode))
            payload["message"] = .string(JSString(text))
            throw DriverError("REST \(path)", .object(payload))
        }
        retryCounts[path] = nil
        return try JSON.parse(text)
    }

    func getToken() async throws -> ITokenResponse {
        try await initializeToken()
        return token!
    }
    func setToken(_ value: ITokenResponse) { token = value }
    private func fetchToken(refresh: Bool) async throws -> ITokenResponse {
        switch service {
        case .storage:
            return try await tokens.fetchStorageToken(tenantId: tenantId, documentId: documentId, refresh: refresh)
        case .orderer:
            return try await tokens.fetchOrdererToken(tenantId: tenantId, documentId: documentId.isEmpty ? nil : documentId, refresh: refresh)
        }
    }
    private func authorization() async throws -> String {
        try await initializeToken()
        let jwt = token!.jwt
        switch service {
        case .storage: return "Basic " + Data("\(tenantId):\(jwt)".utf8).base64EncodedString()
        case .orderer: return "Basic " + jwt
        }
    }
}
