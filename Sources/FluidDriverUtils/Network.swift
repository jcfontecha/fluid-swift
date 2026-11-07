import FluidDriverBase
import FluidJS

/// driver-utils/network.ts: structural error properties shared by all drivers.
public protocol RetryableError: Error {
    var canRetry: Bool { get }
    var retryAfterSeconds: Double? { get }
    var endpointReached: Bool { get }
}

extension DriverError: RetryableError {
    public var endpointReached: Bool {
        (try? payload.asObject()["endpointReached"]) == .bool(true)
    }
}

/// driver-utils/network.ts GenericNetworkError / ThrottlingError property carrier.
public struct NetworkError: RetryableError, Sendable, CustomStringConvertible {
    public let description: String
    public let canRetry: Bool
    public let retryAfterSeconds: Double?
    public let endpointReached: Bool

    public init(_ message: String, canRetry: Bool, retryAfterSeconds: Double? = nil, endpointReached: Bool = false) {
        description = message
        self.canRetry = canRetry
        self.retryAfterSeconds = retryAfterSeconds
        self.endpointReached = endpointReached
    }
}

public func canRetryOnError(_ error: (any Error)?) -> Bool {
    (error as? any RetryableError)?.canRetry == true
}

public func getRetryDelayFromError(_ error: (any Error)?) -> Double? {
    (error as? any RetryableError)?.retryAfterSeconds.map { $0 * 1000 }
}
