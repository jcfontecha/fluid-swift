import { writeFileSync } from 'node:fs';
import { RangeMap } from '../../node_modules/@fluidframework/tree/lib/util/rangeMap.js';
import { Random } from '../random.js';
function structure(value: unknown): unknown {
    if (value === undefined) return ['undefined'];
    if (value === null || typeof value !== 'object') return value;
    if (Array.isArray(value)) return ['array', value.map(structure)];
    return ['object', Object.entries(value).map(([key, item]) => [key, structure(item)])];
}
const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const random = new Random(seed);
    const map = new RangeMap<number, number>((key, offset) => key + offset, (a, b) => a - b, (value, offset) => value + offset);
    const initial = structure(map);
    const setup = Array.from({ length: 60 }, () => ({ start: random.int(300), count: 1 + random.int(12), value: random.int(1000) }));
    for (const { start, count, value } of setup) map.set(start, count, value);
    const clone = map.clone();
    const operations = Array.from({ length: 40 }, () => ({ start: random.int(300), count: 1 + random.int(15), value: random.int(1000), remove: random.int(3) === 0 }));
    const results: (number | null)[] = [];
    for (const { start, count, value, remove } of operations) {
        if (remove) results.push(clone.delete(start, count));
        else {
            clone.set(start, count, value);
            results.push(null);
        }
    }
    const queries = Array.from({ length: 30 }, () => ({ start: random.int(300), count: 1 + random.int(15) }));
    const output = queries.map(({ start, count }) => {
        const first = clone.getFirst(start, count);
        return [first.value ?? null, first.length];
    });
    return { initial, setup, operations, results, queries, output, original: structure(map), changed: structure(clone) };
});
writeFileSync('../Tests/FluidTreeTests/Fixtures/range-map.json', JSON.stringify(fixtures));
