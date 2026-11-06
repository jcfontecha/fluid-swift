import { isDeepStrictEqual } from 'node:util';
import { Peer } from './transport.js';

const peers = [new Peer('ts', []), new Peer('swift', [])];
async function both(method: string, params: unknown) {
    const values = await Promise.all(peers.map(peer => peer.call(method, params)));
    if (!isDeepStrictEqual(values[0], values[1]))
        throw Error(`${method}: ${JSON.stringify(values)}`);
    return values[0];
}
try {
    await both('create', { client: 'A' });
    const catchup = [];
    for (let index = 0; index < 3; index++) {
        const message = {
            clientId: 'B', clientSequenceNumber: index + 1,
            referenceSequenceNumber: index, sequenceNumber: index + 1,
            minimumSequenceNumber: 0, type: 'op',
            contents: { type: 0, pos1: index * 10001, seg: 'x'.repeat(10001) },
        };
        catchup.push(message);
        await both('process', { client: 'A', message });
    }
    for (const version of ['legacy', 'v1']) {
        const summary = await both('snapshot', { client: 'A', version, catchup: version === 'legacy' ? catchup : [] });
        await both('load', { client: 'C', summary });
        await both('state', { client: 'C' });
        await both('snapshot', { client: 'C', version: 'v1' });
    }
    const metadata = { minSequenceNumber: 2, sequenceNumber: 3, orderedChunkMetadata: [{ id: 'header' }, { id: 'body_0' }], totalLength: 3, totalSegmentCount: 3 };
    const summary = { type: 1, tree: {
        header: { type: 2, content: JSON.stringify({ version: '1', segmentCount: 1, length: 1, segments: ['a'], startIndex: 0, headerMetadata: metadata }) },
        body_0: { type: 2, content: JSON.stringify({ version: '1', segmentCount: 2, length: 2, segments: ['b', { json: 'c', seq: 3, client: 'B' }], startIndex: 1 }) },
    } };
    await both('load', { client: 'C', summary });
    await both('state', { client: 'C' });
    console.log('legacy catchup and multichunk V1 differential passed');
}
finally {
    for (const peer of peers)
        peer.close();
}
