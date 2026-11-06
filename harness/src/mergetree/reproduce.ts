import { readFileSync } from 'node:fs';
import { z } from 'zod';
import { isDeepStrictEqual } from 'node:util';
import { ScheduleAudit } from './schedule-audit.js';
import { Peer } from './transport.js';
import { stateSchema } from './protocol.js';
const fixture = z.object({ seed: z.number(), requests: z.array(z.object({ method: z.string(), params: z.unknown() })) }).parse(JSON.parse(readFileSync(new URL(process.argv[2] ?? './fixtures/seed-175.json', import.meta.url), 'utf8')));
const peer = new Peer('ts', []);
try {
    const audit = new ScheduleAudit();
    for (const request of fixture.requests) {
        const p = z.object({ client: z.string().optional(), message: z.unknown().optional(), seq: z.number().optional() }).parse(request.params);
        const result = await peer.call(request.method, request.method === 'create' ? { ...p, obliterate: true } : request.params);
        const client = p.client ?? '';
        if (request.method === 'create')
            audit.create(client);
        if (request.method === 'edit')
            audit.edit(client, result);
        if (request.method === 'process')
            audit.process(client, p.message);
        if (request.method === 'minSeq')
            audit.minSeq(client, p.seq ?? 0);
    }
    console.log('service/runtime schedule audit passed');
    const states: {
        client: string;
        text: number[];
        length: number;
    }[] = [];
    for (const client of ['A', 'B', 'C']) {
        const s = stateSchema.parse(await peer.call('state', { client }));
        states.push({ client, text: s.text, length: s.length });
    }
    console.log(JSON.stringify(states, null, 2));
    if (states.some(s => !isDeepStrictEqual(s.text, states[0]?.text)))
        throw Error(`TS 3.11.0 cross-client divergence reproduced from seed ${fixture.seed}`);
}
finally {
    peer.close();
}
