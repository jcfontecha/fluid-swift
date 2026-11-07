import FluidDriverUtils
import FluidJS

/// driver-base validateMessages (strict): a non-contiguous batch is dropped entirely.
func validateMessages(_ messages: inout [JSONValue], from: Int) throws {
    guard let lastMessage = messages.last else { return }
    let last = try lastMessage.member("sequenceNumber").asInt()
    if last + 1 != from + messages.count {
        messages.removeAll()
    }
}

extension OdspNetworkError: RetryableError {
    public var retryAfterSeconds: Double? { retryAfterMs.map { $0 / 1000 } }
    public var endpointReached: Bool { statusCode != nil }
}
