import FluidJS

/// Port of `LoggingError` (telemetry-utils/src/errorLogging.ts): an error whose `props` are the telemetry
/// properties logged with it.
public struct LoggingError: Error, CustomStringConvertible {
  public let message: String
  public let props: JSObject<JSONValue>
  public var description: String { message }

  public init(_ message: String, _ props: JSObject<JSONValue> = JSObject()) {
    self.message = message
    self.props = props
  }
}
