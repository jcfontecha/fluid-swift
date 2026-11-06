// Diagnostic only: exercises every farm operation against native Swift but does
// not replace fuzz.ts's separate, mandatory tagged structural comparison.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { mkdirSync, writeFileSync } from 'node:fs';
import { z } from 'zod';
import { run, type Scenario } from './oracle.js';
import { generate } from './scenario.js';
const count = Number(process.argv.find(arg => arg.startsWith('--seeds='))?.slice(8) ?? 1000);
assert(Number.isSafeInteger(count) && count > 0);
const root = resolve(import.meta.dirname, '../../..');
execFileSync('swift', ['build', '--scratch-path', '.build/t1', '--product', 'FluidTreePeer', '-c', 'release'], { cwd: root, stdio: 'inherit' });
const bin = execFileSync('swift', ['build', '--scratch-path', '.build/t1', '--show-bin-path', '-c', 'release'], { cwd: root, encoding: 'utf8' }).trim();
const child = spawn(resolve(bin, 'FluidTreePeer'), ['--wire-only'], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
const schema = z.array(z.array(z.string()));
let scenario: Scenario | undefined;
let seed = 0;
let row = -1;
let expected: string[][] = [];
let actual: string[][] = [];
try {
    for (; seed < count; seed++) {
        scenario = generate(seed);
        expected = run(scenario).map(record => {
            assert(record.length === 2 || record.length === 4, 'unexpected oracle comparison row');
            if (record.length === 4) return record;
            const bytes = record[0];
            assert(bytes !== undefined);
            return [bytes];
        });
        child.stdin.write(JSON.stringify(scenario) + '\n');
        let timer: NodeJS.Timeout | undefined;
        const response = await Promise.race([
            lines.next(),
            new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('T1 native peer timed out')), 30000); }),
        ]).finally(() => clearTimeout(timer));
        assert(!response.done, 'T1 native peer exited');
        actual = schema.parse(JSON.parse(response.value));
        assert.equal(actual.length, expected.length, `row count seed ${seed}`);
        row = expected.findIndex((record, index) => JSON.stringify(record) !== JSON.stringify(actual[index]));
        if (row !== -1) assert.deepEqual(actual[row], expected[row], `native wire seed ${seed}, row ${row}`);
        if ((seed + 1) % 100 === 0) console.log(`Native wire diagnostic: ${seed + 1} seeds passed`);
    }
    console.log(`Native wire diagnostic: ${count} seeds, every generated edit/algebra operation; structural certification still required.`);
} catch (error) {
    const directory = resolve(root, 'harness/traces/tree/native-wire');
    mkdirSync(directory, { recursive: true });
    writeFileSync(resolve(directory, `${seed}.json`), JSON.stringify({ seed, row, scenario, expected: expected[row], actual: actual[row], error: String(error) }, null, 2));
    throw error;
} finally {
    child.kill();
}
