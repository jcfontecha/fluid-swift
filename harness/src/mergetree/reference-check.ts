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
    for (const endpointSliding of [false, true]) {
        for (const canSlideToEndpoint of [false, true]) {
            for (const slidingPreference of [0, 1]) {
                for (const refType of [0, 64, 128, 256]) {
                    await both('reset', {});
                    await both('create', { client: 'A', endpointSliding });
                    const initial = await both('edit', { client: 'A', edit: { kind: 'insert', pos: 0, text: 'abc' } });
                    await both('process', { client: 'A', message: { clientId: 'A', clientSequenceNumber: 1, referenceSequenceNumber: 0, sequenceNumber: 1, minimumSequenceNumber: 0, type: 'op', contents: initial } });
                    await both('edit', { client: 'A', edit: { kind: 'reference', pos: slidingPreference === 0 ? 0 : 2, id: 'ref', refType, slidingPreference, canSlideToEndpoint } });
                    const removal = await both('edit', { client: 'A', edit: { kind: 'remove', start: 0, end: 3 } });
                    await both('process', { client: 'A', message: { clientId: 'A', clientSequenceNumber: 2, referenceSequenceNumber: 1, sequenceNumber: 2, minimumSequenceNumber: 0, type: 'op', contents: removal } });
                    await both('state', { client: 'A' });
                    await both('minSeq', { client: 'A', seq: 2 });
                    await both('edit', { client: 'A', edit: { kind: 'insert', pos: 0, text: 'xyz' } });
                    await both('state', { client: 'A' });
                }
            }
        }
    }
    console.log('32 endpoint/reference retention combinations passed');
}
finally {
    for (const peer of peers)
        peer.close();
}
