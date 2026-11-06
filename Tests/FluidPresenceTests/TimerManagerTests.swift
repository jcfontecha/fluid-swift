import FluidPresence
import Testing

/// Ports presence-runtime/src/utils/test/timerManager.spec.ts.
@Suite("Presence/Utils:TimerManager")
struct TimerManagerTests {
  let clock = ManualPresenceClock(start: 1000)

  @Test("fires on time")
  func firesOnTime() {
    let timer = TimerManager(clock: clock)
    var fired = 0
    timer.setTimeout({ fired += 1 }, delay: 100)
    clock.advance(by: 99)
    #expect(fired == 0)
    #expect(!timer.hasExpired())
    clock.advance(by: 1)
    #expect(fired == 1)
    #expect(timer.hasExpired())
  }

  @Test("expire time is based on timeout")
  func expireTime() {
    let timer = TimerManager(clock: clock)
    #expect(timer.expireTime == 0)
    timer.setTimeout({}, delay: 100)
    #expect(timer.expireTime == 1100)
    clock.advance(by: 100)
    #expect(timer.expireTime == 0)
  }

  @Test("does not fire if cleared before timeout")
  func clearedBeforeTimeout() {
    let timer = TimerManager(clock: clock)
    var fired = 0
    timer.setTimeout({ fired += 1 }, delay: 100)
    timer.clearTimeout()
    clock.advance(by: 200)
    #expect(fired == 0)
    #expect(timer.hasExpired())
  }

  @Test("does not fire on old timeout when new timeout set")
  func replacedTimeout() {
    let timer = TimerManager(clock: clock)
    var old = 0
    var new = 0
    timer.setTimeout({ old += 1 }, delay: 100)
    clock.advance(by: 50)
    timer.setTimeout({ new += 1 }, delay: 100)
    clock.advance(by: 50)
    #expect(old == 0)
    #expect(new == 0)
    clock.advance(by: 50)
    #expect(old == 0)
    #expect(new == 1)
  }

  @Test("fires correctly on reuse")
  func reuse() {
    let timer = TimerManager(clock: clock)
    var fired = 0
    timer.setTimeout({ fired += 1 }, delay: 100)
    clock.advance(by: 100)
    timer.setTimeout({ fired += 1 }, delay: 100)
    clock.advance(by: 100)
    #expect(fired == 2)
  }

  @Test("multiple timers")
  func multipleTimers() {
    let first = TimerManager(clock: clock)
    let second = TimerManager(clock: clock)
    var order: [String] = []
    first.setTimeout({ order.append("first") }, delay: 200)
    second.setTimeout({ order.append("second") }, delay: 100)
    clock.advance(by: 200)
    #expect(order == ["second", "first"])
  }

  /// `clearTimeout` on a timer that already fired leaves it expired (the stored ID is not reset
  /// when a timer fires), and on a timer that never ran leaves `hasExpired` unchanged.
  @Test("clear on a timer that never ran does nothing")
  func clearNeverRan() {
    let timer = TimerManager(clock: clock)
    timer.clearTimeout()
    #expect(timer.hasExpired())
    #expect(timer.expireTime == 0)
  }
}
