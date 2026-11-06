import FluidDriverBase
import FluidDriverDefinitions
import FluidJS
import Foundation

/// REST transport shared by the routerlicious storage services (restWrapper.ts).
struct RestClient: Sendable {
    let endpoint: String
    let document: String
    let tokens: any ITokenProvider
    public func get(_ path: String, storage: Bool = true) async throws -> JSONValue {
        try await request(path, storage: storage)
    }
    public func post(_ path: String, body: JSONValue) async throws -> JSONValue {
        try await request(path, body: body)
    }
    private func request(_ path: String, storage: Bool = true, body: JSONValue? = nil) async throws -> JSONValue {
        guard let url = URL(string: endpoint + path) else {
            throw JSONDecodingError("invalid REST URL")
        }
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = Data(JSON.stringify(body).utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let tokenResponse =
            try await storage
            ? tokens.fetchStorageToken(
                tenantId: "tinylicious", documentId: document, refresh: false)
            : tokens.fetchOrdererToken(
                tenantId: "tinylicious", documentId: document, refresh: false)
        let jwt = tokenResponse.jwt
        request.setValue(
            storage
                ? "Basic " + Data("tinylicious:\(jwt)".utf8).base64EncodedString() : "Basic " + jwt,
            forHTTPHeaderField: "Authorization")
        request.setValue("3.11.0", forHTTPHeaderField: "x-driver-version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
        else {
            throw DriverError(
                "REST \(path)", .string(JSString(String(decoding: data, as: UTF8.self))))
        }
        return try JSON.parse(String(decoding: data, as: UTF8.self))
    }
}
