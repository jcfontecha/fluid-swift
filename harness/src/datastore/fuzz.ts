import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { mkdirSync, writeFileSync } from 'node:fs';
import { run } from './oracle.js';
const root = resolve(import.meta.dirname, '../../..');
const self = process.argv.includes('--self');
const count = Number(process.argv.find(a => a.startsWith('--seeds='))?.split('=')[1] ?? 1000);
if (!self) execFileSync('swift', ['build', '--scratch-path', '.build/h5', '--product', 'FluidDatastorePeer'], { cwd: root, stdio: 'inherit' });
const child = self ? undefined : spawn(resolve(root, '.build/h5/debug/FluidDatastorePeer'), [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = child ? createInterface({ input: child.stdout })[Symbol.asyncIterator]() : undefined;
try {
    for (let seed = 0; seed < count; seed++) {
        const expected = await run({ seed });
        let actual: string;
        if (self) actual = await run({ seed });
        else {
            assert(child && lines);
            child.stdin.write(JSON.stringify({ seed }) + '\n');
            let timer: NodeJS.Timeout | undefined;
            const line = await Promise.race([lines.next(), new Promise<never>((_, reject) => {
                timer = setTimeout(() => reject(Error('datastore peer timeout')), 30000);
            })]).finally(() => clearTimeout(timer));
            assert(!line.done, 'peer exited');
            actual = line.value;
        }
        if (actual !== expected) {
            mkdirSync(resolve(root, 'harness/traces/datastore'), { recursive: true });
            writeFileSync(resolve(root, `harness/traces/datastore/${seed}.json`), JSON.stringify({ seed, expected: JSON.parse(expected), actual: JSON.parse(actual) }, null, 2));
        }
        assert.equal(actual, expected, `seed ${seed}`);
    }
    console.log(`Datastore ${self ? 'TS self-check' : 'Swift differential'}: ${count} seeds passed`);
} finally { child?.kill(); }
