// Deterministic replacement for the JS globals the real presence runtime reads:
// Date.now, setTimeout / clearTimeout and Math.random. The Swift mirror is
// `ManualPresenceClock` (Sources/FluidPresence/Testing); both fire timers in the same order.

interface PendingTimer {
  at: number;
  id: number;
  callback: () => void;
}

export class FakeClock {
  private current: number;
  private nextId = 1;
  private readonly timers = new Map<number, PendingTimer>();
  private randomIndex = 0;

  // Invoked when a timer callback throws; the throw does not stop later timers.
  public onError: (error: unknown) => void = () => {};

  public constructor(
    start: number,
    private readonly randoms: readonly number[],
  ) {
    this.current = start;
  }

  public now(): number {
    return this.current;
  }

  public random(): number {
    const value = this.randoms[this.randomIndex % this.randoms.length];
    this.randomIndex += 1;
    if (value === undefined) {
      throw new Error("No randoms configured");
    }
    return value;
  }

  public setTimeout(callback: () => void, delay: number): number {
    const id = this.nextId;
    this.nextId += 1;
    this.timers.set(id, { at: this.current + Math.max(0, delay), id, callback });
    return id;
  }

  public clearTimeout(id: number): void {
    this.timers.delete(id);
  }

  // Fires every timer due at or before now + ms, earliest first (ties by creation
  // order), with now set to each timer's due time while it runs.
  public advance(ms: number): void {
    const target = this.current + ms;
    for (;;) {
      let next: PendingTimer | undefined;
      for (const timer of this.timers.values()) {
        if (timer.at > target) {
          continue;
        }
        if (next === undefined || timer.at < next.at || (timer.at === next.at && timer.id < next.id)) {
          next = timer;
        }
      }
      if (next === undefined) {
        break;
      }
      this.timers.delete(next.id);
      this.current = Math.max(this.current, next.at);
      try {
        next.callback();
      } catch (error) {
        this.onError(error);
      }
    }
    this.current = target;
  }

  // Runs `body` with the JS globals pointing at this clock.
  public withInstalled<T>(body: () => T): T {
    const realNow = Date.now;
    const realSetTimeout = globalThis.setTimeout;
    const realClearTimeout = globalThis.clearTimeout;
    const realRandom = Math.random;
    Date.now = () => this.now();
    Math.random = () => this.random();
    globalThis.setTimeout = ((callback: () => void, delay: number) =>
      this.setTimeout(callback, delay)) as unknown as typeof globalThis.setTimeout;
    globalThis.clearTimeout = ((id: number) => {
      this.clearTimeout(id);
    }) as unknown as typeof globalThis.clearTimeout;
    try {
      return body();
    } finally {
      Date.now = realNow;
      Math.random = realRandom;
      globalThis.setTimeout = realSetTimeout;
      globalThis.clearTimeout = realClearTimeout;
    }
  }
}
