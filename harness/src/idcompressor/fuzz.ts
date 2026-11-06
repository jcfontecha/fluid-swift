import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { mkdirSync, writeFileSync } from 'node:fs';
import { Random } from '../random.js';
import { Oracle, run, type Scenario, type Command } from './oracle.js';
import { z } from 'zod';
import { snapshots } from './fixtures.js';
const root = resolve(import.meta.dirname, '../../..');
const rangeResult = z.object({ value: z.object({ sessionId: z.string(), ids: z.object({ firstGenCount: z.number(), count: z.number(), requestedClusterSize: z.number(), localIdRanges: z.array(z.tuple([z.number(), z.number()])) }).optional() }) });
function generate(seed: number): Scenario {
    const r = new Random(seed);
    const sessions = Array.from({ length: 2 + r.int(4) }, (_, i) => `${(i + 1).toString(16).padStart(8, '0')}-abcd-4fff-bfff-fffffffffff0`);
    const s: Scenario = { sessions, version: seed % 2 === 0 ? 2 : 3, commands: [] };
    const model = new Oracle(s);
    const pending: z.infer<typeof rangeResult>['value'][][] = sessions.map(() => []);
    const counts = sessions.map(() => 0);
    const generated: {
        client: number;
        id: number;
        stable: string;
        gen: number;
    }[] = [];
    function add(c: Command): unknown {
        s.commands.push(c);
        return model.apply(c);
    }
    function take(client: number) {
        const value = rangeResult.parse(add({ kind: 'take', client })).value;
        if (value.ids) pending[client]?.push(value);
    }
    function finalize(client: number) {
        const range = pending[client]?.shift();
        if (!range) return;
        for (let target = 0; target < sessions.length; target++) add({ kind: 'finalize', client: target, range });
        for (const g of generated.filter(g => g.client === client && g.gen < (range.ids?.firstGenCount ?? 0) + (range.ids?.count ?? 0)).slice(-4)) {
            for (let target = 0; target < sessions.length; target++) {
                const a = model.clients[client];
                assert(a);
                const origin = sessions[client];
                assert(origin);
                // Probe only IDs covered by this sequenced range, not later pending IDs.
                const stable = g.stable;
                const id = a.normalizeToOpSpace(g.id as Parameters<typeof a.normalizeToOpSpace>[0]);
                if (id >= 0) {
                    add({ kind: 'query', client: target, id, origin, stable });
                    if (g.id < 0) add({ kind: 'query', client: target, id: g.id, origin, stable });
                }
            }
        }
    }
    for (let step = 0; step < 75; step++) {
        const client = r.int(sessions.length);
        const choice = r.int(10);
        if (choice < 5) {
            const count = r.pick([1, 2, 7, 32, 513]);
            const result = z.object({ value: z.array(z.tuple([z.number(), z.number(), z.string(), z.number()])) }).parse(add({ kind: 'generate', client, count }));
            for (const [id, , stable] of result.value) {
                counts[client] = (counts[client] ?? 0) + 1;
                generated.push({ client, id, stable, gen: counts[client] ?? 0 });
            }
        } else if (choice < 7) {
            take(client);
        } else if (choice < 9) {
            finalize(client);
        } else {
            add({ kind: 'capacity', client, size: r.pick([1, 2, 8, 512, 1048576]) });
            add({ kind: 'restore', client, local: true, newSession: sessions[client] ?? '', version: s.version });
        }
    }
    for (let client = 0; client < sessions.length; client++) take(client);
    while (pending.some(q => q.length > 0)) finalize(r.int(sessions.length));
    for (let client = 0; client < sessions.length; client++) {
        add({ kind: 'reset', client });
        add({ kind: 'take', client });
        add({ kind: 'restore', client, local: false, newSession: `${(client + 100).toString(16).padStart(8, '0')}-0000-4000-8000-000000000000`, version: 3 });
        add({ kind: 'generate', client, count: 2 });
    }
    for (const serialized of snapshots) {
        add({ kind: 'load', client: 0, serialized });
        add({ kind: 'generate', client: 0, count: serialized === snapshots[2] ? 2 : 5 });
        add({ kind: 'restore', client: 0, local: true, newSession: '', version: 2 });
    }
    return s;
}
const self = process.argv.includes('--self');
const count = Number(process.argv.find(a => a.startsWith('--seeds='))?.split('=')[1] ?? 1000);
if (!self) execFileSync('swift', ['build', '--scratch-path', '.build/h2', '--product', 'FluidIdCompressorPeer', '-c', 'release'], { cwd: root, stdio: 'inherit' });
const child = self ? undefined : spawn(resolve(root, '.build/h2/release/FluidIdCompressorPeer'), [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = child ? createInterface({ input: child.stdout })[Symbol.asyncIterator]() : undefined;
let seed = 0;
let scenario: Scenario | undefined;
try {
    for (; seed < count; seed++) {
        scenario = generate(seed);
        const expected = run(scenario);
        let actual: unknown;
        if (self) actual = run(scenario);
        else {
            assert(child && lines);
            child.stdin.write(JSON.stringify(scenario) + '\n');
            let timer: NodeJS.Timeout | undefined;
            const response = await Promise.race([lines.next(), new Promise<never>((_, reject) => {
                timer = setTimeout(() => reject(Error('H2 peer timeout')), 30000);
            })]).finally(() => clearTimeout(timer));
            assert(!response.done, 'H2 peer exited');
            assert.equal(response.value, JSON.stringify(expected), `wire bytes seed ${seed}`);
            actual = JSON.parse(response.value);
        }
        assert.deepEqual(actual, JSON.parse(JSON.stringify(expected)), `seed ${seed}`);
        if ((seed + 1) % 100 === 0) console.log(`${seed + 1} seeds passed`);
    }
    console.log(`${self ? 'TS self-check' : 'Swift differential'}: ${count} seeds passed`);
} catch (error) {
    mkdirSync(resolve(root, 'harness/traces/idcompressor'), { recursive: true });
    writeFileSync(resolve(root, `harness/traces/idcompressor/${seed}.json`), JSON.stringify({ seed, scenario, error: String(error) }, null, 2));
    throw error;
} finally {
    child?.kill();
}
