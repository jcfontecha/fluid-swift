import assert from 'node:assert/strict';
import { redemptionOracle } from './redemption.js';
import { epochCacheOracle, cacheCases } from './epoch-cache.js';
import { prefetchOracle } from './prefetch.js';
import { snapshotManagerOracle, snapshotRaceOracle } from './snapshot-manager.js';
import { joinOracle, joinLiveOracle } from './join.js';
import { socketFake, socketOracle } from './socket.js';
import { retryOracle } from './retry.js';
import { createServer, type ServerResponse } from 'node:http';
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
interface Trace {
    method: string;
    url: string;
    headers: Record<string, string>;
    body: string;
}
interface Outcome {
    cacheClears?: number;
    serverEpoch?: string;
    summary?: string;
    snapshot?: unknown;
    join?: unknown;
    messages?: unknown[];
    errorType?: string;
    canRetry?: boolean;
    statusCode?: number;
    retryAfterMs?: number;
    claims?: string;
    tenantId?: string;
}
let trace: Trace[] = [];
let statuses: number[] = [];
let wrapped = false;
let seed = 0;
let cacheClears = 0;
let snapshotDelay = 0;
let redeemMode = '';
let redeemJoinCalls = 0;
let limitActive = 0;
let limitPeak = 0;
let limitCount = 0;
let limitResponses: ServerResponse[] = [];
let limitTimer: ReturnType<typeof setTimeout> | undefined;
const server = createServer(async (request, response) => {
    const chunks: Buffer[] = [];
    for await (const chunk of request)
        chunks.push(Buffer.from(chunk));
    const raw = Buffer.concat(chunks).toString();
    const boundary = /boundary=([^;]+)/.exec(request.headers['content-type'] ?? '')?.[1];
    const headers: Record<string, string> = {};
    // Transport-generated headers are documented exclusions, not protocol headers.
    for (const [key, value] of Object.entries(request.headers)) {
        if (['host', 'connection', 'content-length', 'user-agent', 'accept-language', 'accept-encoding', 'sec-fetch-mode'].includes(key))
            continue;
        if (key === 'accept' && !request.url?.includes('trees/latest'))
            continue;
        headers[key] = String(value).replace(boundary ?? '\0', 'BOUNDARY').replace(/driverId=[^,]+/g, 'driverId=NORMALIZED');
    }
    trace.push({ method: request.method ?? '', url: request.url ?? '', headers, body: boundary ? raw.replaceAll(boundary, 'BOUNDARY').replace(/driverId=[^,]+/g, 'driverId=NORMALIZED') : raw });
    if (request.url?.startsWith('/redeem/')) {
        const join = request.url.endsWith('/join');
        if (join)
            redeemJoinCalls++;
        else
            await new Promise<void>(resolve => setTimeout(resolve, 20));
        const status = join ? (redeemJoinCalls === 1 ? 403 : 200) : redeemMode === 'failure' ? 404 : 200;
        response.statusCode = status;
        response.setHeader('content-type', 'application/json');
        if (status === 200)
            response.setHeader('x-fluid-epoch', 'E');
        response.end(status === 200 ? '{}' : '{"error":{"message":"failure"}}');
        return;
    }
    if (request.url === '/redirect') {
        response.statusCode = 404;
        response.setHeader('content-type', 'application/json');
        response.end(JSON.stringify({ error: { message: 'moved', '@error.redirectLocation': 'https://new.example/moved?ignored=1' } }));
        return;
    }
    if (request.url === '/limit') {
        limitCount++;
        limitActive++;
        limitPeak = Math.max(limitPeak, limitActive);
        limitResponses.push(response);
        limitTimer ??= setTimeout(() => {
            limitTimer = undefined;
            const pending = limitResponses;
            limitResponses = [];
            for (const response of pending) {
                limitActive--;
                response.setHeader('content-type', 'application/json');
                response.end('{}');
            }
        }, 50);
        return;
    }
    const status = statuses.shift() ?? 200;
    response.statusCode = status;
    response.setHeader('content-type', 'application/json');
    if (seed % 4 === 0 && seed % 9 >= 7)
        response.setHeader('x-fluid-epoch', seed % 9 === 8 ? 'F' : 'E');
    if (status === 401)
        response.setHeader('www-authenticate', 'Bearer realm="tenant", error="insufficient_claims", claims="eyJhIjoxfQ=="');
    if (status === 429)
        response.setHeader('retry-after', String(1 + seed % 4));
    if (status !== 200) {
        response.end('{"error":{"message":"scripted failure","code":"outer"}}');
        return;
    }
    if (request.url?.endsWith('/snapshot')) {
        response.end('{"id":"proposal"}');
        return;
    }
    if (request.url?.includes('joinSession')) {
        response.end(JSON.stringify({ id: 'session', runtimeTenantId: 'runtime', tenantId: '', deltaStreamSocketUrl: origin, socketToken: 'token', snapshotStorageUrl: 'http://snapshot', deltaStorageUrl: 'http://delta' }));
        return;
    }
    if (request.url?.includes('trees/latest')) {
        response.setHeader('x-fluid-epoch', 'E');
        if (snapshotDelay > 0)
            await new Promise<void>(resolve => setTimeout(resolve, snapshotDelay));
        const snapshot = { id: 'snapshot', trees: [{ id: 'root', sequenceNumber: seed, entries: [{ path: 'blob', type: 'blob' as const, id: 'b' }] }], blobs: [{ id: 'b', content: 'aGVsbG8=', encoding: 'base64' as const, size: 5 }], ops: [] };
        if (seed % 2 === 0) {
            response.setHeader('content-type', 'application/ms-fluid');
            response.end(Buffer.from(convertToCompactSnapshot(convertOdspSnapshotToSnapshotTreeAndBlobs(snapshot))));
        }
        else
            response.end(JSON.stringify(snapshot));
        return;
    }
    const messages = [1, 2, 4].map(sequenceNumber => ({ sequenceNumber, contents: seed }));
    response.end(JSON.stringify({ value: wrapped ? messages.map(op => ({ op, sequenceNumber: op.sequenceNumber })) : messages }));
});
// Discovery tests advance Date by an hour; keep Engine.IO heartbeat outside that virtual window.
const io = new Server(server, { transports: ['websocket'], pingInterval: 7200000, pingTimeout: 7200000 });
const liveSocketFake = socketFake(io);
await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
const address = server.address();
assert(address !== null && typeof address !== 'string');
const origin = `http://127.0.0.1:${address.port}`;
const url = origin + '/ops';
const self = process.argv.includes('--self');
const count = Number(process.argv.find(value => value.startsWith('--seeds='))?.split('=')[1] ?? 1000);
if (!self)
    execFileSync('swift', ['build', '--scratch-path', '.build/odsp2', '--product', 'FluidOdspNetPeer'], { cwd: '..', stdio: 'inherit' });
