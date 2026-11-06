import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { spawn, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { z } from 'zod';
import { run } from './world.js';
import { generate } from './scenario.js';

const count = Number(process.argv.find(arg => arg.startsWith('--seeds='))?.slice(8) ?? 300);
const first = Number(process.argv.find(arg => arg.startsWith('--first='))?.slice(8) ?? 0);
assert(Number.isSafeInteger(count) && count > 0, '--seeds must be a positive integer');
assert(Number.isSafeInteger(first) && first >= 0, '--first must be a nonnegative integer');
const self = process.argv.includes('--self');
const root = resolve(import.meta.dirname, '../../..');
const product = 'FluidTreeEditManagerPeer';
if (!self) execFileSync('swift', ['build', '--scratch-path', '.build/tree-em', '--product', product, '-c', 'release'], { cwd: root, stdio: 'inherit' });
const bin = self ? undefined : execFileSync('swift', ['build', '--scratch-path', '.build/tree-em', '--show-bin-path', '-c', 'release'], { cwd: root, encoding: 'utf8' }).trim();
const child = bin === undefined ? undefined : spawn(resolve(bin, product), [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = child === undefined ? undefined : createInterface({ input: child.stdout })[Symbol.asyncIterator]();
const schema = z.array(z.array(z.string()));
const totals = { rows: 0, summaries: 0, actions: 0, joins: 0 };
try {
    for (let seed = first; seed < first + count; seed++) {
        let expected: string[][] = [];
        let actual: string[][] = [];
        let row = -1;
        const generated = generate(seed);
        const scenario = generated.scenario;
        try {
            expected = generated.rows;
            if (self) actual = run(scenario);
            else {
                assert(child !== undefined && lines !== undefined);
                child.stdin.write(JSON.stringify(scenario) + '\n');
                let timer: NodeJS.Timeout | undefined;
                const response = await Promise.race([
                    lines.next(),
                    new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('T3 peer timeout')), 60000); }),
                ]).finally(() => clearTimeout(timer));
                assert(!response.done, 'T3 native peer exited');
                actual = schema.parse(JSON.parse(response.value));
            }
            row = expected.findIndex((value, index) => JSON.stringify(value) !== JSON.stringify(actual[index]));
            if (row === -1 && actual.length !== expected.length) row = Math.min(actual.length, expected.length);
            assert.equal(row, -1, `editmanager ${self ? 'self' : 'native'} mismatch seed ${seed}, row ${row}`);
        } catch (error) {
            mkdirSync('traces/tree-editmanager', { recursive: true });
            writeFileSync(`traces/tree-editmanager/${seed}-records.json`, JSON.stringify({ expected, actual }));
            writeFileSync(`traces/tree-editmanager/${seed}.json`, JSON.stringify({ scenario, row, expected: expected[row], actual: actual[row], error: String(error) }, null, 2));
            throw error;
        }
        totals.rows += expected.length;
        totals.summaries += expected.filter(r => r[0] === 'summary').length;
        totals.actions += scenario.actions.length;
        totals.joins += scenario.actions.filter(a => a.type === 'join').length;
        if ((seed - first + 1) % 50 === 0) console.log(`EditManager ${self ? 'TS self-check' : 'Swift differential'}: ${seed - first + 1} seeds passed`);
    }
    console.log(`EditManager ${self ? 'TS self-check' : 'Swift differential'}: ${count} seeds (from ${first}), ${totals.actions} actions, ${totals.rows} rows, ${totals.summaries} summary rows x5 formats, ${totals.joins} summary joins`);
} finally {
    child?.kill();
}
