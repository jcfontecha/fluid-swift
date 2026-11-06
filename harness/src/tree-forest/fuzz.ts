import assert from 'node:assert/strict';
import {execFileSync, spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {mkdirSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {z} from 'zod';
import {decodeBatch, decodeForest, decodeJob, decodeJobs, decodeSchema, extra, forestJobs, run, specializations} from './oracle.js';
import {generate} from './scenario.js';
const count = Number(process.argv.find(a => a.startsWith('--seeds='))?.slice(8) ?? 1000);
assert(Number.isSafeInteger(count) && count > 0);
const self = process.argv.includes('--self');
const root = resolve(import.meta.dirname, '../../..');
if (!self) execFileSync('swift', ['build', '--scratch-path', '.build/t2', '--product', 'FluidTreeForestPeer'], {cwd: root, stdio: 'inherit'});
const bin = self ? undefined : execFileSync('swift', ['build', '--scratch-path', '.build/t2', '--show-bin-path'], {cwd: root, encoding: 'utf8'}).trim();
const child = bin === undefined ? undefined : spawn(resolve(bin, 'FluidTreeForestPeer'), [], {stdio: ['pipe', 'pipe', 'inherit']});
const lines = child === undefined ? undefined : createInterface({input: child.stdout})[Symbol.asyncIterator]();
try {
    for (let seed = 0; seed < count; seed++) {
        const scenario = generate(seed);
        const specialized = specializations(seed);
        const expected = [...run(scenario), ...extra(scenario), ...specialized.map(decodeBatch)];
        let actual: string[];
        if (self) actual = [...run(scenario), ...extra(scenario), ...specialized.map(decodeBatch)];
        else {
            assert(child && lines);
            const decode = decodeJobs(expected);
            child.stdin.write(JSON.stringify({...scenario, decode, specialized, forestDecode: forestJobs(expected), schemaDecode: [expected[24], expected[25]]}) + '\n');
            let timer: NodeJS.Timeout | undefined;
            const response = await Promise.race([
                lines.next(),
                new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('T2 peer timeout')), 30000); }),
            ]).finally(() => clearTimeout(timer));
            assert(!response.done, 'T2 peer exited');
            actual = z.array(z.string()).parse(JSON.parse(response.value));
            const decoded = actual.splice(expected.length);
            assert.deepEqual(decoded, [...decodeJobs(expected).map(decodeJob), ...forestJobs(expected).map(decodeForest), decodeSchema(expected[24] ?? "null", 1), decodeSchema(expected[25] ?? "null", 2)], `TS to Swift seed ${seed}`);
        }
        try {
            assert.deepEqual(actual, expected, `T2 seed ${seed}`);
            assert.deepEqual(forestJobs(actual).map(decodeForest), forestJobs(expected).map(decodeForest), `Swift forest to TS seed ${seed}`);
            assert.equal(decodeSchema(actual[24] ?? "null", 1), expected[24]);
            assert.equal(decodeSchema(actual[25] ?? "null", 2), expected[25]);
            assert.deepEqual(decodeJobs(actual).map(decodeJob), decodeJobs(expected).map(decodeJob), `Swift to TS seed ${seed}`);
        }
        catch (error) {
            mkdirSync('traces/tree-forest', {recursive: true});
            writeFileSync(`traces/tree-forest/${seed}.json`, JSON.stringify({scenario, expected, actual}, null, 2));
            throw error;
        }
        if ((seed + 1) % 100 === 0) console.log(`T2 ${self ? 'self' : 'native'} ${seed + 1} seeds`);
    }
} finally { child?.kill(); }
