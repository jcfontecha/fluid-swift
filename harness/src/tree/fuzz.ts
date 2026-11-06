import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { run } from './oracle.js';
import { generate } from './scenario.js';

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
console.log(`Tree TS self-check: ${count} seeds, algebra format 5 + structure; gated individual-edit wire formats 3/4/5`);
