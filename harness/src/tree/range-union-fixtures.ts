import { writeFileSync } from 'node:fs';
import { RangeMap } from '../../node_modules/@fluidframework/tree/lib/util/rangeMap.js';
import { Random } from '../random.js';
function structure(value: unknown): unknown {
    if (value === undefined) return ['undefined'];
    if (value === null || typeof value !== 'object') return value;
    if (Array.isArray(value)) return ['array', value.map(structure)];
    return ['object', Object.entries(value).map(([key, item]) => [key, structure(item)])];
}
const offset = (value: number, amount: number) => value + amount;
const subtract = (a: number, b: number) => a - b;
const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const random = new Random(seed);
    const first = new RangeMap(offset, subtract, offset);
    const second = new RangeMap(offset, subtract, offset);
    const operations = () => Array.from({ length: 40 }, () => ({ start: random.int(300), count: 1 + random.int(12), value: random.int(1000) }));
    const left = operations();
    const right = operations();
    for (const { start, count, value } of left) first.set(start, count, value);
    for (const { start, count, value } of right) second.set(start, count, value);
    const merged = RangeMap.union(first, second);
    return { left, right, first: structure(first), second: structure(second), result: structure(merged) };
});
writeFileSync('../Tests/FluidTreeTests/Fixtures/range-union.json', JSON.stringify(fixtures));
