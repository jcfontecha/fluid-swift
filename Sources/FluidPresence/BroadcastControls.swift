/// Ports presence-definitions/src/broadcastControlsTypes.ts `BroadcastControlSettings`.
public struct BroadcastControlSettings {
  public var allowableUpdateLatencyMs: Double?

  public init(allowableUpdateLatencyMs: Double? = nil) {
    self.allowableUpdateLatencyMs = allowableUpdateLatencyMs
  }
}

/// Ports `ForcedRefreshControl` of presence-runtime/src/utils/broadcastControls.ts. The constructor
/// ignores the forced-refresh setting.
public class ForcedRefreshControl {
  public private(set) var forcedRefreshIntervalMs: Double?

  /// Setting `undefined` or a value below 10 stores `undefined`. A value of 10 or more is stored
  /// and then throws `Forced Refresh feature is not implemented`.
  public func setForcedRefreshIntervalMs(_ value: Double?) throws {
    guard let value else {
      forcedRefreshIntervalMs = nil
      return
    }
    forcedRefreshIntervalMs = value >= 10 ? value : nil
    if value >= 10 {
      throw PresenceError.failed("Forced Refresh feature is not implemented")
    }
  }
}

/// Ports `OptionalBroadcastControl`: `allowableUpdateLatencyMs` may be `undefined`.
public final class OptionalBroadcastControl: ForcedRefreshControl {
  public var allowableUpdateLatencyMs: Double?

  public init(settings: BroadcastControlSettings?) {
    allowableUpdateLatencyMs = settings?.allowableUpdateLatencyMs
  }
}

/// Ports `RequiredBroadcastControl`: always defined. Setting `undefined` restores the default.
public final class RequiredBroadcastControl: ForcedRefreshControl {
  private let defaultAllowableUpdateLatencyMs: Double
  public private(set) var allowableUpdateLatencyMs: Double

  public init(defaultAllowableUpdateLatencyMs: Double) {
    self.defaultAllowableUpdateLatencyMs = defaultAllowableUpdateLatencyMs
    allowableUpdateLatencyMs = defaultAllowableUpdateLatencyMs
  }

  public func setAllowableUpdateLatencyMs(_ value: Double?) {
    allowableUpdateLatencyMs = value ?? defaultAllowableUpdateLatencyMs
  }
}
