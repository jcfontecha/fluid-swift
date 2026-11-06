import { createServer, type IncomingMessage, type Server as HttpServer, type ServerResponse } from 'node:http';
import { Server, type Socket } from 'socket.io';
import { convertToCompactSnapshot } from '../../../node_modules/@fluidframework/odsp-driver/lib/compactSnapshotWriter.js';
import type { FaultTarget, Scenario } from './scenario.js';

export interface HttpTrace {
    method: string;
    url: string;
    headers: Record<string, string>;
    body: string;
}

/** The recorded wire traffic of one scenario run: HTTP requests and server-observed socket frames. */
export interface WireTrace {
    http: HttpTrace[];
    socket: string[];
}

// Transport-generated headers are documented exclusions (the same set as the ODSP 2 gate).
const transportHeaders = ['host', 'connection', 'content-length', 'user-agent', 'accept-language', 'accept-encoding', 'sec-fetch-mode'];
const uuidPattern = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;
const epoch = 'E';

export function sequencedOp(sequenceNumber: number, clientId: string | null, contents: unknown): Record<string, unknown> {
    return {
        clientId,
        sequenceNumber,
        minimumSequenceNumber: 0,
        clientSequenceNumber: sequenceNumber,
        referenceSequenceNumber: sequenceNumber - 1,
        type: 'op',
        contents,
        timestamp: 1700000000000 + sequenceNumber,
    };
}

function text(content: unknown): string {
    return JSON.stringify(content);
}

function hexToBuffer(hex: string): ArrayBuffer {
    const bytes = Buffer.from(hex, 'hex');
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}

/** The scripted fake ODSP service: REST endpoints plus a websocket-only Socket.IO push service. */
export class FakeOdsp {
    public readonly http: HttpServer;
    public readonly io: Server;
    private scenario: Scenario | undefined;
    private trace: WireTrace = { http: [], socket: [] };
    private faultsLeft = 0;
    private nextSequenceNumber = 1;
    private summaries = 0;

    public constructor(private readonly port: number) {
        this.http = createServer((request, response) => {
            this.handle(request, response).catch(error => {
                response.statusCode = 599;
                response.end(String(error));
            });
        });
        this.io = new Server(this.http, { transports: ['websocket'], pingInterval: 7200000, pingTimeout: 7200000 });
        this.io.on('connection', socket => this.connection(socket));
    }

    public get origin(): string {
        return `http://127.0.0.1:${this.port}`;
    }

    public async listen(): Promise<void> {
        await new Promise<void>(resolve => this.http.listen(this.port, '127.0.0.1', resolve));
    }

    public async close(): Promise<void> {
        this.io.close();
        this.http.closeAllConnections();
        await new Promise<void>(resolve => this.http.close(() => resolve()));
    }

    public reset(scenario: Scenario): void {
        this.scenario = scenario;
        this.trace = { http: [], socket: [] };
        this.faultsLeft = scenario.server.fault?.times ?? 0;
        this.nextSequenceNumber = this.latest() + 1;
        this.summaries = 0;
    }

    /** Waits until the server has observed `disconnects` disconnect_document frames, then hands over the trace. */
    public async take(disconnects: number): Promise<WireTrace> {
        for (let attempt = 0; this.observedDisconnects() < disconnects; attempt++) {
            if (attempt === 1000)
                throw new Error(`expected ${disconnects} disconnect_document frames`);
            await new Promise<void>(resolve => setTimeout(resolve, 2));
        }
        const trace = this.trace;
        this.trace = { http: [], socket: [] };
        return trace;
    }

    private observedDisconnects(): number {
        return this.trace.socket.filter(frame => frame.startsWith('["disconnect_document"')).length;
    }

    private get current(): Scenario {
        if (this.scenario === undefined)
            throw new Error('fake ODSP used before reset');
        return this.scenario;
    }

    private latest(): number {
        const server = this.current.server;
        return server.sequenceNumber + server.snapshotOps + server.restOps;
    }

    /** Returns the scripted fault for this request class, consuming one use. */
    private fault(target: FaultTarget): number | 'epoch' | undefined {
        const fault = this.current.server.fault;
        if (fault === null || fault.target !== target || this.faultsLeft === 0)
            return undefined;
        this.faultsLeft--;
        return fault.status;
    }

