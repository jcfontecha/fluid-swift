import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { spawn, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { z } from 'zod';
import { run } from './oracle.js';
import { generate } from './scenario.js';

const count = Number(process.argv.find(arg => arg.startsWith('--seeds='))?.slice(8) ?? 1000);
assert(Number.isSafeInteger(count) && count > 0, '--seeds must be a positive integer');
const self = process.argv.includes('--self');
const root = resolve(import.meta.dirname, '../../..');
if (!self) execFileSync('swift', ['build', '--scratch-path', '.build/t1', '--product', 'FluidTreePeer', '-c', 'release'], { cwd: root, stdio: 'inherit' });
const bin = self ? undefined : execFileSync('swift', ['build', '--scratch-path', '.build/t1', '--show-bin-path', '-c', 'release'], { cwd: root, encoding: 'utf8' }).trim();
const child = bin === undefined ? undefined : spawn(resolve(bin, 'FluidTreePeer'), [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = child === undefined ? undefined : createInterface({ input: child.stdout })[Symbol.asyncIterator]();
const schema = z.array(z.array(z.string()));
try {
    for (let seed = 0; seed < count; seed++) {
        const scenario = generate(seed);
        let expected: string[][] = [];
        let actual: string[][] = [];
        let row = -1;
        try {
            expected = run(scenario);
            if (self) actual = run(scenario);
            else {
                assert(child !== undefined && lines !== undefined);
                child.stdin.write(JSON.stringify(scenario) + '\n');
                let timer: NodeJS.Timeout | undefined;
                const response = await Promise.race([
                    lines.next(),
                    new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('T1 peer timeout')), 30000); }),
                ]).finally(() => clearTimeout(timer));
                assert(!response.done, 'T1 native peer exited');
                actual = schema.parse(JSON.parse(response.value));
            }
            assert.equal(actual.length, expected.length, `row count seed ${seed}`);
            row = expected.findIndex((value, index) => JSON.stringify(value) !== JSON.stringify(actual[index]));
            assert.equal(row, -1, `tree ${self ? 'self' : 'native'} mismatch seed ${seed}, row ${row}`);
        } catch (error) {
            mkdirSync('traces/tree', { recursive: true });
            writeFileSync(`traces/tree/${seed}-records.json`, JSON.stringify({ expected, actual }));
            writeFileSync(`traces/tree/${seed}.json`, JSON.stringify({ scenario, row, expected: expected[row], actual: actual[row], error: String(error) }, null, 2));
            throw error;
        }
        if ((seed + 1) % 100 === 0) console.log(`Tree ${self ? 'TS self-check' : 'Swift differential'}: ${seed + 1} seeds passed`);
    }
    console.log(`Tree ${self ? 'TS self-check' : 'Swift differential'}: ${count} seeds, algebra format 5 + structure; gated individual-edit wire formats 3/4/5`);
} finally {
    child?.kill();
}
