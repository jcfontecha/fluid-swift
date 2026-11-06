import Foundation

/// odsp-driver-definitions/src/tokenFetch.ts. Empty custom authorization is intentionally retained.
public enum TokenResponse: Sendable {
    case token(String)
    case response(token: String, authorizationHeader: String? = nil, fromCache: Bool? = nil)
    case null

    public var token: String? {
        switch self {
        case .token(let token), .response(let token, _, _): return token
        case .null: return nil
        }
    }

    public var fromCache: Bool? {
        if case .response(_, _, let cached) = self { return cached }
        return nil
    }

    public var authorizationHeader: String? {
        if case .response(_, let header?, _) = self { return header }
        return token.map { "Bearer " + $0 }
    }
}

public struct TokenFetchOptions: Sendable {
    public var siteUrl = ""
    public var driveId: String?
    public var itemId: String?
    public var previousError: OdspNetworkError?
    public var refresh = false
    public var claims: String?
    public var tenantId: String?
    public var requestURL: String?
    public var method: String?
    public init() {}
}

nonisolated(nonsending) public func getWithRetryForTokenRefresh<T>(_ get: (TokenFetchOptions) async throws -> T) async throws -> T {
    do { return try await get(TokenFetchOptions()) }
    catch let error as OdspNetworkError {
        guard ["authorizationError", "incorrectServerResponse", "fetchTokenError"].contains(error.errorType) || error.repeatForTokenRefresh else { throw error }
        var options = TokenFetchOptions()
        options.refresh = true
        options.previousError = error
        if error.errorType == "authorizationError" {
            options.claims = error.claims
            options.tenantId = error.tenantId
        }
        return try await get(options)
    }
}

/// retryUtils.ts. Generic 429 and 5xx are deliberately not retried here.
public func runWithRetry<T>(sleep: (Double) async throws -> Void, random: () -> Double, checkDisposed: () throws -> Void = {}, call: () async throws -> T) async throws -> T {
    var delay = 1000.0
    for attempt in 1...5 {
        try checkDisposed()
        do { return try await call() }
        catch var error as OdspNetworkError {
            guard error.canRetry, error.odsp409Error || error.errorType == "serviceReadOnly" else { throw error }
            if attempt == 5 {
                error.canRetry = false
                throw error
            }
            delay = error.retryAfterMs ?? delay
            try await sleep(floor(delay))
            delay += delay / 4 * (1 + random())
        }
    }
    preconditionFailure("bounded retry must return or throw")
}
