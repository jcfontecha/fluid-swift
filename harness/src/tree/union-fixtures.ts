import { writeFileSync } from 'node:fs';
import { BTree } from '@tylerbu/sorted-btree-es6';
import { union } from '@tylerbu/sorted-btree-es6/extended/union';
import { Random } from '../random.js';
function structure(value: unknown): unknown {
    if (value === undefined) return ['undefined'];
    if (value === null || typeof value !== 'object') return value;
    if (Array.isArray(value)) return ['array', value.map(structure)];
    return ['object', Object.entries(value).map(([key, item]) => [key, structure(item)])];
}
const compare = (a: number, b: number) => a - b;
const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const random = new Random(seed);
    const maxNodeSize = seed % 2 === 0 ? 32 : 4;
    const size = 1 + random.int(180);
    const leftKeys = Array.from({ length: size }, (_, i) => i * 3).filter(() => random.int(4) !== 0);
    const rightKeys = Array.from({ length: size }, (_, i) => i * 2 + (seed % 4) * 90).filter(() => random.int(4) !== 0);
    const left = new BTree(leftKeys.map(key => [key, key + 1]), compare, maxNodeSize);
    const same = seed % 10 === 0;
    const cloneRight = !same && seed % 7 === 0;
    const right = same ? left : cloneRight ? left.clone() : new BTree(rightKeys.map(key => [key, key * 2 + 1]), compare, maxNodeSize);
    const merged = union<BTree<number, number>, number, number>(left, right, (_key, a, b) => a + b);
    return { maxNodeSize, leftKeys, rightKeys, same, cloneRight, left: structure(left), right: structure(right), result: structure(merged), entries: merged.toArray() };
});
writeFileSync('../Tests/FluidTreeTests/Fixtures/btree-union.json', JSON.stringify(fixtures));
