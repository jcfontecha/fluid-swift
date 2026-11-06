// Mulberry32: all arithmetic is explicitly 32-bit, independent of host randomness.
export class Random {
  constructor(private seed: number) {}
  uint32(): number {
    let t = (this.seed = (this.seed + 0x6d2b79f5) | 0);
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return (t ^ (t >>> 14)) >>> 0;
  }
  int(max: number): number {
    return Math.floor((this.uint32() / 0x100000000) * max);
  }
  pick<T>(items: readonly T[]): T {
    const item = items[this.int(items.length)];
    if (item === undefined)
      throw new Error("Cannot choose from empty collection");
    return item;
  }
}
