import FluidJS

/// A deterministic `PresenceClock` for tests and the differential harness: the Swift mirror of
/// harness/src/presence/clock.ts. Time moves only through `advance(by:)`, which fires every timer
/// due at or before the target, earliest first (ties in creation order), with `now()` set to each
/// timer's due time while it runs.
public final class ManualPresenceClock: PresenceClock {
  private struct PendingTimer {
    let at: Double
    let id: Int
    let callback: () throws -> Void
  }

  private var current: Double
  private var nextId = 1
  private var timers: [Int: PendingTimer] = [:]
  private let randoms: [Double]
  private var randomIndex = 0

  /// Called when a timer callback throws; the throw does not stop later timers.
  public var onError: (any Error) -> Void = { _ in }

  public init(start: Double, randoms: [Double] = [0.5]) {
    current = start
    self.randoms = randoms
  }

  public func now() -> Double {
    current
  }

  /// `Math.random()`: the configured sequence, cycled.
  public func random() -> Double {
    guard !randoms.isEmpty else {
      return 0.5
    }
    let value = randoms[randomIndex % randoms.count]
    randomIndex += 1
    return value
  }

  public func setTimeout(_ callback: @escaping () throws -> Void, delay: Double) -> Int {
    let id = nextId
    nextId += 1
    timers[id] = PendingTimer(at: current + max(0, delay), id: id, callback: callback)
    return id
  }

  public func clearTimeout(_ handle: Int) {
    timers[handle] = nil
  }

  public func advance(by ms: Double) {
    let target = current + ms
    while true {
      var next: PendingTimer?
      for timer in timers.values where timer.at <= target {
        if let best = next {
          if timer.at < best.at || (timer.at == best.at && timer.id < best.id) {
            next = timer
          }
        } else {
          next = timer
        }
      }
      guard let due = next else {
        break
      }
      timers[due.id] = nil
      current = max(current, due.at)
      do {
        try due.callback()
      } catch {
        onError(error)
      }
    }
    current = target
  }
}