const child = self ? undefined : spawn('../.build/odsp2/debug/FluidOdspNetPeer', [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = child ? createInterface({ input: child.stdout })[Symbol.asyncIterator]() : undefined;
const logger = new MockLogger().toTelemetryLogger();
function normalizeError(error: unknown): Outcome {
    if (!(error instanceof Error))
        throw error;
    const fields = error as Error & Outcome;
    if (fields.errorType === undefined)
        throw error;
    return { errorType: fields.errorType, canRetry: fields.canRetry, statusCode: fields.statusCode, retryAfterMs: getRetryDelayFromError(error), claims: fields.claims, tenantId: fields.tenantId, serverEpoch: fields.serverEpoch };
}
async function oracle(): Promise<Outcome> {
    const resolvedUrl = await new OdspDriverUrlResolver().resolve({ url: origin + '?driveId=d&itemId=i&path=' });
    const tracker = new EpochTracker({ get: async () => undefined, put: async () => { }, removeEntries: async () => { cacheClears++; } }, { resolvedUrl, docId: 'doc' }, logger, false);
    if (seed % 4 === 0 && seed % 9 >= 7)
        tracker.setEpoch('E', false, 'test');
    const storage = new OdspDeltaStorageService(url, async (options) => options.refresh ? 'Bearer refreshed' : 'Bearer initial', tracker, logger);
    try {
        if (seed % 4 === 1)
            return { join: await fetchJoinSession(resolvedUrl, 'opStream/joinSession', 'POST', logger, async (options) => options.refresh ? 'Bearer refreshed' : 'Bearer initial', tracker, true, { refresh: false }, false, false, 'Guest') };
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
    catch (error) {
        return normalizeError(error);
    }
}
function reset(index: number): void {
    seed = index;
    wrapped = index % 2 === 0;
    statuses = [[200], [401, 200], [403, 403], [404], [409], [429], [500], [409], [409]][index % 9]?.slice() ?? [200];
    if (index % 4 !== 0)
        statuses = [200];
    trace = [];
    cacheClears = 0;
}
function requestNumber(request: Trace): number {
    const match = /RequestNumber=(\d+)/.exec(request.headers['x-requeststats'] ?? '');
    assert(match?.[1], 'correlation number required');
    return Number(match[1]);
}
function correlationOrder(requests: Trace[]): Trace[] {
    return [...requests].sort((a, b) => requestNumber(a) - requestNumber(b));
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
    for (const documentId of ['doc', 'parallel', 'overlap', 'disconnect', 'error400', 'error404', 'error406', 'badmode']) {
        liveSocketFake.reset();
        const expected = await socketOracle(origin, documentId);
        const expectedWire = await liveSocketFake.finish(documentId === 'doc' ? 4 : ['parallel', 'overlap', 'disconnect'].includes(documentId) ? 2 : 0);
        liveSocketFake.reset();
        const actual = self ? await socketOracle(origin, documentId) : await (async () => {
            assert(child && lines);
            child.stdin.write(JSON.stringify({ socket: true, origin, documentId }) + '\n');
            const line = await lines.next();
            assert(!line.done);
            return JSON.parse(line.value) as unknown;
        })();
        assert.deepEqual(JSON.parse(JSON.stringify(actual)), JSON.parse(JSON.stringify(expected)), `live socket ${documentId}`);
        const actualWire = await liveSocketFake.finish(documentId === 'doc' ? 4 : ['parallel', 'overlap', 'disconnect'].includes(documentId) ? 2 : 0);
        if (documentId === 'parallel') {
            // Independent Swift child tasks may start in either order; every frame and transport count remains compared.
            assert.deepEqual([...actualWire].sort(), [...expectedWire].sort(), `live socket wire ${documentId}`);
        }
        else {
            assert.deepEqual(actualWire, expectedWire, `live socket wire ${documentId}`);
        }
    }
    reset(1);
    const expectedJoinCache = await joinOracle(origin);
    const joinRequests = structuredClone(trace);
    reset(1);
    if (child && lines) {
        child.stdin.write(JSON.stringify({ joinCache: true, origin }) + '\n');
        const line = await lines.next();
        assert(!line.done);
        assert.deepEqual(JSON.parse(line.value), expectedJoinCache, 'join-session cache');
        assert.deepEqual(trace, joinRequests, 'join-session cache requests');
    }
    reset(1);
    const expectedJoinLive = await joinLiveOracle(origin);
    const liveJoinRequests = structuredClone(trace);
    reset(1);
    if (child && lines) {
        child.stdin.write(JSON.stringify({ joinLive: true, origin }) + '\n');
        const line = await lines.next();
        assert(!line.done);
        assert.deepEqual(JSON.parse(line.value), expectedJoinLive, 'join-session live refresh/disconnect');
        assert.deepEqual(trace, liveJoinRequests, 'join-session live refresh/disconnect requests');
    }
    for (const kind of ['default', 'retry', 'limited', 'summarizer', 'timeout']) {
        reset(2);
        statuses = kind === 'retry' || kind === 'limited' ? [413, 200] : [200];
        const expected = await snapshotManagerOracle(origin, kind);
        const expectedRequests = structuredClone(trace);
        reset(2);
        statuses = kind === 'retry' || kind === 'limited' ? [413, 200] : [200];
        if (child && lines) {
            child.stdin.write(JSON.stringify({ snapshotManager: kind, origin }) + '\n');
            const line = await lines.next();
            assert(!line.done);
            assert.deepEqual(JSON.parse(line.value), JSON.parse(JSON.stringify(expected)), `snapshot manager ${kind}`);
            assert.deepEqual(trace, expectedRequests, `snapshot manager requests ${kind}`);
        }
    }
    for (const kind of ['cacheFirst', 'networkFirst', 'cacheMiss', 'cacheFailure', 'networkFailure', 'bothFailureCacheFirst', 'bothFailureNetworkFirst']) {
        reset(2);
        snapshotDelay = kind === 'cacheFirst' ? 25 : 0;
        statuses = kind === 'networkFailure' || kind.startsWith('bothFailure') ? [500] : [200];
        const expected = await snapshotRaceOracle(origin, kind);
        const expectedRequests = structuredClone(trace);
        reset(2);
        statuses = kind === 'networkFailure' || kind.startsWith('bothFailure') ? [500] : [200];
        if (child && lines) {
            child.stdin.write(JSON.stringify({ snapshotRace: kind, origin }) + '\n');
            const line = await lines.next();
            assert(!line.done);
            assert.deepEqual(JSON.parse(line.value), expected, `snapshot race ${kind}`);
            assert.deepEqual(trace, expectedRequests, `snapshot race requests ${kind}`);
        }
    }
    snapshotDelay = 0;
    for (const failPut of [false, true]) {
        reset(2);
        const expected = await prefetchOracle(origin, failPut);
        const expectedRequests = structuredClone(trace);
        reset(2);
        if (child && lines) {
            child.stdin.write(JSON.stringify({ prefetch: true, failPut, origin }) + '\n');
            const line = await lines.next();
            assert(!line.done);
            assert.deepEqual(JSON.parse(line.value), expected, `prefetch ${failPut}`);
            assert.deepEqual(trace, expectedRequests, `prefetch requests ${failPut}`);
        }
    }
    const expectedCache = await epochCacheOracle(origin);
    if (child && lines) {
        child.stdin.write(JSON.stringify({ epochCache: cacheCases }) + '\n');
        const line = await lines.next();
        assert(!line.done);
        assert.deepEqual(JSON.parse(line.value), expectedCache, 'epoch cache envelopes');
    }
    reset(1);
    limitPeak = limitCount = 0;
    const limitResolved = await new OdspDriverUrlResolver().resolve({ url: origin + '?driveId=d&itemId=i&path=' });
    const limitTracker = new EpochTracker({ get: async () => undefined, put: async () => { }, removeEntries: async () => { } }, { docId: 'doc', resolvedUrl: limitResolved }, logger, false);
    await Promise.all(Array.from({ length: 48 }, () => limitTracker.fetch(origin + '/limit', { method: 'POST' }, 'test')));
    assert.deepEqual({ peak: limitPeak, count: limitCount }, { peak: 24, count: 48 }, 'TS request limiter');
    limitPeak = limitCount = 0;
    if (child && lines) {
        child.stdin.write(JSON.stringify({ limit: true, origin }) + '\n');
        const line = await lines.next();
        assert(!line.done);
        assert.deepEqual(JSON.parse(line.value), { done: 48 });
        assert.deepEqual({ peak: limitPeak, count: limitCount }, { peak: 24, count: 48 }, 'Swift request limiter');
    }
    reset(1);
    const redirectTracker = new EpochTracker({ get: async () => undefined, put: async () => { }, removeEntries: async () => { cacheClears++; } }, { docId: 'doc', resolvedUrl: limitResolved }, logger, false);
    let redirectExpected: unknown;
    try {
        await redirectTracker.fetch(origin + '/redirect', { method: 'POST' }, 'test');
    }
    catch (error) {
        const value = error as Error & Outcome & {
            redirectUrl: {
                siteUrl: string;
            };
        };
        redirectExpected = { ...normalizeError(error), cacheClears, redirectSiteUrl: value.redirectUrl.siteUrl };
    }
    const redirectRequests = structuredClone(trace);
    reset(1);
    if (child && lines) {
        child.stdin.write(JSON.stringify({ redirect: true, origin }) + '\n');
        const line = await lines.next();
        assert(!line.done);
        assert.deepEqual(JSON.parse(line.value), JSON.parse(JSON.stringify(redirectExpected)), 'location redirection');
        assert.deepEqual(trace, redirectRequests, 'location redirection requests');
    }
    for (const mode of ['success', 'failure', 'timeout']) {
        reset(1);
        redeemMode = mode;
        redeemJoinCalls = 0;
        const expected = await redemptionOracle(origin, mode, () => redeemJoinCalls);
        const expectedRequests = structuredClone(trace);
        reset(1);
        redeemJoinCalls = 0;
        if (child && lines) {
            child.stdin.write(JSON.stringify({ redemption: mode, origin }) + '\n');
            const line = await lines.next();
            assert(!line.done);
            assert.deepEqual(JSON.parse(line.value), expected, `redemption ${mode}`);
            assert.deepEqual(correlationOrder(trace), correlationOrder(expectedRequests), `redemption requests ${mode}`);
        }
    }
    const retry = await retryOracle();
    if (child && lines) {
        child.stdin.write('{"retry":true}\n');
        const line = await lines.next();
        assert(!line.done);
        assert.deepEqual(JSON.parse(line.value), retry, 'deterministic retry clock');
    }
    console.log(`odsp-net ${self ? 'TS self-check' : 'Swift-vs-TS'}: ${count} REST seeds passed plus live socket, discovery, snapshot manager/races/prefetch, epoch envelopes/limiter/redirect/redemption, and retry clock`);
}
finally {
    child?.kill();
    io.close();
    server.closeAllConnections();
    await new Promise<void>(resolve => server.close(() => resolve()));
}