    private record(request: IncomingMessage, raw: Buffer): void {
        const boundary = /boundary=([^;]+)/.exec(request.headers['content-type'] ?? '')?.[1];
        const headers: Record<string, string> = {};
        for (const [key, value] of Object.entries(request.headers)) {
            if (transportHeaders.includes(key))
                continue;
            if (key === 'accept' && !request.url?.includes('trees/latest'))
                continue;
            headers[key] = String(value).replace(boundary ?? '\0', 'BOUNDARY').replace(/driverId=[^,]+/g, 'driverId=NORMALIZED');
        }
        const binary = request.headers['content-type'] === 'application/octet-stream';
        let body = binary ? raw.toString('hex') : raw.toString();
        if (boundary !== undefined)
            body = body.replaceAll(boundary, 'BOUNDARY');
        body = body.replace(/driverId=[^,\r]+/g, 'driverId=NORMALIZED');
        this.trace.http.push({ method: request.method ?? '', url: request.url ?? '', headers, body });
    }

    private async handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
        const chunks: Buffer[] = [];
        for await (const chunk of request)
            chunks.push(Buffer.from(chunk));
        const raw = Buffer.concat(chunks);
        this.record(request, raw);
        const url = request.url ?? '';
        const target = this.target(request.method ?? '', url);
        const fault = this.fault(target);
        if (typeof fault === 'number') {
            this.failure(response, fault);
            return;
        }
        response.statusCode = 200;
        response.setHeader('x-fluid-epoch', fault === 'epoch' ? 'F' : epoch);
        switch (target) {
            case 'treesLatest':
                this.snapshot(response);
                return;
            case 'blob':
                this.blob(response, url);
                return;
            case 'createBlob':
                this.json(response, { id: `created-${this.current.seed}-${raw.length}` });
                return;
            case 'joinSession':
                this.joinSession(response);
                return;
            case 'ops':
                this.ops(response, url);
                return;
            case 'upload':
                this.summaries++;
                this.json(response, { id: `proposal-${this.current.seed}-${this.summaries}` });
                return;
            case 'versions':
                this.json(response, { value: [{ id: `snap-${this.current.seed}` }, { id: 'older' }] });
                return;
            case 'createFile':
                this.createFile(response, request.method ?? '', url);
                return;
            case 'push':
                throw new Error(`unexpected request ${request.method} ${url}`);
        }
    }

    private target(method: string, url: string): FaultTarget {
        if (url.includes('/trees/latest'))
            return 'treesLatest';
        if (url.includes('/opStream/attachments/'))
            return 'blob';
        if (url.includes('/opStream/attachment/content'))
            return 'createBlob';
        if (url.includes('/opStream/joinSession'))
            return 'joinSession';
        if (url.includes('/opStream?ump=1&filter='))
            return 'ops';
        if (url.includes('/snapshots/versions'))
            return 'versions';
        if (url.includes('/items/root:') || url.includes(':/content?') || method === 'PATCH')
            return 'createFile';
        if (url.endsWith('/opStream/snapshots/snapshot'))
            return 'upload';
        throw new Error(`unexpected request ${method} ${url}`);
    }

    private failure(response: ServerResponse, status: number): void {
        response.statusCode = status;
        response.setHeader('content-type', 'application/json');
        if (status === 401)
            response.setHeader('www-authenticate', 'Bearer realm="tenant", error="insufficient_claims", claims="eyJhIjoxfQ=="');
        if (status === 409)
            response.setHeader('x-fluid-epoch', epoch);
        if (status === 429)
            response.setHeader('retry-after', '0');
        response.end(text({ error: { message: 'scripted failure', code: 'outer' } }));
    }

    private json(response: ServerResponse, content: unknown): void {
        response.setHeader('content-type', 'application/json');
        response.end(text(content));
    }

    private protocolBlobs(): [string, string][] {
        const sequenceNumber = this.current.server.sequenceNumber;
        return [
            ['attributes', text({ minimumSequenceNumber: sequenceNumber, sequenceNumber })],
            ['quorumMembers', '[]'],
            ['quorumProposals', '[]'],
            ['quorumValues', '[]'],
        ];
    }

    private snapshot(response: ServerResponse): void {
        const scenario = this.current;
        const server = scenario.server;
        const snapshotOps: Record<string, unknown>[] = [];
        for (let index = 1; index <= server.snapshotOps; index++)
            snapshotOps.push(sequencedOp(server.sequenceNumber + index, 'snapshot-client', { snapshot: index }));
        const protocolBlobs = this.protocolBlobs();
        const root = `snap-${scenario.seed}`;
        if (server.format === 'json') {
            const entries: unknown[] = [
                { path: '.app', type: 'tree' },
                { path: '.protocol', type: 'tree' },
            ];
            const blobs: unknown[] = [];
            for (const blob of server.appBlobs) {
                entries.push({ path: `.app/${blob.id}`, type: 'blob', id: blob.id });
                blobs.push({ id: blob.id, content: Buffer.from(blob.hex, 'hex').toString('base64'), encoding: 'base64', size: blob.hex.length / 2 });
            }
            for (const [name, content] of protocolBlobs) {
                entries.push({ path: `.protocol/${name}`, type: 'blob', id: `${root}-${name}` });
                blobs.push({ id: `${root}-${name}`, content, size: content.length });
            }
            const snapshot = {
                id: root,
                trees: [{ id: root, sequenceNumber: server.sequenceNumber, entries }],
                blobs,
                ops: snapshotOps.map(op => ({ op, sequenceNumber: op.sequenceNumber })),
            };
            this.json(response, snapshot);
            return;
        }
        const blobContents = new Map<string, ArrayBuffer>();
        const appBlobs: Record<string, string> = {};
        for (const blob of server.appBlobs) {
            appBlobs[blob.id] = blob.id;
            blobContents.set(blob.id, hexToBuffer(blob.hex));
        }
        const protocol: Record<string, string> = {};
        for (const [name, content] of protocolBlobs) {
            protocol[name] = `${root}-${name}`;
            blobContents.set(`${root}-${name}`, hexToBuffer(Buffer.from(content).toString('hex')));
        }
        const compact = convertToCompactSnapshot({
            snapshotTree: {
                id: root,
                blobs: {},
                trees: {
                    '.app': { blobs: appBlobs, trees: {} },
                    '.protocol': { blobs: protocol, trees: {} },
                },
            },
            blobContents,
            ops: snapshotOps as never,
            sequenceNumber: server.sequenceNumber,
            latestSequenceNumber: server.sequenceNumber + server.snapshotOps,
            snapshotFormatV: 1,
        });
        response.setHeader('content-type', 'application/ms-fluid; v=1.0');
        response.end(Buffer.from(compact));
    }

    private blob(response: ServerResponse, url: string): void {
        const server = this.current.server;
        const id = decodeURIComponent(url.split('/opStream/attachments/')[1]?.split('/content')[0] ?? '');
        const blob = [...server.appBlobs, server.extraBlob].find(candidate => candidate.id === id);
        if (blob === undefined) {
            this.failure(response, 404);
            return;
        }
        response.setHeader('content-type', 'application/octet-stream');
        response.setHeader('cache-control', 'private');
        response.end(Buffer.from(blob.hex, 'hex'));
    }

    private joinSession(response: ServerResponse): void {
        const scenario = this.current;
        this.json(response, {
            id: `session-${scenario.seed}`,
            runtimeTenantId: 'runtime-tenant',
            tenantId: '',
            deltaStreamSocketUrl: this.origin,
            socketToken: scenario.websocketToken ? null : 'join-socket-token',
            snapshotStorageUrl: 'http://snapshot',
            deltaStorageUrl: 'http://delta',
        });
    }

    private ops(response: ServerResponse, url: string): void {
        const server = this.current.server;
        const filter = decodeURIComponent(url.split('filter=')[1] ?? '');
        const match = /sequenceNumber ge (\d+) and sequenceNumber le (\d+)/.exec(filter);
        if (match?.[1] === undefined || match[2] === undefined)
            throw new Error(`bad ops filter ${filter}`);
        const from = Number(match[1]);
        const to = Math.min(Number(match[2]), this.latest());
        const messages: Record<string, unknown>[] = [];
        for (let sequenceNumber = from; sequenceNumber <= to; sequenceNumber++)
            messages.push(sequencedOp(sequenceNumber, 'rest-client', { rest: sequenceNumber }));
        const value = server.wrappedOps ? messages.map(op => ({ op, sequenceNumber: op.sequenceNumber })) : messages;
        this.json(response, { value });
    }

    private createFile(response: ServerResponse, method: string, url: string): void {
        const scenario = this.current;
        if (method === 'PATCH') {
            this.json(response, { id: `new-item-${scenario.seed}`, name: scenario.fileName });
            return;
        }
        if (method === 'PUT') {
            this.json(response, { id: `new-item-${scenario.seed}`, name: `${scenario.fileName}.tmp` });
            return;
        }
        if (!url.includes('/opStream/snapshots/snapshot'))
            throw new Error(`unexpected create request ${url}`);
        this.json(response, { itemId: `new-item-${scenario.seed}`, itemUrl: 'http://item', driveId: scenario.driveId, id: `created-summary-${scenario.seed}`, sequenceNumber: 0 });
    }

    private connection(socket: Socket): void {
        this.trace.socket.push('transport');
        socket.onAny((name: string, ...args: unknown[]) => {
            this.trace.socket.push(JSON.stringify([name, ...args]).replace(uuidPattern, 'UUID'));
        });
        socket.on('connect_document', (message: { id: string; tenantId: string; nonce: string; mode: string; client: unknown }) => {
            const fault = this.fault('push');
            if (typeof fault === 'number') {
                socket.emit('connect_document_error', { code: fault, message: 'scripted failure', nonce: message.nonce });
                return;
            }
            const clientId = `client-${this.current.seed}`;
            // Frames before the handshake reply are queued by the client (DocumentDeltaConnection early handlers).
            socket.emit('op', message.id, [sequencedOp(this.latest() + 1000, 'early-client', { early: true })]);
            socket.emit('signal', { clientId: null, content: '{"type":"early"}' }, message.id);
            socket.emit('connect_document_success', {
                claims: {
                    documentId: message.id,
                    scopes: ['doc:read', 'doc:write'],
                    tenantId: message.tenantId,
                    user: { id: 'user' },
                    iat: 1700000000,
                    exp: 1800000000,
                    ver: '1.0',
                },
                clientId,
                existing: true,
                maxMessageSize: 16384,
                initialMessages: [sequencedOp(this.latest(), 'initial-client', { initial: true })],
                initialSignals: [{ clientId: null, content: '{"type":"initial"}' }],
                initialClients: [],
                version: '^0.4.0',
                supportedVersions: ['^0.4.0', '^0.3.0'],
                serviceConfiguration: { maxMessageSize: 16384, blockSize: 65436, noopTimeFrequency: 2000, noopCountFrequency: 50 },
                mode: message.mode,
                nonce: message.nonce,
                checkpointSequenceNumber: this.latest(),
                epoch: fault === 'epoch' ? 'F' : epoch,
                supportedFeatures: { api_get_ops: true, api_flush_ops: true, submit_signals_v2: true },
            });
        });
        socket.on('submitOp', (clientId: string, batches: Record<string, unknown>[][]) => {
            for (const batch of batches) {
                const sequenced: Record<string, unknown>[] = [];
                for (const message of batch) {
                    const sequenceNumber = this.nextSequenceNumber++;
                    sequenced.push({ ...message, clientId, sequenceNumber, minimumSequenceNumber: 0, timestamp: 1700000000000 + sequenceNumber });
                }
                socket.emit('op', this.documentId(), sequenced);
            }
        });
        socket.on('submitSignal', (clientId: string, signals: unknown[]) => {
            for (const signal of signals)
                socket.emit('signal', { ...(signal as object), clientId }, this.documentId());
        });
        // Answered without ops: a response with ops races the script's dispose when the REST fetch
        // fails at once, in TS as in Swift. ODSP 2 covers get_ops_response routing with ops.
        socket.on('get_ops', (_clientId: string, request: { nonce: string }) => {
            socket.emit('get_ops_response', { nonce: request.nonce, code: 200, messages: [] });
        });
        socket.on('flush_ops', (_clientId: string, request: { nonce: string }) => {
            socket.emit('flush_ops_response', { nonce: request.nonce, code: 200, lastPersistedSequenceNumber: this.nextSequenceNumber - 1 });
        });
    }

    private documentId(): string {
        return `session-${this.current.seed}`;
    }
}
