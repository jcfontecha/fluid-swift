import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { Oracle, structure } from './oracle.js';
import { generate } from './scenario.js';
import { runAxioms } from './axioms.js';
const count = Number(process.argv.find(arg => arg.startsWith('--seeds='))?.slice(8) ?? 1000);
assert(Number.isSafeInteger(count) && count > 0, '--seeds must be positive');
for (let seed = 0; seed < count; seed++) {
    const oracle = new Oracle();
    const scenario = generate(seed);
    const rebase = oracle.rebase.bind(oracle);
    oracle.rebase = (change, over, history) => {
        try { return rebase(change, over, history); }
        catch (error) {
            mkdirSync('traces/tree/axioms', { recursive: true });
            writeFileSync(`traces/tree/axioms/${seed}.json`, JSON.stringify({ scenario, change: structure(change), over: structure(over), history, stack: new Error().stack }, null, 2));
            throw error;
        }
    };
    try {
        runAxioms(oracle, scenario, scenario.edits.map(edit => oracle.build(edit)), () => {});
    } catch (error) {
        throw new Error(`axiom seed ${seed}`, { cause: error });
    }
    if ((seed + 1) % 100 === 0) console.log(`Axioms: ${seed + 1} seeds passed`);
}
