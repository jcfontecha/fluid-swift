import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { Random } from '../random.js';
import { run, type Edit, type Scenario } from './oracle.js';

export function generate(seed: number): Scenario {
    const random = new Random(seed);
    const kinds: Edit['kind'][] = ['insert', 'remove', 'move', 'revive', 'set', 'clear', 'crossMove', 'nested'];
    return { seed, edits: [...kinds, ...Array.from({ length: 16 }, () => random.pick(kinds))].map(kind => ({ kind, index: random.int(5), count: 1 + random.int(3), destination: random.int(12), field: random.pick(['a', 'b']) })) };
}
const count = Number(process.argv.find(arg => arg.startsWith('--seeds='))?.slice(8) ?? 1000);
assert(Number.isSafeInteger(count) && count > 0, '--seeds must be a positive integer');
assert(process.argv.includes('--self'), 'Swift tree peer is not implemented; use --self for TS oracle checks only');
for (let seed = 0; seed < count; seed++) {
    const scenario = generate(seed);
    try {
        assert.deepEqual(run(scenario), run(scenario));
    } catch (error) {
        mkdirSync('traces/tree', { recursive: true });
        writeFileSync(`traces/tree/${seed}.json`, JSON.stringify(scenario, null, 2));
        throw error;
    }
}
console.log(`Tree TS self-check: ${count} seeds, modular formats 3/4/5`);
