import FluidDriverDefinitions
import FluidJS
import FluidSocketIO
import Foundation

/// Native error carrier for driver-base/src/documentDeltaConnection.ts. Status classification
/// follows routerlicious-driver/src/errorUtils.ts; opaque service error payloads are retained.
public struct DriverError: Error, Sendable, CustomStringConvertible {
    public let scenario: String
    public let payload: JSONValue
    public let canRetry: Bool
    public let errorType: String
    public let statusCode: Int?
    public let retryAfterSeconds: Double?
    public var description: String { "\(scenario): \(JSON.stringify(payload))" }
    public init(_ scenario: String, _ payload: JSONValue, canRetry: Bool = true) {
        self.scenario = scenario
        self.payload = payload
        var code: Int?
        var retry: Double?
        var internalCode: JSONValue?
        if case .object(let fields) = payload {
            if case .number(let number) = fields["code"] { code = Int(exactly: number) }
            if case .number(let milliseconds) = fields["retryAfterMs"] {
                retry = milliseconds / 1000
            }
            internalCode = fields["internalErrorCode"]
        }
        statusCode = code
        var retryable = canRetry
        var type = "genericNetworkError"
        if canRetry, let code {
            switch code {
            case 401, 403:
                type = "authorizationError"
                retryable = false
            case 404:
                type = "fileNotFoundOrAccessDeniedError"
                retryable = false
            case 429, 500, 502: retryable = true
            case 503 where internalCode == .string("ClusterDraining"):
                type = "clusterDrainingError"
                retryable = true
                retry = retry ?? 660
            default: retryable = retry != nil
            }
        }
        self.canRetry = retryable
        errorType = type
        retryAfterSeconds = retry
    }
}
