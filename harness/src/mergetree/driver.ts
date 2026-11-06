import { z } from 'zod';
import { mkdirSync, writeFileSync } from 'node:fs';
import { isDeepStrictEqual } from 'node:util';
import { Random } from '../random.js';
import { Peer } from './transport.js';
import { stateSchema, type Edit } from './protocol.js';
const args = process.argv.slice(2);
const option = (k: string, d: string) => args[args.indexOf(k) + 1] ?? d;
const kinds = args.includes('--peers') ? option('--peers', 'ts,ts').split(',') : ['ts', 'ts'];
const range = args.includes('--seeds') ? option('--seeds', '0..499') : '0..499';
const [first, last] = range.split('..').map(Number);
if (first === undefined)
    throw Error('seed required');
if (args.includes('--obliterate')) {
    if (kinds.some(kind => kind !== 'ts'))
        throw Error('obliterate is an upstream TS-only mode; Swift is not implemented');
    const { prepareObliterate } = await import('./prepare-obliterate.js');
    prepareObliterate();
    const { runObliterateFarm } = await import('./obliterate-farm.js');
    await runObliterateFarm(first, last ?? first);
    process.exit(0);
}
const trace: unknown[] = [];
const peers = kinds.map((k, i) => new Peer(k, trace, i));
function equal(a: unknown, b: unknown, label: string) {
    if (!isDeepStrictEqual(a, b))
        throw Error(`${label}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`);
}
async function both(method: string, params: unknown, origin = 0) {
    const results = [];
    for (const peer of peers)
        results.push(await peer.call(method, params));
    for (const r of results.slice(1))
        equal(results[0], r, method);
    return results[origin];
}
try {
    for (let seed = first; seed <= (last ?? first); seed++) {
        trace.length = 0;
        trace.push({ seed, peers: kinds });
        const random = new Random(seed);
        await both('reset', {});
        const ids = ['A', 'B', 'C'];
        const cursors = [0, 0, 0];
        const clientSeq = [0, 0, 0];
        const refs = [0, 0, 0];
        const log: {
            clientId: string;
            clientSequenceNumber: number;
            referenceSequenceNumber: number;
            sequenceNumber: number;
            minimumSequenceNumber: number;
            type: 'op';
            contents: unknown;
        }[] = [];
        const queue: typeof log = [];
        for (const client of ids)
            await both('create', { client });
        const deliver = async (i: number, count: number) => {
            while (count-- > 0 && cursors[i]! < log.length) {
                const message = log[cursors[i]!]!;
                await both('process', { client: ids[i], message });
                cursors[i] = cursors[i]! + 1;
            }
        };
        const sequence = () => {
            const m = queue.shift();
            if (m) {
                refs[ids.indexOf(m.clientId)] = m.referenceSequenceNumber;
                m.sequenceNumber = log.length + 1;
                m.minimumSequenceNumber = Math.min(...refs);
                log.push(m);
            }
        };
        const checkpoint = async () => {
            while (queue.length)
                sequence();
            for (let i = 0; i < 3; i++)
                await deliver(i, log.length);
            let baseline: unknown;
            for (const client of ids) {
                const s = stateSchema.parse(await both('state', { client }));
                const visible = { text: s.text, length: s.length };
                if (baseline)
                    equal(baseline, visible, 'convergence');
                else
                    baseline = visible;
                await both('snapshot', { client, version: 'v1' });
                await both('snapshot', { client, version: 'legacy' });
                if (seed % 2 === 0) {
                    const summary = await both('snapshot', { client, version: 'v1' });
                    await both('load', { client, summary });
                    await both('state', { client });
                }
            }
            for (const client of ids)
                await both('minSeq', { client, seq: log.length });
            refs.fill(log.length);
            for (const client of ids) {
                const summary = await both('snapshot', { client, version: seed % 2 === 0 ? 'v1' : 'legacy' });
                await both('load', { client, summary });
                await both('state', { client });
            }
        };
        for (let step = 0; step < 120; step++) {
            if (step % 30 === 29) {
                await checkpoint();
                continue;
            }
            if (step % 30 === 20) {
                for (let index = 0; index < ids.length; index++) {
                    await deliver(index, log.length);
                    const client = ids[index]!;
                    const regenerated = z.array(z.unknown()).parse(await both('reconnect', { client }));
                    equal(regenerated, await both('reconnect', { client }), 'repeated reconnect');
                    const messages = queue.filter(message => message.clientId === client);
                    equal(regenerated.length, messages.length, 'reconnect pending count');
                    for (const [offset, message] of messages.entries()) {
                        message.contents = regenerated[offset];
                        message.referenceSequenceNumber = cursors[index]!;
                    }
                    await both('state', { client });
                }
                continue;
            }
            const i = random.int(3);
            const client = ids[i]!;
            const choice = random.int(10);
            if (choice === 0) {
                sequence();
                continue;
            }
            if (choice === 1) {
                await deliver(i, 1 + random.int(5));
                continue;
            }
            const s = stateSchema.parse(await both('state', { client }));
            const n = s.length;
            let edit: Edit;
            if (n === 0 || choice < 5)
                edit = { kind: 'insert', pos: random.int(n + 1), text: random.pick(['a', 'bc', '😀', '\ud800', '\udfff', '\n', 'é']) };
            else if (choice === 5)
                edit = { kind: 'marker', pos: random.int(n + 1) };
            else if (choice === 6)
                edit = { kind: 'reference', pos: random.int(n), id: `r${step}`, refType: random.pick([64, 128, 256]) };
            else {
                const start = random.int(n);
                edit = { kind: choice === 7 ? 'remove' : 'annotate', start, end: start + 1 + random.int(n - start), props: { color: random.pick(['red', 'blue', null]) } };
            }
            const contents = await both('edit', { client, edit }, i % peers.length);
            if (contents !== null && step % 17 === 16) {
                await both('rollback', { client });
                await both('state', { client });
            }
            else if (contents !== null)
                queue.push({ clientId: client, clientSequenceNumber: ++clientSeq[i]!, referenceSequenceNumber: cursors[i]!, sequenceNumber: 0, minimumSequenceNumber: 0, type: 'op', contents });
        }
        await checkpoint();
        if ((seed - first + 1) % 50 === 0)
            console.log(`merge-tree ${kinds.join(',')} passed ${seed - first + 1} seeds`);
    }
}
catch (error) {
    mkdirSync('traces', { recursive: true });
    writeFileSync('traces/mergetree-failure.jsonl', trace.map(x => JSON.stringify(x)).join('\n'));
    throw error;
}
finally {
    for (const peer of peers)
        peer.close();
}
