import FluidJS

/// Ports signalTelemetryProcessing.ts wire tracking. Resetting telemetry never resets the broadcast counter.
public final class SignalTelemetryManager {
  private var broadcastSignalSequenceNumber = 0
  public init() {}
  public func applyTrackingToBroadcastSignalEnvelope(_ envelope: JSONValue) throws -> JSONValue {
    broadcastSignalSequenceNumber += 1
    var result = try envelope.asObject()
    result["clientBroadcastSignalSequenceNumber"] = number(broadcastSignalSequenceNumber)
    return .object(result)
  }
}
