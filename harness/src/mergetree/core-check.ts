// Focused insert/remove/annotation/reference/snapshot differential check. This does NOT replace the full farm.
import { isDeepStrictEqual } from 'node:util';
import { Random } from '../random.js';
import { Peer } from './transport.js';
import { stateSchema, type Edit } from './protocol.js';
const trace: unknown[] = [];
const peers = [new Peer('ts', trace), new Peer('swift', trace, 1)];
async function both(method: string, params: unknown) {
    const a = await peers[0]!.call(method, params);
    const b = await peers[1]!.call(method, params);
    if (!isDeepStrictEqual(a, b))
        throw Error(`${method}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`);
    return a;
}
try {
    for (let seed = 0; seed < 1000; seed++) {
        trace.length = 0;
        await both('reset', {});
        for (const client of ['A', 'B'])
            await both('create', { client });
        const random = new Random(seed);
        let sequence = 0;
        for (let round = 0; round < 8; round++) {
            const ref = sequence;
            const messages = [];
            for (const client of ['A', 'B']) {
                const s = stateSchema.parse(await both('state', { client }));
                if (s.length > 0) {
                    await both('edit', { client, edit: {
                        kind: 'reference', pos: random.int(s.length),
                        id: `${round}`, refType: random.pick([0, 64, 128, 256]),
                        slidingPreference: random.pick([0, 1]),
                    } });
                }
                const start = random.int(s.length + 1);
                let edit: Edit = s.length > 0 && random.int(3) === 0 ? { kind: 'remove', start: Math.min(start, s.length - 1), end: s.length } : { kind: 'insert', pos: start, text: random.pick(['abc', '😀', '\ud800', '\udfff', '\n', 'é']) };
                if (s.length > 0 && random.int(3) === 0)
                    edit = { kind: 'annotate', start: Math.min(start, s.length - 1), end: s.length, props: { color: random.pick(['red', 'blue', null]) } };
                const contents = await both('edit', { client, edit });
                await both('state', { client });
                await both('snapshot', { client, version: 'legacy' });
                messages.push({ clientId: client, clientSequenceNumber: round + 1, referenceSequenceNumber: ref, sequenceNumber: ++sequence, minimumSequenceNumber: 0, type: 'op', contents });
            }
            for (const message of messages)
                for (const client of ['A', 'B'])
                    await both('process', { client, message });
            for (const client of ['A', 'B']) {
                await both('state', { client });
                await both('snapshot', { client, version: 'v1' });
            }
        }
        for (const client of ['A', 'B']) {
            await both('minSeq', { client, seq: sequence });
            await both('snapshot', { client, version: 'v1' });
            await both('snapshot', { client, version: 'legacy' });
        }
        if ((seed + 1) % 100 === 0)
            console.log(`focused insert/remove/annotation/reference snapshots: ${seed + 1} seeds`);
    }
}
finally {
    for (const p of peers)
        p.close();
}
