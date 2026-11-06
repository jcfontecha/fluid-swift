import { writeFileSync } from 'node:fs';
import { BTree } from '@tylerbu/sorted-btree-es6';
import { Random } from '../random.js';
// Kept local: importing the modular oracle would prewarm the shared undefVals
// array before the first empty-tree observation.
function structure(value: unknown): unknown {
    if (value === undefined) return ['undefined'];
    if (value === null || typeof value !== 'object') return value;
    if (Array.isArray(value)) return ['array', value.map(structure)];
    return ['object', Object.entries(value).map(([key, item]) => [key, structure(item)])];
}
type Operation = { kind: 'set'; key: number; value: number; overwrite: boolean } | { kind: 'delete'; key: number } | { kind: 'deleteRange'; low: number; high: number } | { kind: 'map' };
const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const random = new Random(seed);
    const tree = new BTree<number, number>(undefined, (a, b) => a - b);
    const initial = structure(tree);
    const initialKeys = Array.from({ length: 110 }, (_, i) => i);
    for (let index = initialKeys.length - 1; index > 0; index--) {
        const swap = random.int(index + 1);
        const a = initialKeys[index];
        const b = initialKeys[swap];
        if (a === undefined || b === undefined) throw new Error('shuffle bounds');
        initialKeys[index] = b;
        initialKeys[swap] = a;
    }
    for (const key of initialKeys) tree.set(key, key * 3);
    let clone = tree.clone();
    const operations: Operation[] = [];
    const results: (number | boolean)[] = [];
    for (let index = 0; index < 80; index++) {
        const key = random.int(150);
        switch (random.int(4)) {
            case 0: {
                const overwrite = random.int(2) === 0;
                operations.push({ kind: 'set', key, value: index, overwrite });
                results.push(clone.set(key, index, overwrite));
                break;
            }
            case 1:
                operations.push({ kind: 'delete', key });
                results.push(clone.delete(key));
                break;
            case 2: {
                const high = key + random.int(12);
                operations.push({ kind: 'deleteRange', low: key, high });
                results.push(clone.deleteRange(key, high, true));
                break;
            }
            case 3:
                operations.push({ kind: 'map' });
                clone = clone.mapValues(value => value + 1);
                results.push(clone.size);
                break;
        }
    }
    return { initial, initialKeys, operations, results, original: structure(tree), changed: structure(clone), entries: clone.toArray() };
});
writeFileSync('../Tests/FluidTreeTests/Fixtures/btree.json', JSON.stringify(fixtures));
