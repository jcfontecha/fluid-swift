import assert from 'node:assert/strict';
import { Random } from '../random.js';
import { createServer } from 'node:http';
import { Server } from 'socket.io';
import { execFileSync, spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdirSync, writeFileSync } from 'node:fs';
import { RouterliciousDocumentServiceFactory } from '@fluidframework/routerlicious-driver/internal';
import type { IResolvedUrl, IClient, IDocumentMessage, ISummaryContext, IDocumentDeltaConnection } from '@fluidframework/driver-definitions/internal';
import type { ISummaryTree } from '@fluidframework/driver-definitions';
const origin = 'http://127.0.0.1:7089';
const count = Number(process.argv.find(x => x.startsWith('--seeds='))?.split('=')[1] ?? 300);
type Trace = { http: unknown[]; socket: string[] };
let trace: Trace = { http: [], socket: [] };
let seed = 0;
let faultLeft = false;
let target = 'none';
let status = 0;
const targets = ['none', 'create', 'discovery', 'snapshot', 'delta', 'upload'];
const session = { ordererUrl: origin, historianUrl: origin, deltaStreamUrl: origin };
function op(n: number) {
    return { clientId: 'remote', sequenceNumber: n, minimumSequenceNumber: 0, clientSequenceNumber: n, referenceSequenceNumber: n - 1, type: 'op', contents: { n }, timestamp: 1700000000000 + n };
}
const server = createServer(async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(Buffer.from(chunk));
    const headers: Record<string, string> = {};
    for (const key of ['authorization', 'content-type', 'x-driver-version']) {
        if (req.headers[key] !== undefined) headers[key] = String(req.headers[key]);
    }
    trace.http.push({ method: req.method, url: req.url, headers, body: Buffer.concat(chunks).toString() });
    const url = new URL(req.url!, origin);
    const path = url.pathname;
    const method = req.headers['content-type']?.includes('restless') ? new URLSearchParams(Buffer.concat(chunks).toString()).get('method') : req.method;
    const kind = path.includes('/session/') ? 'discovery' : path.startsWith('/documents/') ? 'create' : path.includes('/deltas/') ? 'delta' : method === 'POST' ? 'upload' : 'snapshot';
    res.setHeader('content-type', 'application/json');
    if (faultLeft && kind === target) {
        faultLeft = false;
        res.statusCode = status;
        res.end(JSON.stringify({ message: 'scripted failure', ...(status === 429 ? { retryAfter: 0.001 } : {}) }));
        return;
    }
    let result: unknown;
    if (kind === 'create') {
        res.statusCode = 201;
        result = seed % 7 === 0 ? `doc-${seed}` : { id: `doc-${seed}`, session, token: "created-token" };
    } else if (kind === 'discovery') result = session;
    else if (kind === 'delta') result = [op(1), op(2)].filter(x => x.sequenceNumber > Number(url.searchParams.get('from')) && x.sequenceNumber < Number(url.searchParams.get('to')));
    else if (kind === 'upload') result = { id: `uploaded-${seed}` };
    else result = {
        id: `snapshot-${seed}`,
        trees: [{ id: `tree-${seed}`, sequenceNumber: 0, entries: [
            { path: '.app', type: 'tree' }, { path: '.app/data', type: 'blob', id: 'blob' },
            { path: '.protocol', type: 'tree' }, { path: '.protocol/attributes', type: 'blob', id: 'attributes' },
        ] }],
        blobs: [{ id: 'blob', content: `data-${seed}` }, { id: 'attributes', content: '{"sequenceNumber":0}' }],
    };
    res.end(JSON.stringify(result));
});
const io = new Server(server, { transports: ['websocket'], pingInterval: 7200000 });
io.on('connection', socket => {
    socket.onAny((name, ...args) => trace.socket.push(JSON.stringify([name, ...args]).replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, 'UUID')));
    socket.onAnyOutgoing((name, ...args) => trace.socket.push(JSON.stringify(['out', name, ...args]).replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, 'UUID')));
    socket.on('connect_document', message => socket.emit('connect_document_success', {
        claims: { documentId: message.id, tenantId: 'tenant', scopes: ['doc:read', 'doc:write'], user: { id: 'user' }, iat: 1700000000, exp: 1800000000, ver: '1.0' },
        clientId: 'client', existing: true, maxMessageSize: 16384, initialMessages: [], initialSignals: [], initialClients: [], version: '^0.4.0', supportedVersions: ['^0.4.0'],
        serviceConfiguration: { maxMessageSize: 16384, blockSize: 65436, noopTimeFrequency: 2000, noopCountFrequency: 50 },
        mode: message.mode, nonce: message.nonce, checkpointSequenceNumber: 2, supportedFeatures: {},
    }));
    socket.on('submitOp', (_client, batches: IDocumentMessage[][]) => socket.emit('op', `doc-${seed}`, batches.flat().map(m => ({ ...m, sequenceNumber: 3, minimumSequenceNumber: 0, clientId: 'client', timestamp: 1700000000003 }))));
});
await new Promise<void>(resolve => server.listen(7089, '127.0.0.1', resolve));
execFileSync('swift', ['build', '--scratch-path', '.build/l10', '--product', 'FluidR11sServicePeer'], { cwd: '..', stdio: 'inherit' });
const child = spawn('../.build/l10/debug/FluidR11sServicePeer', [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
function scenario(n: number) {
    const random = new Random(n);
    const create = Math.floor(n / 24) % 2 === 0;
    const blob = (content: string) => ({ type: 2 as const, content });
    const summary: ISummaryTree = { type: 1, tree: { '.app': { type: 1, tree: { data: blob(`create-${n}`) } }, '.protocol': { type: 1, tree: { attributes: blob('{"sequenceNumber":0,"minimumSequenceNumber":0}'), quorumValues: blob('[]') } } } };
    const app = summary.tree['.app'];
    assert(app?.type === 1);
    app.tree['nested space/🙂'] = { type: 1, unreferenced: true, tree: {
        binary: { type: 2, content: new Uint8Array(Array.from({ length: random.int(12) }, () => random.int(256))) },
        text: blob(JSON.stringify({ seed: n, value: random.uint32(), text: '🙂\n"&=' })),
    } };
    const resolved: IResolvedUrl & { createAsEphemeral: boolean; routerliciousResolvedUrl: boolean } = { routerliciousResolvedUrl: n % 4 === 0, createAsEphemeral: n % 5 === 0, type: 'fluid', id: create ? '' : `doc-${n}`, url: `${origin}/tenant/${create ? 'new' : `doc-${n}`}`, tokens: {}, endpoints: { ordererUrl: origin, storageUrl: `${origin}/repos/tenant`, deltaStorageUrl: `${origin}/deltas/tenant/${create ? 'new' : `doc-${n}`}` } };
    const client: IClient = { mode: 'write', details: { capabilities: { interactive: true }, environment: 'harness' }, permission: [], user: { id: 'user' }, scopes: [] };
    const message: IDocumentMessage = { clientSequenceNumber: 1, referenceSequenceNumber: 2, type: 'op', contents: { seed: n }, traces: [] };
    const upload: ISummaryTree = { type: 1, tree: { data: blob(`upload-${n}`) } };
    const context: ISummaryContext = { referenceSequenceNumber: 2, ackHandle: undefined, proposalHandle: undefined };
    return { create, callback: n % 3 === 0, resolved, summary, client, message, upload, context };
}
async function oracle(s: ReturnType<typeof scenario>) {
    const tokens: unknown[] = [];
    const steps: unknown[] = [];
    const provider = {
        documentPostCreateCallback: s.callback ? async (id: string, token: string) => { tokens.push(['callback', id, token]); } : undefined,
        async fetchOrdererToken(tenant: string, document?: string, refresh = false) {
            tokens.push(['orderer', tenant, document ?? null, refresh]);
            return { jwt: refresh ? 'refreshed' : 'token', fromCache: false };
        },
        async fetchStorageToken(tenant: string, document: string, refresh = false) {
            tokens.push(['storage', tenant, document, refresh]);
            return { jwt: refresh ? 'refreshed' : 'token', fromCache: false };
        },
    };
    const factory = new RouterliciousDocumentServiceFactory(provider, { enableDiscovery: true, enableWholeSummaryUpload: true });
    let connection: IDocumentDeltaConnection | undefined;
    try {
        const service = s.create ? await factory.createContainer(s.summary, s.resolved) : await factory.createDocumentService(s.resolved);
        steps.push(['resolved', service.resolvedUrl]);
        const storage = await service.connectToStorage();
        const versions = await storage.getVersions(null, 1);
        steps.push(['versions', versions]);
        steps.push(['tree', await storage.getSnapshotTree(versions[0])]);
        steps.push(['blob', Buffer.from(await storage.readBlob('blob')).toString('base64')]);
        const deltas = await service.connectToDeltaStorage();
        const stream = deltas.fetchMessages(1, 3);
        const messages: unknown[] = [];
        for (;;) {
            const next = await stream.read();
            if (next.done) break;
            messages.push(...next.value);
        }
        steps.push(['deltas', messages]);
        connection = await service.connectToDeltaStream(s.client);
        connection.on('error', () => {});
        connection.on('pong', () => {});
        steps.push(['connected', connection.clientId]);
        const echo = new Promise<void>(resolve => connection!.on('op', () => resolve()));
        connection.submit([s.message]);
        await echo;
        steps.push(['uploaded', await storage.uploadSummaryWithContext(s.upload, s.context)]);
    } catch (error) {
        const e = error as { errorType?: string; canRetry?: boolean; statusCode?: number; message: string };
        steps.push(['error', e.errorType ? { errorType: e.errorType, canRetry: e.canRetry, statusCode: e.statusCode ?? null } : e.message]);
    }
    connection?.dispose();
    return JSON.parse(JSON.stringify({ steps, tokens }));
}
async function take() {
    await new Promise(resolve => setTimeout(resolve, 10));
    const result = trace;
    trace = { http: [], socket: [] };
    return result;
}
const coverage = new Map<string, number>();
try {
    for (seed = 0; seed < count; seed++) {
        target = targets[Math.floor(seed / 4) % targets.length]!;
        status = [401, 429, 500, 502][seed % 4]!;
        const s = scenario(seed);
        faultLeft = target !== 'none';
        const expected = await oracle(s);
        if (process.argv.includes("--debug")) console.error("oracle", JSON.stringify(expected), JSON.stringify(trace));
        const expectedWire = await take();
        faultLeft = target !== 'none';
        child.stdin.write(JSON.stringify(s) + '\n');
        const reply = await lines.next();
        assert(!reply.done, 'Swift exited');
        const actual: unknown = JSON.parse(reply.value);
        const actualWire = await take();
        if (process.argv.includes('--plant')) actualWire.http.push({ planted: true });
        try {
            assert.deepStrictEqual(actual, expected, `outcome seed ${seed}`);
            assert.deepStrictEqual(actualWire, expectedWire, `wire seed ${seed}`);
        } catch (error) {
            mkdirSync('traces/r11s-service', { recursive: true });
            writeFileSync(`traces/r11s-service/${seed}.json`, JSON.stringify({ s, target, status, expected, actual, expectedWire, actualWire }, null, 2));
            throw error;
        }
        if (seed % 25 === 24) console.log(`r11s-service progress: ${seed + 1}/${count}`);
        const key = `${s.create ? 'create' : 'load'} ${target}:${status}`;
        coverage.set(key, (coverage.get(key) ?? 0) + 1);
    }
    console.log([...coverage].map(([key, n]) => `${key}: ${n}`).join('\n'));
    console.log(`r11s-service: ${count} seeds passed; outcomes, tokens, HTTP bytes and socket frames`);
} finally {
    child.stdin.end();
    child.kill();
    io.close();
    server.closeAllConnections();
    server.close();
}
