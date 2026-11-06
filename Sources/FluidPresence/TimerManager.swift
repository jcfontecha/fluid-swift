/// Ports presence-runtime/src/utils/timerManager.ts: a wrapper around `setTimeout` that tracks
/// whether the timeout has expired.
public final class TimerManager {
  private let clock: any PresenceClock
  private var timeoutId: Int?
  private var _startTime: Double = 0
  private var _delay: Double = 0
  private var expired = true

  public init(clock: any PresenceClock) {
    self.clock = clock
  }

  public var startTime: Double {
    _startTime
  }

  public var delay: Double {
    _delay
  }

  public func hasExpired() -> Bool {
    expired
  }

  /// First cancels any old timeout.
  public func setTimeout(_ callback: @escaping () throws -> Void, delay: Double) {
    clearTimeout()
    _startTime = clock.now()
    _delay = delay
    expired = false
    timeoutId = clock.setTimeout(
      { [weak self] in
        // The callback marks the timer expired before running. As in TS, the stored timeout ID is
        // not reset when a timer fires, only by `clearTimeout`.
        self?.expired = true
        try callback()
      }, delay: delay)
  }

  /// Cancels a stored timeout, forgets it and marks the timer expired. Does nothing, and leaves
  /// `hasExpired` unchanged, when no timeout was ever stored.
  public func clearTimeout() {
    if let timeoutId {
      clock.clearTimeout(timeoutId)
      self.timeoutId = nil
      expired = true
    }
  }

  /// When the timer will fire: 0 if it has expired, otherwise `startTime + delay`.
  public var expireTime: Double {
    hasExpired() ? 0 : startTime + delay
  }
}
