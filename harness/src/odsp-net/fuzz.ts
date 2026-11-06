import assert from 'node:assert/strict';
import { retryOracle } from './retry.js';
import { createServer } from 'node:http';
import { Server } from 'socket.io';
import { spawn, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { getRetryDelayFromError } from '@fluidframework/driver-utils/internal';
import { MockLogger } from '@fluidframework/telemetry-utils/internal';
import { OdspDeltaStorageService } from '../../node_modules/@fluidframework/odsp-driver/lib/odspDeltaStorageService.js';
import { downloadSnapshot } from '../../node_modules/@fluidframework/odsp-driver/lib/fetchSnapshot.js';
import { convertOdspSnapshotToSnapshotTreeAndBlobs } from '../../node_modules/@fluidframework/odsp-driver/lib/odspSnapshotParser.js';
import { convertToCompactSnapshot } from '../../node_modules/@fluidframework/odsp-driver/lib/compactSnapshotWriter.js';
import { parseCompactSnapshotResponse } from '../../node_modules/@fluidframework/odsp-driver/lib/compactSnapshotParser.js';
import { fetchJoinSession } from '../../node_modules/@fluidframework/odsp-driver/lib/vroom.js';
import { OdspSummaryUploadManager } from '../../node_modules/@fluidframework/odsp-driver/lib/odspSummaryUploadManager.js';
import { EpochTracker } from '../../node_modules/@fluidframework/odsp-driver/lib/epochTracker.js';
import { OdspDriverUrlResolver } from '../../node_modules/@fluidframework/odsp-driver/lib/odspDriverUrlResolver.js';

// Start with a real HTTP boundary: neither oracle nor peer receives preconstructed requests.
interface Trace { method: string; url: string; headers: Record<string, string>; body: string }
interface Outcome { cacheClears?: number; serverEpoch?: string; summary?: string; snapshot?: unknown; join?: unknown; messages?: unknown[]; errorType?: string; canRetry?: boolean; statusCode?: number; retryAfterMs?: number; claims?: string; tenantId?: string }
let trace: Trace[] = [];
let statuses: number[] = [];
let wrapped = false;
let seed = 0;
let cacheClears = 0;
const server = createServer(async (request, response) => {
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(Buffer.from(chunk));
    const raw = Buffer.concat(chunks).toString();
    const boundary = /boundary=([^;]+)/.exec(request.headers['content-type'] ?? '')?.[1];
    const headers: Record<string, string> = {};
    // Transport-generated headers are documented exclusions, not protocol headers.
    for (const [key, value] of Object.entries(request.headers)) {
        if (['host', 'connection', 'content-length', 'user-agent', 'accept-language', 'accept-encoding', 'sec-fetch-mode'].includes(key)) continue;
        if (key === 'accept' && !request.url?.includes('trees/latest')) continue;
        headers[key] = String(value).replace(boundary ?? '\0', 'BOUNDARY').replace(/driverId=[^,]+/g, 'driverId=NORMALIZED');
    }
    trace.push({ method: request.method ?? '', url: request.url ?? '', headers, body: boundary ? raw.replaceAll(boundary, 'BOUNDARY').replace(/driverId=[^,]+/g, 'driverId=NORMALIZED') : raw });
    const status = statuses.shift() ?? 200;
    response.statusCode = status;
    response.setHeader('content-type', 'application/json');
    if (seed % 4 === 0 && seed % 9 >= 7) response.setHeader('x-fluid-epoch', seed % 9 === 8 ? 'F' : 'E');
    if (status === 401) response.setHeader('www-authenticate', 'Bearer realm="tenant", error="insufficient_claims", claims="eyJhIjoxfQ=="');
    if (status === 429) response.setHeader('retry-after', String(1 + seed % 4));
    if (status !== 200) {
        response.end('{"error":{"message":"scripted failure","code":"outer"}}');
        return;
    }
    if (request.url?.endsWith('/snapshot')) {
        response.end('{"id":"proposal"}');
        return;
    }
    if (request.url?.includes('joinSession')) {
        response.end(JSON.stringify({ id: 'session', runtimeTenantId: 'runtime', tenantId: '', deltaStreamSocketUrl: 'http://relay', snapshotStorageUrl: 'http://snapshot', deltaStorageUrl: 'http://delta' }));
        return;
    }
    if (request.url?.includes('trees/latest')) {
        const snapshot = { id: 'snapshot', trees: [{ id: 'root', sequenceNumber: seed, entries: [{ path: 'blob', type: 'blob' as const, id: 'b' }] }], blobs: [{ id: 'b', content: 'aGVsbG8=', encoding: 'base64' as const, size: 5 }], ops: [] };
        if (seed % 2 === 0) {
            response.setHeader('content-type', 'application/ms-fluid');
            response.end(Buffer.from(convertToCompactSnapshot(convertOdspSnapshotToSnapshotTreeAndBlobs(snapshot))));
        } else response.end(JSON.stringify(snapshot));
        return;
    }
    const messages = [1, 2, 4].map(sequenceNumber => ({ sequenceNumber, contents: seed }));
    response.end(JSON.stringify({ value: wrapped ? messages.map(op => ({ op, sequenceNumber: op.sequenceNumber })) : messages }));
});
const io = new Server(server, { transports: ['websocket'] });
io.on('connection', socket => {
    socket.on('connect_document', message => socket.emit('connect_document_success', { ...message, clientId: 'client', initialMessages: [], initialSignals: [] }));
    socket.on('get_ops', (_client, request) => socket.emit('get_ops_response', { nonce: request.nonce, code: 200, messages: [] }));
});
await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
const address = server.address();
assert(address !== null && typeof address !== 'string');
const origin = `http://127.0.0.1:${address.port}`;
const url = origin + '/ops';
const self = process.argv.includes('--self');
const count = Number(process.argv.find(value => value.startsWith('--seeds='))?.split('=')[1] ?? 1000);
if (!self) execFileSync('swift', ['build', '--scratch-path', '.build/odsp2', '--product', 'FluidOdspNetPeer'], { cwd: '..', stdio: 'inherit' });
const child = self ? undefined : spawn('../.build/odsp2/debug/FluidOdspNetPeer', [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = child ? createInterface({ input: child.stdout })[Symbol.asyncIterator]() : undefined;
const logger = new MockLogger().toTelemetryLogger();
function normalizeError(error: unknown): Outcome {
    if (!(error instanceof Error)) throw error;
    const fields = error as Error & Outcome;
    if (fields.errorType === undefined) throw error;
    return { errorType: fields.errorType, canRetry: fields.canRetry, statusCode: fields.statusCode, retryAfterMs: getRetryDelayFromError(error), claims: fields.claims, tenantId: fields.tenantId, serverEpoch: fields.serverEpoch };
}
async function oracle(): Promise<Outcome> {
    const resolvedUrl = await new OdspDriverUrlResolver().resolve({ url: origin + '?driveId=d&itemId=i&path=' });
    const tracker = new EpochTracker({ get: async () => undefined, put: async () => {}, removeEntries: async () => { cacheClears++; } }, { resolvedUrl, docId: 'doc' }, logger, false);
    if (seed % 4 === 0 && seed % 9 >= 7) tracker.setEpoch('E', false, 'test');
    const storage = new OdspDeltaStorageService(url, async options => options.refresh ? 'Bearer refreshed' : 'Bearer initial', tracker, logger);
    try {
        if (seed % 4 === 1) return { join: await fetchJoinSession(resolvedUrl, 'opStream/joinSession', 'POST', logger, async options => options.refresh ? 'Bearer refreshed' : 'Bearer initial', tracker, true, { refresh: false }, false, false, 'Guest') };
        if (seed % 4 === 2) {
            const result = await downloadSnapshot(resolvedUrl, async () => 'Bearer initial', { refresh: false }, undefined, undefined, logger, undefined, undefined, tracker);
            const content = result.odspResponse.content;
            const snapshot = content.headers.get('content-type')?.includes('ms-fluid')
                ? parseCompactSnapshotResponse(new Uint8Array(await content.arrayBuffer()), logger)
                : convertOdspSnapshotToSnapshotTreeAndBlobs(JSON.parse(await content.text()));
            return { snapshot: { tree: snapshot.snapshotTree, sequenceNumber: snapshot.sequenceNumber, ops: snapshot.ops, blobs: [...snapshot.blobContents].map(([id, bytes]) => [id, Buffer.from(bytes as ArrayBuffer).toString('hex')]) } };
        }
        if (seed % 4 === 3) {
            const upload = new OdspSummaryUploadManager(resolvedUrl.endpoints.snapshotStorageUrl, async () => 'Bearer initial', logger, tracker, () => 't/session');
            return { summary: await upload.writeSummaryTree({ type: 1, tree: { text: { type: 2, content: 'hello' }, binary: { type: 2, content: new Uint8Array([0, 255]) }, reuse: { type: 3, handleType: 1, handle: '/old' }, attachment: { type: 4, id: 'attachment' } } }, { ackHandle: 'parent', proposalHandle: undefined, referenceSequenceNumber: seed }) };
        }
        return { messages: (await storage.get(1, 6, {})).messages };
    }
    catch (error) { return normalizeError(error); }
}
function reset(index: number): void {
    seed = index;
    wrapped = index % 2 === 0;
    statuses = [[200], [401, 200], [403, 403], [404], [409], [429], [500], [409], [409]][index % 9]?.slice() ?? [200];
    if (index % 4 !== 0) statuses = [200];
    trace = [];
    cacheClears = 0;
}
try {
    for (let index = 0; index < count; index++) {
        reset(index);
        const expected = await oracle();
        expected.cacheClears = cacheClears;
        const requests = structuredClone(trace);
        reset(index);
        let actual: Outcome;
        if (self) {
            actual = await oracle();
            actual.cacheClears = cacheClears;
        }
        else {
            assert(child && lines);
            child.stdin.write(JSON.stringify({ url, origin, kind: index % 4, from: 1, to: 6, seed: index }) + '\n');
            const line = await lines.next();
            assert(!line.done, 'Swift peer exited');
            actual = JSON.parse(line.value) as Outcome;
        }
        assert.deepEqual(JSON.parse(JSON.stringify(actual)), JSON.parse(JSON.stringify(expected)), `outcome seed ${index}`);
        assert.deepEqual(trace, requests, `requests seed ${index}`);
    }
    const retry = await retryOracle();
    if (child && lines) {
        child.stdin.write('{"retry":true}\n');
        const line = await lines.next();
        assert(!line.done);
        assert.deepEqual(JSON.parse(line.value), retry, 'deterministic retry clock');
    }
    console.log(`odsp-net ${self ? 'TS self-check' : 'Swift-vs-TS'}: ${count} seeds passed (delta/auth/errors, join, JSON/compact snapshot requests and results, retry clock)`);
} finally {
    child?.kill();
    io.close();
    server.closeAllConnections();
    await new Promise<void>(resolve => server.close(() => resolve()));
}
