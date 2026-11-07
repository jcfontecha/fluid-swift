import { createServer } from "node:http";
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { EventEmitter } from 'node:events';
import { loadExistingContainer } from '@fluidframework/container-loader/internal';
import { createDOProviderContainerRuntimeFactory, createFluidContainer } from '@fluidframework/fluid-static/internal';
import { SharedMap } from '@fluidframework/map/internal';
import { MessageType, ScopeType, type IClient, type IDocumentMessage, type ISequencedDocumentMessage, type ISnapshotTree, type ISummaryTree, type IDocumentStorageService, type IDocumentDeltaConnection, type IDocumentService, type IResolvedUrl, type ITokenClaims, type ISignalMessage, type ISignalClient, type IClientConfiguration } from '@fluidframework/driver-definitions/internal';
import { z } from 'zod';
import { RetriableDocumentStorageService } from '../../node_modules/@fluidframework/container-loader/lib/retriableDocumentStorageService.js';
import { createChildLogger } from '@fluidframework/telemetry-utils/internal';
import { createGenericNetworkError } from '@fluidframework/driver-utils/internal';
const summary: ISummaryTree = JSON.parse(readFileSync('../Tests/FluidContainerLoaderTests/Fixtures/m2-summary.json', 'utf8'));
const blobs = new Map<string, ArrayBuffer>();
function tree(node: ISummaryTree): ISnapshotTree {
    const result: ISnapshotTree = { blobs: {}, trees: {} };
    for (const [key, child] of Object.entries(node.tree)) {
        if (child.type === 1)
            result.trees[key] = tree(child);
        else if (child.type === 2) {
            const id = `blob-${blobs.size}`;
            result.blobs[key] = id;
            blobs.set(id, new TextEncoder().encode(typeof child.content === 'string' ? child.content : '').buffer);
        }
        else
            throw new Error('unexpected fixture');
    }
    return result;
}
const snapshot = tree(summary);
const attributes = snapshot.trees['.protocol']?.blobs['attributes'];
assert(attributes !== undefined);
const sequence = z.object({ sequenceNumber: z.number() }).parse(JSON.parse(new TextDecoder().decode(blobs.get(attributes)))).sequenceNumber;
const storage: IDocumentStorageService = {
    getSnapshotTree: async () => snapshot,
    getVersions: async () => [{ id: 'version-1', treeId: 'tree-root' }],
    readBlob: async (id) => { const blob = blobs.get(id); assert(blob); return blob; },
    createBlob: async () => { throw new Error('unused'); },
    uploadSummaryWithContext: async () => { throw new Error('unused'); },
    downloadSummary: async () => { throw new Error('unused'); },
};
const resolved: IResolvedUrl = { type: 'fluid', id: 'doc', url: 'https://fake.example/tenant/doc', tokens: {}, endpoints: { storageUrl: 'https://fake.example/storage' } };
const client: IClient = { mode: 'write', details: { capabilities: { interactive: true } }, permission: [], scopes: [], user: { id: '' } };
class Ordering {
    sequenceNumber = sequence;
    log: ISequencedDocumentMessage[] = [];
    clients = new Map<string, Connection>();
    submitted: IDocumentMessage[] = [];
    broadcast(message: Omit<ISequencedDocumentMessage, 'sequenceNumber' | 'minimumSequenceNumber' | 'timestamp'>): void {
        const op: ISequencedDocumentMessage = { ...message, sequenceNumber: ++this.sequenceNumber, minimumSequenceNumber: 0, timestamp: 0 };
        this.log.push(op);
        for (const c of this.clients.values())
            c.emit('op', 'doc', [op]);
    }
    system(type: MessageType, data: string): void {
        this.broadcast({ type, data, clientId: null, clientSequenceNumber: -1, referenceSequenceNumber: -1, contents: null });
    }
    join(connection: Connection): void {
        this.clients.set(connection.clientId, connection);
        this.system(MessageType.ClientJoin, JSON.stringify({ clientId: connection.clientId, detail: client }));
    }
    leave(id: string): void {
        if (this.clients.delete(id))
            this.system(MessageType.ClientLeave, JSON.stringify(id));
    }
}
class Connection extends EventEmitter implements IDocumentDeltaConnection {
    readonly claims: ITokenClaims = { documentId: 'doc', tenantId: 'fake', scopes: [ScopeType.DocRead, ScopeType.DocWrite], user: { id: 'u' }, iat: 0, exp: 0, ver: '1.0' };
    readonly existing = true;
    readonly maxMessageSize = 16384;
    readonly mode = 'write';
    readonly initialMessages: ISequencedDocumentMessage[] = [];
    readonly initialSignals: ISignalMessage[] = [];
    readonly initialClients: ISignalClient[] = [];
    readonly version = '^0.4.0';
    readonly serviceConfiguration: IClientConfiguration = { maxMessageSize: 16384, blockSize: 65436 };
    readonly supportedFeatures = {};
    disposed = false;
    constructor(readonly clientId: string, readonly ordering: Ordering) { super(); }
    submit(messages: IDocumentMessage[]): void {
        if (this.disposed)
            return;
        const first = this.ordering.submitted.length === 0;
        this.ordering.submitted.push(...messages);
        if (first)
            return;
        queueMicrotask(() => {
            for (const message of messages) {
                if (!this.disposed)
                    this.ordering.broadcast({ ...message, clientId: this.clientId });
            }
        });
    }
    submitSignal(): void { }
    dispose(): void {
        this.disposed = true;
        this.ordering.leave(this.clientId);
        this.removeAllListeners();
    }
}
async function until(condition: () => boolean): Promise<void> {
    for (let turn = 0; turn < 2000; turn++) {
        if (condition())
            return;
        await new Promise<void>(resolve => setImmediate(resolve));
    }
    throw new Error('oracle did not settle');
}
async function storageFault(seed: number): Promise<number[]> {
    let remaining = seed % 4 + 1;
    const delays: number[] = [];
    const original = globalThis.setTimeout;
    globalThis.setTimeout = ((callback: (...args: unknown[]) => void, ms?: number, ...args: unknown[]) => {
        delays.push(ms ?? 0);
        return original(callback, 0, ...args);
    }) as typeof setTimeout;
    try {
        const retry = new RetriableDocumentStorageService(Promise.resolve({ ...storage, readBlob: async () => {
                if (remaining-- > 0)
                    throw createGenericNetworkError(['429', '503', 'offline'][seed % 3] ?? 'offline', { canRetry: true, retryAfterMs: (seed % 5) * 250 }, { driverVersion: undefined, endpointReached: seed % 3 !== 2 });
                return new Uint8Array([1, 2, 3]).buffer;
            } }), createChildLogger());
        assert.deepEqual(new Uint8Array(await retry.readBlob('blob')), new Uint8Array([1, 2, 3]));
        return delays;
    }
    finally {
        globalThis.setTimeout = original;
    }
}
export async function runOracle(seed: number) {
    const storageDelays = await storageFault(seed);
    const ordering = new Ordering();
    let index = 0;
    let connection: Connection | undefined;
    const service: IDocumentService = Object.assign(new EventEmitter(), {
        resolvedUrl: resolved,
        connectToStorage: async () => storage,
        connectToDeltaStorage: async () => ({ fetchMessages: (from: number) => {
                let done = false;
                return { read: async () => {
                        if (done)
                            return { done: true as const, value: undefined };
                        done = true;
                        return { done: false as const, value: ordering.log.filter(op => op.sequenceNumber >= from) };
                    } };
            } }),
        connectToDeltaStream: async () => {
            connection = new Connection(`client-1-${++index}`, ordering);
            ordering.join(connection);
            connection.initialMessages.push(...ordering.log);
            return connection;
        },
        dispose: () => { },
    });
    const container = await loadExistingContainer({
        request: { url: 'doc' },
        urlResolver: { resolve: async () => resolved, getAbsoluteUrl: async () => 'doc' },
        documentServiceFactory: { createDocumentService: async () => service, createContainer: async () => { throw new Error('unused'); } },
        codeLoader: { load: async () => ({ module: { fluidExport: createDOProviderContainerRuntimeFactory({ schema: { initialObjects: { map: SharedMap } }, oldestSupportedClient: '2.0.0', runtimeOptionOverrides: { summaryOptions: { summaryConfigOverrides: { state: 'disabled' } } } }) }, details: { package: 'test' } }) },
        configProvider: { getRawConfig: name => name === 'Fluid.Container.ForceWriteConnection' ? true : undefined },
    });
    try {
        await until(() => container.connectionState === 2);
        const fluid = await createFluidContainer<{
            initialObjects: {
                map: typeof SharedMap;
            };
        }>({ container });
        const map = fluid.initialObjects.map;
        const events: string[] = [];
        const delays: number[] = [];
        container.on('connected', () => events.push('connected'));
        container.on('disconnected', () => { events.push('disconnected'); });
        container.on('closed', () => { events.push('closed'); });
        map.set('during', seed);
        await until(() => ordering.submitted.length > 0);
        const codes = [undefined, 400, 401, 403, 404, 429, 500, 503];
        const code = codes[seed % codes.length];
        const retryAfter = (seed % 5) / 4;
        // Only the reconnect timer is virtualized. All ordering, loader and runtime work runs
        // on the actual TS implementation; no model of those algorithms is used here.
        const original = globalThis.setTimeout;
        globalThis.setTimeout = ((callback: (...args: unknown[]) => void, ms?: number, ...args: unknown[]) => {
            if (ms === retryAfter * 1000 && code !== undefined && code !== 403) {
                if (ms > 0)
                    delays.push(ms);
                return original(callback, 0, ...args);
            }
            return original(callback, ms, ...args);
        }) as typeof setTimeout;
        try {
            assert(connection);
            if (code === undefined)
                connection.emit('disconnect', { message: 'socket drop', canRetry: true });
            else
                connection.emit('nack', 'doc', [{ content: { code, type: 'BadRequestError', message: 'fault', retryAfter }, sequenceNumber: 0 }]);
            await until(() => code === 403 ? container.closed : container.connectionState === 2 && container.clientId === 'client-1-2' && !container.isDirty);
        }
        catch (error) {
            console.error({ events, state: container.connectionState, id: container.clientId, dirty: container.isDirty, log: ordering.log, submitted: ordering.submitted });
            throw error;
        }
        finally {
            globalThis.setTimeout = original;
        }
        return { storageDelays, events: [...events], delays: [...delays], state: Object.fromEntries(map.entries()), ops: ordering.submitted.filter(op => op.type === 'op').map(op => JSON.stringify(op)) };
    }
    finally {
        container.dispose();
    }
}

