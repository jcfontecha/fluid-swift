/** Reduce whole operations (including every delivery/ack), regenerating valid local positions. */
import { readFileSync, writeFileSync } from 'node:fs';
import { isDeepStrictEqual } from 'node:util';
import { z } from 'zod';
import { Peer } from './transport.js';
import { messageSchema, requestSchema, stateSchema } from './protocol.js';
const fixture = z.object({ seed: z.number(), requests: z.array(requestSchema.omit({ id: true, jsonrpc: true })) }).parse(JSON.parse(readFileSync(new URL(`./fixtures/seed-${process.argv[2] ?? '175'}.json`, import.meta.url), 'utf8')));
type Request = typeof fixture.requests[number];
const counts = new Map<string, number>();
const keys = fixture.requests.map(r => {
    const client = r.params.client ?? '';
    if (r.method === 'edit' && r.params.edit?.kind !== 'reference') {
        const n = (counts.get(client) ?? 0) + 1;
        counts.set(client, n);
        return `${client}:${n}`;
    }
    if (r.method === 'process') {
        const m = messageSchema.parse(r.params.message);
        return `${m.clientId}:${m.clientSequenceNumber}`;
    }
    return undefined;
});
const peer = new Peer('ts', []);
async function replay(keep: Set<string>): Promise<Request[] | undefined> {
    const out: Request[] = [];
    const contents = new Map<string, unknown>();
    const seqs = new Map<number, number>([[0, 0]]);
    const clientCounts = new Map<string, number>();
    const clientSeqs = new Map<string, number>();
    let seq = 0;
    for (const [i, r] of fixture.requests.entries()) {
        if (r.method !== 'process')
            continue;
        const m = messageSchema.parse(r.params.message);
        if (seqs.has(m.sequenceNumber))
            continue;
        if (keep.has(keys[i] ?? ''))
            seq++;
        seqs.set(m.sequenceNumber, seq);
    }
    for (const [i, original] of fixture.requests.entries()) {
        const r = structuredClone(original);
        const key = keys[i];
        if (key !== undefined && !keep.has(key))
            continue;
        const p = r.params;
        if (r.method === 'create')
            p.obliterate = true;
        if (r.method === 'edit') {
            const e = p.edit;
            if (!e || e.kind === 'reference')
                continue;
            const s = stateSchema.parse(await peer.call('state', { client: p.client }));
            if (e.kind === 'insert' || e.kind === 'marker') {
                e.pos = Math.min(e.pos, s.length);
            }
            else {
                if (s.length === 0)
                    return undefined;
                e.start = Math.min(e.start, s.length - 1);
                e.end = Math.min(Math.max(e.end, e.start + 1), s.length);
            }
            contents.set(key ?? '', await peer.call('edit', p));
            const client = p.client ?? '';
            const n = (clientCounts.get(client) ?? 0) + 1;
            clientCounts.set(client, n);
            clientSeqs.set(key ?? '', n);
        }
        else {
            if (r.method === 'process') {
                const m = messageSchema.parse(p.message);
                m.sequenceNumber = seqs.get(m.sequenceNumber) ?? 0;
                m.referenceSequenceNumber = seqs.get(m.referenceSequenceNumber) ?? 0;
                m.minimumSequenceNumber = seqs.get(m.minimumSequenceNumber) ?? 0;
                m.clientSequenceNumber = clientSeqs.get(key ?? '') ?? 0;
                m.contents = contents.get(key ?? '');
                p.message = m;
            }
            else if (r.method === 'minSeq') {
                p.seq = seqs.get(p.seq ?? 0) ?? 0;
            }
            await peer.call(r.method, p);
        }
        out.push(r);
    }
    const states: {
        text: number[];
        length: number;
    }[] = [];
    for (const client of ['A', 'B', 'C']) {
        const s = stateSchema.parse(await peer.call('state', { client }));
        states.push({ text: s.text, length: s.length });
    }
    return states.some(s => !isDeepStrictEqual(s, states[0])) ? out : undefined;
}
try {
    const keep = new Set(keys.filter((k): k is string => k !== undefined));
    let best = await replay(keep);
    if (!best)
        throw Error('source no longer diverges');
    let changed = true;
    while (changed) {
        changed = false;
        for (const key of [...keep]) {
            const candidate = new Set(keep);
            candidate.delete(key);
            const result = await replay(candidate);
            if (result) {
                keep.delete(key);
                best = result;
                changed = true;
                console.log(`retained ${keep.size} operations`);
            }
        }
    }
    writeFileSync(new URL(`./fixtures/seed-${fixture.seed}-minimized.json`, import.meta.url), JSON.stringify({ seed: fixture.seed, requests: best }, null, 2) + '\n');
}
finally {
    peer.close();
}
