import type { IClient, ISummaryTree } from '@fluidframework/driver-definitions';
import type { IDocumentDeltaConnection, IDocumentService, IDocumentStorageService, ISnapshot } from '@fluidframework/driver-definitions/internal';
import { MockLogger } from '@fluidframework/telemetry-utils/internal';
import { OdspDocumentServiceFactory } from '../../../node_modules/@fluidframework/odsp-driver/lib/odspDocumentServiceFactory.js';
import { OdspDriverUrlResolver } from '../../../node_modules/@fluidframework/odsp-driver/lib/odspDriverUrlResolver.js';
import { createOdspCreateContainerRequest } from '../../../node_modules/@fluidframework/odsp-driver/lib/createOdspCreateContainerRequest.js';
import { createOdspUrl } from '../../../node_modules/@fluidframework/odsp-driver/lib/createOdspUrl.js';
import type { Scenario } from './scenario.js';

export const client: IClient = { mode: 'write', details: { capabilities: { interactive: true }, environment: 'harness' }, permission: [], user: { id: 'user' }, scopes: [] };

const uuidPattern = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

/** Error classes compared between implementations: category, retryability and HTTP status. */
export function errorOutcome(error: unknown): Record<string, unknown> {
    const fields = error as { errorType?: unknown; canRetry?: unknown; statusCode?: unknown; message?: unknown };
    if (fields.errorType === undefined)
        return { error: String(fields.message ?? error) };
    return { errorType: fields.errorType, canRetry: fields.canRetry, statusCode: fields.statusCode };
}

function hex(buffer: ArrayBufferLike): string {
    return Buffer.from(new Uint8Array(buffer)).toString('hex');
}

/** UUIDs the driver generates (createNew blob IDs) become their first-seen index. */
function normalizeUuids(value: unknown): unknown {
    const seen = new Map<string, string>();
    return JSON.parse(JSON.stringify(value).replace(uuidPattern, match => {
        const known = seen.get(match);
        if (known !== undefined)
            return known;
        const name = `UUID-${seen.size}`;
        seen.set(match, name);
        return name;
    }));
}

function snapshotOutcome(snapshot: ISnapshot): unknown {
    return normalizeUuids({
        snapshotTree: snapshot.snapshotTree,
        blobContents: [...snapshot.blobContents].map(([id, buffer]) => [id, hex(buffer)]),
        ops: snapshot.ops,
        sequenceNumber: snapshot.sequenceNumber,
        latestSequenceNumber: snapshot.latestSequenceNumber,
        snapshotFormatV: snapshot.snapshotFormatV,
    });
}

function tokenOptions(kind: string, options: Record<string, unknown>): unknown {
    const request = options.request as { url: string; method: string } | undefined;
    return { kind, refresh: options.refresh, claims: options.claims, tenantId: options.tenantId, siteUrl: options.siteUrl, driveId: options.driveId, itemId: options.itemId, request };
}

/** The summary each scenario uploads, built from JSON so both implementations start from equal values. */
export function uploadSummary(scenario: Scenario): { summary: ISummaryTree; ackHandle: string | undefined; referenceSequenceNumber: number } {
    const latest = scenario.server.sequenceNumber + scenario.server.snapshotOps + scenario.server.restOps + scenario.submits;
    const app: ISummaryTree = { type: 1, tree: { '.metadata': { type: 2, content: '{"summaryFormatVersion":1}' }, data: { type: 2, content: new Uint8Array([0, 128, 255]) } } };
    if (scenario.kind === 'createEmpty')
        return { summary: { type: 1, tree: { '.protocol': protocolSummary(0), '.app': app } }, ackHandle: undefined, referenceSequenceNumber: 0 };
    app.tree.reuse = { type: 3, handleType: 1, handle: '/.channels/old' };
    if (scenario.summary === 'container')
        return { summary: { type: 1, tree: { '.protocol': protocolSummary(latest), '.app': app } }, ackHandle: `ack-${scenario.seed}`, referenceSequenceNumber: latest };
    return { summary: { type: 1, tree: { '.channels': { type: 1, tree: { channel: { type: 2, content: 'text' } }, unreferenced: true } } }, ackHandle: `ack-${scenario.seed}`, referenceSequenceNumber: latest };
}