/** One actual ordering-service implementation is used by both loaders. Each replay resets it. */
export async function startOrderingService() {
    let ordering = new Ordering();
    const server = createServer(async (request, response) => {
        try {
            let body = "";
            for await (const chunk of request) body += String(chunk);
            const command = z.object({ method: z.enum(["join", "leave", "submit"]), clientId: z.string(), messages: z.array(z.string()).optional() }).parse(JSON.parse(body));
            if (command.method === "join") ordering.join(new Connection(command.clientId, ordering));
            else if (command.method === "leave") ordering.leave(command.clientId);
            else {
                const connection = ordering.clients.get(command.clientId);
                assert(connection);
                const messages: IDocumentMessage[] = (command.messages ?? []).map(text => JSON.parse(text));
                connection.submit(messages);
                await new Promise<void>(resolve => setImmediate(resolve));
            }
            response.setHeader("content-type", "application/json");
            response.end(JSON.stringify(ordering.log));
        } catch (error) {
            response.statusCode = 500;
            response.end(String(error));
        }
    });
    await new Promise<void>(resolve => server.listen(7090, "127.0.0.1", resolve));
    return {
        reset() { ordering = new Ordering(); },
        async close() {
            server.closeAllConnections();
            await new Promise<void>(resolve => server.close(() => resolve()));
        },
    };
}
