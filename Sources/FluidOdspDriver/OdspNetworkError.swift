import FluidJS
import Foundation

/// odsp-doclib-utils/src/odspErrorUtils.ts.
public struct OdspNetworkError: Error, Sendable {
    public var errorType: String
    public var canRetry: Bool
    public var statusCode: Int?
    public var retryAfterMs: Double?
    public var claims: String?
    public var tenantId: String?
    public var serverEpoch: String?
    public var scenarioName: String?
    public var redirectLocation: String?
    public var redirectUrl: IOdspResolvedUrl?
    public var facetCodes: [String] = []
    public var odsp409Error = false
    public var repeatForTokenRefresh = false

    public init(_ errorType: String, canRetry: Bool, statusCode: Int? = nil) {
        self.errorType = errorType
        self.canRetry = canRetry
        self.statusCode = statusCode
    }
}

public func parseAuthErrorClaims(_ header: String?) throws -> String? {
    guard let header, !header.isEmpty else { return nil }
    var insufficient = false
    var claims: String?
    for section in header.components(separatedBy: ",") {
        let parts = section.components(separatedBy: "=")
        guard parts.count > 1 else { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        if key == "error", !insufficient {
            insufficient = try JSON.parse(parts[1].lowercased()).asString() == "insufficient_claims"
        }
        if key == "claims", claims == nil {
            let encoded = try JSON.parse(parts.dropFirst().joined(separator: "=")).asString().description
            guard let bytes = Data(base64Encoded: encoded) else { throw JSONDecodingError("invalid claims base64") }
            claims = String(decoding: bytes, as: UTF8.self)
        }
    }
    return insufficient ? claims : nil
}

public func parseAuthErrorTenant(_ header: String?) throws -> String? {
    guard let header, let bearer = header.range(of: "Bearer") else { return nil }
    for section in header[bearer.upperBound...].components(separatedBy: ",") {
        let parts = section.components(separatedBy: "=")
        if parts.count > 1, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "realm" {
            let realm = try JSON.parse(parts[1]).asString().description
            if !realm.isEmpty { return realm }
        }
    }
    return nil
}

public func createOdspNetworkError(status: Int, headers: [String: String] = [:], body: String = "") throws -> OdspNetworkError {
    let headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
    var facets: [String] = []
    var redirect: String?
    if !body.isEmpty {
        do {
            let root = try JSON.parse(body).asObject()
            if case .object(let service) = root["error"], case .string = service["message"] {
                if let code = service["code"], case .string = code {} else if service["code"] != nil { throw JSONDecodingError("invalid error code") }
                var node: JSONValue? = .object(service)
                while case .object(let fields) = node {
                    if case .string(let code) = fields["code"] { facets.insert(code.description, at: 0) }
                    node = fields["innerError"]
                }
                if case .string(let location) = service["@error.redirectLocation"] { redirect = location.description }
            }
        } catch is JSONDecodingError {
            // TS tryParseErrorResponse deliberately ignores invalid service JSON.
        }
    }
    let deepest = facets.first
    var error = OdspNetworkError("genericNetworkError", canRetry: true, statusCode: status)
    switch status {
    case 301, 302, 303, 307, 308:
        error.canRetry = false
        if let location = headers["location"] {
            error.errorType = "fileNotFoundOrAccessDeniedError"
            error.redirectLocation = location
        }
    case 400:
        error.canRetry = deepest == "fluidEpochNotProvided"
        if deepest == "fluidEpochNotProvided" { error.errorType = "usageError" }
        if deepest == "fluidInvalidSchema" { error.errorType = "fluidInvalidSchemaError" }
    case 401, 403:
        error.canRetry = false
        if deepest == "serviceReadOnly" {
            error.errorType = "serviceReadOnly"
            error.canRetry = true
        } else if deepest == "blockedIPAddress" || deepest == "conditionalAccessPolicyEnforced" {
            error.errorType = "blockedIPAddress"
        } else {
            error.errorType = "authorizationError"
            error.claims = try parseAuthErrorClaims(headers["www-authenticate"])
            error.tenantId = try parseAuthErrorTenant(headers["www-authenticate"])
        }
    case 404:
        error.errorType = "fileNotFoundOrAccessDeniedError"
        error.canRetry = false
        error.redirectLocation = redirect
    case 406: error.errorType = "unsupportedClientProtocolVersion"
    case 409: error.errorType = "fileOverwrittenInStorage"
    case 410: error.errorType = "cannotCatchUp"
    case 412: error.canRetry = false
    case 413: error.errorType = "snapshotTooBig"
    case 414: error.errorType = "invalidFileNameError"
    case 423 where deepest == "resourceLocked" || deepest == "resourceCheckedOut": error.errorType = "fileIsLocked"
    case 501: error.errorType = "fluidNotEnabled"
    case 507: error.errorType = "outOfStorageError"
    case 712: error.errorType = "incorrectServerResponse"
    case 500, 423: break
    default:
        if let raw = headers["retry-after"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = trimmed.isEmpty ? 0 : Double(trimmed), !seconds.isNaN {
                error.errorType = "throttlingError"
                error.retryAfterMs = seconds * 1000
            }
        }
    }
    if [406, 409, 410, 413, 414, 501, 507, 712].contains(status) || error.errorType == "fileIsLocked" { error.canRetry = false }
    error.facetCodes = facets
    error.serverEpoch = headers["x-fluid-epoch"]
    return error
}
