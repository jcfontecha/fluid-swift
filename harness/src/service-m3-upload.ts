import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { convertSummaryTreeToWholeSummaryTree } from '@fluidframework/server-services-client';
import type { ISummaryTree } from '@fluidframework/driver-definitions/internal';

/** Tinylicious 7 exposes shredded storage only. Verify the whole-summary HTTP contract
 * against the TS converter on a separate recording endpoint, without pretending it is tinylicious. */
export async function wholeUpload(call: (params: Record<string, unknown>) => Promise<unknown>) {
    const summary = { type: 1, tree: {
        'unicode 🙂': { type: 2, content: 'hello 🙂' },
        binary: { type: 2, content: new Uint8Array([0, 1, 127, 255]) },
        reused: { type: 3, handleType: 1, handle: '/.channels/A' },
        attachment: { type: 4, id: 'attachment' },
        unreferenced: { type: 1, unreferenced: true, tree: {} },
    } } satisfies ISummaryTree;
    const converted = convertSummaryTreeToWholeSummaryTree('parent', summary, '', '.app');
    const expected = { entries: converted.entries ?? [], message: '', sequenceNumber: 0, type: 'channel' };
    let recorded: { url?: string; method?: string; body: string } | undefined;
    const server = createServer(async (request, response) => {
        const chunks: Buffer[] = [];
        for await (const chunk of request) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk)));
        recorded = { url: request.url, method: request.method, body: Buffer.concat(chunks).toString('utf8') };
        response.setHeader('Content-Type', 'application/json');
        response.end(JSON.stringify({ id: 'uploaded-summary' }));
    });
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    try {
        const address = server.address();
        assert(address && typeof address !== 'string');
        assert.equal(await call({ endpoint: `http://127.0.0.1:${address.port}`, summary,
            context: { ackHandle: 'parent', proposalHandle: 'proposal', referenceSequenceNumber: 19 } }), 'uploaded-summary');
        assert(recorded);
        assert.equal(recorded.method, 'POST');
        assert.equal(recorded.url, '/repos/tinylicious/git/summaries?initial=false');
        assert.equal(recorded.body, JSON.stringify(expected), 'whole-summary HTTP body byte-exact against TS');
    } finally {
        server.closeAllConnections();
        await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    }
}