function protocolSummary(sequenceNumber: number): ISummaryTree {
    return {
        type: 1,
        tree: {
            attributes: { type: 2, content: JSON.stringify({ minimumSequenceNumber: sequenceNumber, sequenceNumber }) },
            quorumMembers: { type: 2, content: '[]' },
            quorumProposals: { type: 2, content: '[]' },
            quorumValues: { type: 2, content: '[]' },
        },
    };
}

/** The detached summary createContainer uploads (sequence number 0, no handles). */
export function createNewSummary(): ISummaryTree {
    return {
        type: 1,
        tree: {
            '.app': { type: 1, tree: { '.metadata': { type: 2, content: '{"createContainerRuntimeVersion":"3.11.0"}' }, '.channels': { type: 1, tree: { root: { type: 2, content: new Uint8Array([1, 2, 3]) } }, groupId: 'g' } } },
            '.protocol': {
                type: 1,
                tree: {
                    attributes: { type: 2, content: '{ "minimumSequenceNumber": 0, "sequenceNumber": 0, "term": 1 }' },
                    quorumMembers: { type: 2, content: '[]' },
                    quorumProposals: { type: 2, content: '[]' },
                    quorumValues: { type: 2, content: '[["code",{"key":"code","value":{"package":"p"},"approvalSequenceNumber":0,"commitSequenceNumber":0,"sequenceNumber":0}]]' },
                },
            },
        },
    };
}

async function waitFor(events: unknown[][], predicate: (event: unknown[]) => boolean): Promise<void> {
    for (let attempt = 0; attempt < 500; attempt++) {
        if (events.some(predicate))
            return;
        await new Promise<void>(resolve => setTimeout(resolve, 2));
    }
    throw new Error('timed out waiting for a socket event');
}

/** The `X-CLP-Compliant-App` resolve header (ClpCompliantAppHeader), when the scenario sets one. */
function clpHeaders(scenario: Scenario): Record<string, boolean> | undefined {
    return scenario.clp === null ? undefined : { 'X-CLP-Compliant-App': scenario.clp };
}

