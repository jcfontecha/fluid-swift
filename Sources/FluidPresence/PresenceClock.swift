/// The JS globals the presence runtime reads: `Date.now()`, `setTimeout` / `clearTimeout` and
/// `Math.random()`. ARCHITECTURE.md §2: the runtime is synchronous, so a host supplies the clock
/// and runs timer callbacks on the container's executor.
public protocol PresenceClock: AnyObject {
  /// `Date.now()`: epoch milliseconds.
  func now() -> Double

  /// `Math.random()`.
  func random() -> Double

  /// `setTimeout(callback, delay)`. Returns the handle for `clearTimeout`.
  func setTimeout(_ callback: @escaping () throws -> Void, delay: Double) -> Int

  /// `clearTimeout(handle)`.
  func clearTimeout(_ handle: Int)
}
