import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { mkdirSync, writeFileSync } from 'node:fs';
import { Random } from '../random.js';
import { run, uuids, type Scenario } from './oracle.js';
const root = resolve(import.meta.dirname, '../../..');
function generate(seed: number): Scenario {
    const r = new Random(seed);
    const s: Scenario = { seed, uuids: uuids(seed), detached: seed % 4 === 0, pending: seed % 2 === 0, commands: [] };
    const add = (kind: string, value: Record<string, unknown> = {}) => s.commands.push({ kind, value });
    add('outbound', { ops: [
            { type: 'component', contents: { address: 'a', contents: { type: 'op', content: { n: seed } } } },
            { type: 'attach', contents: { id: 'b', snapshot: { entries: [] }, type: 'test' } },
            { type: 'alias', contents: { internalId: 'b', alias: 'root' } },
            { type: 'blobAttach' }, { type: 'rejoin' },
            { type: 'GC', contents: { type: 'Sweep', deletedNodeIds: [] } },
            { type: 'schema', contents: { version: 1, refSeq: 0, runtime: { explicitSchemaControl: true } } },
            { type: 'idAllocation', contents: { sessionId: '10000000-0000-4000-8000-000000000001' } },
        ] });
    const batch = ['a', 'a', 'b', 'a'].map((address, index) => ({ type: 'component', contents: { address, contents: { type: 'op', content: index } } }));
    add('batch', { ops: batch, grouped: true });
    add('batch', { ops: batch, grouped: false });
    for (const version of ['1.9.0', '2.0.0', '2.39.9', '2.40.0', '3.10.0', '3.10.1', '3.12.0', '3.11.0-beta', 'v2.40.0', ' 2.40.0 ', '2.40.0+build', 'bad'])
        add('compat', { version, pending: r.int(2) === 0 });
    for (const type of ['attach', 'alias', 'GC', 'schema', 'idAllocation', 'rejoin', 'chunkedOp', 'groupedBatch', 'future']) {
        add('route', { type, contents: [{ id: 'a', snapshot: { entries: [] }, type: 'test', internalId: 'a', alias: 'root' }], local: r.int(2) === 0 });
    }
    for (let i = 0; i < 12; i++) {
        add('route', { type: 'component', contents: Array.from({ length: 1 + r.int(5) }, () => ({ address: r.pick(['a', 'b', 'deleted', 'missing']), contents: { type: r.pick(['op', 'other']), content: { n: r.int(100), text: 'lone\ud800' } } })), local: r.int(2) === 0 });
        const address = r.pick(['container', '', 'a', 'b', 'missing', 'deleted', '/ext/presence/', '/ext/presence/room', '/other']);
        add('signal', { ...(address === 'container' ? {} : { address }), payload: { x: r.int(100) }, ...(r.int(2) === 0 ? { target: 'peer' } : {}), local: r.int(2) === 0, client: r.pick(['peer', 'self', 'server']) });
    }
    for (let i = 0; i < 4; i++) {
        add('create', { bytes: [r.int(256), 0, 255, r.int(4)] });
        if (s.pending && !s.detached) {
            add('attach', { index: i });
            if (i === 0) {
                add('restore');
                add('resume');
            }
            add('ack', { index: i === 0 ? 1 : i + 1, local: false });
        }
    }
    if (s.detached) {
        const entries = s.commands.filter(c => c.kind === 'create').map(c => {
            const bytes = c.value.bytes as number[];
            const pseudo = 's' + Buffer.from(bytes).toString('base64');
            return [pseudo, 'real' + pseudo];
        });
        add('patch', { entries });
    }
    else if (s.pending) {
        add('time', { now: 8000 });
        add('resubmit', { index: 2 });
        add('resume');
    }
    add('read', { id: s.uuids[0] });
    add('read', { id: 'missing' });
    add('reloadSummary');
    add('remote', { localId: 'remote', blobId: 'storage' });
    add('remote', { localId: 'duplicate', blobId: 'storage' });
    add('sweep', { routes: ['/_blobs/remote'] });
    add('sweep', { routes: ['/_blobs/duplicate'] });
    if (s.pending && !s.detached) {
        add('defer', { enabled: true });
        add('create', { bytes: [4, 255] });
        add('attach', { index: 4 });
        add('remote', { localId: s.uuids[4], blobId: 'authoritative' });
        add('finish');
        add('create', { bytes: [5, 255] });
        add('attach', { index: 5 });
        add('abort', { index: 5 });
        add('finish');
    }
    return s;
}
const self = process.argv.includes('--self');
const count = Number(process.argv.find(a => a.startsWith('--seeds='))?.split('=')[1] ?? 1000);
if (!self)
    execFileSync('swift', ['build', '--scratch-path', '.build/h4', '--product', 'FluidRoutingPeer', '-c', 'release'], { cwd: root, stdio: 'inherit' });
const child = self ? undefined : spawn(resolve(root, '.build/h4/release/FluidRoutingPeer'), [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = child ? createInterface({ input: child.stdout })[Symbol.asyncIterator]() : undefined;
let seed = 0;
try {
    for (; seed < count; seed++) {
        const scenario = generate(seed);
        const expected = await run(scenario);
        const observed: { destination: string; value: unknown }[] = JSON.parse(expected);
        assert.equal(observed.filter(row => row.destination === 'batchBegin').length, 2, 'real TS batch begin');
        assert.equal(observed.filter(row => row.destination === 'batchEnd').length, 2, 'real TS batch end');
        assert.equal(observed.filter(row => row.destination === 'op').length, 8, 'real TS logical op events');
        for (const row of observed) {
            if (row.destination === 'error') assert(['route', 'signal', 'compat', 'read'].includes(String(row.value)), `unexpected oracle error: ${String(row.value)}`);
        }
        let actual: string;
        if (self)
            actual = await run(scenario);
        else {
            assert(child && lines);
            child.stdin.write(JSON.stringify(scenario) + '\n');
            let timer: NodeJS.Timeout | undefined;
            const line = await Promise.race([lines.next(), new Promise<never>((_, reject) => { timer = setTimeout(() => reject(Error('peer timeout')), 30000); })]).finally(() => clearTimeout(timer));
            assert(!line.done, 'peer exited');
            actual = line.value;
        }
        if (actual !== expected) {
            mkdirSync(resolve(root, 'harness/traces/routing'), { recursive: true });
            writeFileSync(resolve(root, `harness/traces/routing/${seed}.json`), JSON.stringify({ scenario, expected: JSON.parse(expected), actual: JSON.parse(actual) }, null, 2));
        }
        assert.equal(actual, expected, `seed ${seed}`);
    }
    console.log(`Routing ${self ? 'TS self-check' : 'Swift differential'}: ${count} seeds passed`);
}
finally {
    child?.kill();
}