/** Runs one scenario through the real TS OdspDocumentServiceFactory and returns the observable outcome. */
export async function runOracle(scenario: Scenario): Promise<Record<string, unknown>> {
    const out: Record<string, unknown> = {};
    const tokens: unknown[] = [];
    const steps: unknown[] = [];
    out.tokens = tokens;
    out.steps = steps;
    const getStorageToken = async (options: Record<string, unknown>): Promise<string> => {
        tokens.push(tokenOptions('storage', options));
        return options.refresh === true ? 'refreshed' : 'initial';
    };
    const getWebsocketToken = scenario.websocketToken
        ? async (options: Record<string, unknown>): Promise<string> => {
            tokens.push(tokenOptions('websocket', options));
            return 'push-token';
        }
        : undefined;
    // TS shares sockets process-wide; isolating per factory matches the Swift factory-owned registry.
    const factory = new OdspDocumentServiceFactory(getStorageToken as never, getWebsocketToken as never, undefined, { isolateSocketCache: true });
    const resolver = new OdspDriverUrlResolver();
    const logger = new MockLogger();
    let service: IDocumentService | undefined;
    let connection: IDocumentDeltaConnection | undefined;
    const events: unknown[][] = [];
    try {
        if (scenario.kind === 'load') {
            const url = createOdspUrl({ siteUrl: scenario.origin, driveId: scenario.driveId, itemId: scenario.itemId, dataStorePath: '' });
            const resolvedUrl = await resolver.resolve({ url, headers: clpHeaders(scenario) });
            out.resolvedUrl = JSON.parse(JSON.stringify(resolvedUrl));
            out.absoluteUrl = await resolver.getAbsoluteUrl(resolvedUrl, '/store/x');
            service = await factory.createDocumentService(resolvedUrl, logger, false);
        }
        else {
            const request = createOdspCreateContainerRequest(scenario.origin, scenario.driveId, scenario.filePath, scenario.fileName);
            request.headers = { ...request.headers, ...clpHeaders(scenario) };
            out.createRequest = request;
            const resolvedUrl = await resolver.resolve(request);
            out.createResolvedUrl = JSON.parse(JSON.stringify(resolvedUrl));
            if (scenario.hostContext) {
                resolvedUrl.context = `context-${scenario.seed}`;
                resolvedUrl.appName = 'harness-app';
            }
            const summary = scenario.kind === 'create' ? createNewSummary() : undefined;
            service = await factory.createContainer(summary, resolvedUrl, logger, false);
            out.resolvedUrl = JSON.parse(JSON.stringify(service.resolvedUrl));
        }
        out.policies = service.policies;
        const storage: IDocumentStorageService = await service.connectToStorage();
        if (scenario.loadPath === 'versions') {
            const versions = await storage.getVersions(null, 1);
            steps.push(['latestVersion', versions]);
            steps.push(['versionTree', normalizeUuids(await storage.getSnapshotTree(versions[0]))]);
        }
        else {
            const snapshot = await storage.getSnapshot!(undefined);
            steps.push(['snapshot', snapshotOutcome(snapshot)]);
        }
        for (const id of scenario.readBlobs)
            steps.push(['readBlob', id, hex(await storage.readBlob(id))]);
        if (scenario.snapshotTree)
            steps.push(['snapshotTree', normalizeUuids(await storage.getSnapshotTree())]);
        if (scenario.versions > 0)
            steps.push(['versions', await storage.getVersions(scenario.versions === 1 ? null : `snap-${scenario.seed}`, scenario.versions, 'harnessVersions')]);
        const connect = async (): Promise<IDocumentDeltaConnection> => {
            const created = await service!.connectToDeltaStream(client);
            created.on('op', (documentId: string, ops: unknown[]) => events.push(['op', documentId, ops]));
            created.on('signal', (signal: unknown) => events.push(['signal', signal]));
            created.on('nack', (documentId: string, nacks: unknown[]) => events.push(['nack', documentId, nacks]));
            created.on('disconnect', (reason: unknown) => events.push(['disconnect', errorOutcome(reason)]));
            steps.push(['connected', {
                clientId: created.clientId,
                mode: created.mode,
                existing: created.existing,
                version: created.version,
                serviceConfiguration: created.serviceConfiguration,
                checkpointSequenceNumber: created.checkpointSequenceNumber,
                initialMessages: created.initialMessages,
                initialSignals: created.initialSignals,
                initialClients: created.initialClients,
            }]);
            return created;
        };
        if (scenario.connect === 'before')
            connection = await connect();
        const deltaStorage = await service.connectToDeltaStorage();
        const stream = deltaStorage.fetchMessages(scenario.fetchFrom, scenario.fetchTo ?? undefined, undefined, false, 'harness');
        const batches: unknown[] = [];
        for (;;) {
            const result = await stream.read();
            if (result.done)
                break;
            batches.push(result.value);
        }
        steps.push(['deltas', batches]);
        if (scenario.connect === 'after')
            connection = await connect();
        if (connection !== undefined) {
            const latest = scenario.server.sequenceNumber + scenario.server.snapshotOps + scenario.server.restOps;
            for (let index = 1; index <= scenario.submits; index++) {
                connection.submit([{ clientSequenceNumber: index, referenceSequenceNumber: latest, type: 'op', contents: { submit: index } }]);
                await waitFor(events, event => event[0] === 'op' && JSON.stringify(event[2]).includes(`"submit":${index}`));
            }
            if (scenario.signal) {
                connection.submitSignal('{"type":"hello"}', undefined);
                await waitFor(events, event => event[0] === 'signal' && JSON.stringify(event[1]).includes('hello'));
            }
        }
        if (scenario.summary !== 'none') {
            const { summary, ackHandle, referenceSequenceNumber } = uploadSummary(scenario);
            steps.push(['upload', await storage.uploadSummaryWithContext(summary, { proposalHandle: undefined, ackHandle, referenceSequenceNumber })]);
        }
        if (scenario.createBlob !== null) {
            const bytes = Buffer.from(scenario.createBlob, 'hex');
            steps.push(['createBlob', await storage.createBlob(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength))]);
        }
        if (scenario.kind !== 'load')
            out.finalResolvedUrl = JSON.parse(JSON.stringify(service.resolvedUrl));
    }
    catch (error) {
        steps.push(['error', errorOutcome(error)]);
    }
    if (connection !== undefined) {
        connection.dispose();
        await waitFor(events, event => event[0] === 'disconnect');
    }
    service?.dispose();
    out.events = events;
    return out;
}
