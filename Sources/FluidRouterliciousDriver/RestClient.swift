import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Foundation

/// Ports restWrapper.ts RouterliciousStorageRestWrapper and RouterliciousOrdererRestWrapper: the
/// request URL is the base URL concatenated with the path, and every request carries
/// `x-driver-version` and the service's Authorization header.
public struct RestClient: Sendable {
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

    public init(service: Service, baseUrl: String, tenantId: String, documentId: String, tokens: any ITokenProvider) {
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

    private func request(_ path: String, body: JSONValue?) async throws -> JSONValue {
        guard let url = URL(string: baseUrl + path) else {
            throw JSONDecodingError("invalid REST URL")
        }
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = Data(JSON.stringify(body).utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("3.11.0", forHTTPHeaderField: "x-driver-version")
        request.setValue(try await authorization(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw JSONDecodingError("REST \(path): not an HTTP response")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(response.statusCode) else {
            var payload = JSObject<JSONValue>()
            payload["code"] = .number(Double(response.statusCode))
            payload["message"] = .string(JSString(text))
            throw DriverError("REST \(path)", .object(payload))
        }
        return try JSON.parse(text)
    }

    private func authorization() async throws -> String {
        switch service {
        case .storage:
            let jwt = try await tokens.fetchStorageToken(tenantId: tenantId, documentId: documentId, refresh: false).jwt
            return "Basic " + Data("\(tenantId):\(jwt)".utf8).base64EncodedString()
        case .orderer:
            let jwt = try await tokens.fetchOrdererToken(tenantId: tenantId, documentId: documentId, refresh: false).jwt
            return "Basic " + jwt
        }
    }
}
