import { performance } from 'node:perf_hooks';
import { Peer } from './transport.js';
import { stateSchema } from './protocol.js';

const peer = new Peer('swift', []);
const operations = 4000;
const clients = 32;
const width = 256;
try {
    await peer.call('create', { client: 'observer' });
    const start = performance.now();
    for (let index = 0; index < operations; index++) {
        await peer.call('process', {
            client: 'observer',
            message: {
                clientId: `writer-${index % clients}`,
                clientSequenceNumber: Math.floor(index / clients) + 1,
                referenceSequenceNumber: index,
                sequenceNumber: index + 1,
                minimumSequenceNumber: 0,
                type: 'op',
                contents: { type: 0, pos1: index * width, seg: 'x'.repeat(width) },
            },
        });
    }
    const elapsed = (performance.now() - start) / 1000;
    await peer.call('minSeq', { client: 'observer', seq: operations });
    const state = stateSchema.parse(await peer.call('state', { client: 'observer' }));
    if (state.length !== operations * width)
        throw Error('benchmark lost content');
    console.log(JSON.stringify({ operations, clients, utf16Length: state.length, elapsedSeconds: elapsed, operationsPerSecond: operations / elapsed }));
}
finally {
    peer.close();
}
