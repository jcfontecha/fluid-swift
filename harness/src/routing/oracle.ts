import { setEntropyContext } from '../entropy.js';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { AttachState } from '@fluidframework/container-definitions/internal';
import type { OpaqueJsonDeserialized, IFluidHandleContext } from '@fluidframework/core-interfaces/internal';
import { ContainerRuntime } from '../../node_modules/@fluidframework/container-runtime/lib/containerRuntime.js';
import { loadBlobManagerLoadInfo } from '../../node_modules/@fluidframework/container-runtime/lib/blobManager/blobManagerSnapSum.js';
import { BlobManager, type BlobHandle, type IPendingBlobs } from '../../node_modules/@fluidframework/container-runtime/lib/blobManager/blobManager.js';
import { SignalTelemetryManager } from '../../node_modules/@fluidframework/container-runtime/lib/signalTelemetryProcessing.js';
import { validateMinimumVersionForCollab } from '../../node_modules/@fluidframework/runtime-utils/lib/compatibilityBase.js';
import { getMinVersionForCollabDefaults, validateRuntimeOptions } from '../../node_modules/@fluidframework/container-runtime/lib/containerCompatibility.js';
import { ChannelCollection } from '../../node_modules/@fluidframework/container-runtime/lib/channelCollection.js';
import type { IRuntimeMessagesContent } from '@fluidframework/runtime-definitions/internal';
import { Outbox } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/outbox.js';
import { PendingStateManager } from '../../node_modules/@fluidframework/container-runtime/lib/pendingStateManager.js';
import { OpGroupingManager } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/opGroupingManager.js';
import { OpCompressor } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/opCompressor.js';
import { OpSplitter } from '../../node_modules/@fluidframework/container-runtime/lib/opLifecycle/opSplitter.js';
import { CompressionAlgorithms } from '../../node_modules/@fluidframework/container-runtime/lib/compressionDefinitions.js';
import type { LocalContainerRuntimeMessage } from '../../node_modules/@fluidframework/container-runtime/lib/messageTypes.js';
export interface Command {
    kind: string;
    value: Record<string, unknown>;
}
export interface Scenario {
    seed: number;
    uuids: string[];
    detached: boolean;
    pending: boolean;
    commands: Command[];
}
export function uuids(seed: number): string[] {
    return Array.from({ length: 256 }, (_, index) => {
        const bytes = createHash('sha256').update(`h4:${seed}:${index}:0`).digest();
        bytes[6] = ((bytes[6] ?? 0) & 15) | 64;
        bytes[8] = ((bytes[8] ?? 0) & 63) | 128;
        const hex = bytes.subarray(0, 16).toString('hex');
        return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    });
}
export async function run(s: Scenario): Promise<string> {
    setEntropyContext(`h3:${s.seed}`);
    const previousNow = Date.now;
    let now = 1000;
    Date.now = () => now;
    const results: unknown[] = [];
    const wire: {
        localId: string;
        blobId: string;
    }[] = [];
    const storage = new Map<string, ArrayBufferLike>();
    const handles: BlobHandle[] = [];
    const controllers: AbortController[] = [];
    let deferred = false;
    const uploads: (() => void)[] = [];
    const runtime = Object.assign(new EventEmitter(), { attachState: s.detached ? AttachState.Detached : AttachState.Attached, baseLogger: { send() { } }, disposed: false });
    const route: IFluidHandleContext = {
        get IFluidHandleContext() { return route; },
        absolutePath: '', isAttached: true, attachGraph() { },
        async resolveHandle() { throw Error('unused'); },
    };
    function manager(pendingBlobs?: IPendingBlobs, blobManagerLoadInfo: {
        ids?: string[];
        redirectTable?: [
            string,
            string
        ][];
    } = {}): BlobManager {
        return new BlobManager({ routeContext: route, blobManagerLoadInfo, runtime,
            createBlobPayloadPending: s.pending, pendingBlobs,
            storage: {
                async createBlob(bytes) {
                    const id = `s${Buffer.from(bytes).toString('base64')}`;
                    storage.set(id, bytes);
                    if (deferred)
                        await new Promise<void>(resolve => uploads.push(resolve));
                    return { id, minTTLInSeconds: 10 };
                },
                async readBlob(id) {
                    const bytes = storage.get(id);
                    if (!bytes)
                        throw Error('missing storage');
                    return bytes;
                },
            },
            sendBlobAttachMessage(localId, blobId) { wire.push({ localId, blobId }); },
            blobRequested() { }, isBlobDeleted() { return false; },
        });
    }
    let blobs = manager();
    const record = (destination: string, value: unknown) => results.push({ destination, value });
    const channel: ChannelCollection = Object.create(ChannelCollection.prototype);
    const contexts = new Map(['a', 'b', ''].map(id => [id, {
            isLoaded: false,
            processMessages(value: unknown) { record(id, value); },
            processSignal(value: unknown, local: boolean) { record(id, { signal: value, local }); },
        }]));
    Object.defineProperties(channel, {
        contexts: { value: contexts },
        checkAndLogIfDeleted: { value: (address: string) => address === 'deleted' },
        gcNodeUpdated: { value() { } },
        parentContext: { value: { addedGCOutboundRoute() { } } },
        mc: { value: { logger: { sendTelemetryEvent() { } } } },
    });
    const cr: ContainerRuntime = Object.create(ContainerRuntime.prototype);
    Object.defineProperties(cr, {
        channelCollection: { value: { processMessages: (value: Parameters<ChannelCollection['processMessages']>[0]) => {
                    if (value.envelope.type === 'component')
                        channel['processChannelMessages'](value);
                    else
                        record('channels', value);
                }, processSignal: channel.processSignal.bind(channel) } },
        blobManager: { get: () => blobs },
        garbageCollector: { value: { processMessages: (...args: unknown[]) => record('GC', args) } },
        documentsSchemaController: { value: { processDocumentSchemaMessages: (...args: unknown[]) => record('schema', args) } },
        processIdCompressorMessages: { value: (...args: unknown[]) => record('idAllocation', args) },
        updateDocumentDirtyState: { value() {} },
        useDeltaManagerOpsProxy: { value: false },
        closeFn: { value: () => record('close', null) },
        clientId: { value: 'self' },
        signalTelemetryManager: { value: new SignalTelemetryManager() },
        mc: { value: { logger: { sendTelemetryEvent() { }, sendPerformanceEvent() { }, sendErrorEvent() { } } } },
        consecutiveReconnects: { value: 0 },
        extensions: { value: new Map([['presence', { extension: { processSignal: (...args: unknown[]) => record('extension', args) } }]]) },
        emit: { value: (event: string, ...args: unknown[]) => record(event, args) },
    });
    const logger = { send() { } };
    let csn = 0;
    const outbox = new Outbox({
        shouldSend: () => true,
        pendingStateManager: new PendingStateManager({ connected: () => true, clientId: () => 'self', isActiveConnection: () => true, isAttached: () => true, applyStashedOp: async () => undefined, reSubmitBatch() { } }, undefined, logger),
        submitBatchFn: batch => {
            record('outbound', batch);
            csn += batch.length;
            return csn;
        },
        legacySendBatchFn() { throw Error('legacy'); },
        config: { compressionOptions: { minimumBatchSizeInBytes: Infinity, compressionAlgorithm: CompressionAlgorithms.lz4 }, maxBatchSizeInBytes: 1000000 },
        compressor: new OpCompressor(logger),
        splitter: new OpSplitter([], undefined, 100000, 1000000, logger),
        groupingManager: new OpGroupingManager({ groupedBatchingEnabled: true }, logger),
        logger, getCurrentSequenceNumbers: () => ({ referenceSequenceNumber: 0, clientSequenceNumber: csn }),
        reSubmit() { throw Error('reentrant'); }, opReentrancy: () => false, generateIdAllocationOp: () => undefined,
    });
    const settle = async () => {
        for (let i = 0; i < 20; i++)
            await Promise.resolve();
    };
    try {
        for (const command of s.commands) {
            const v = command.value;
            try {
                switch (command.kind) {
                    case 'batch': {
                        const messages = (v.ops as { type: string; contents: unknown }[]).map((op, index) => ({
                            message: { type: op.type, contents: op.contents, sequenceNumber: 100, clientSequenceNumber: index + 1, minimumSequenceNumber: 0, referenceSequenceNumber: 0, clientId: 'peer', timestamp: 10 },
                            localOpMetadata: index,
                        }));
                        cr['processInboundMessages'](messages, { batchStart: true, batchEnd: true }, false, false, true, Boolean(v.grouped));
                        break;
                    }
                    case 'outbound': {
                        for (const op of v.ops as LocalContainerRuntimeMessage[])
                            outbox.submit({ runtimeOp: op, referenceSequenceNumber: 0 });
                        outbox.flush();
                        break;
                    }
                    case 'compat': {
                        const version = String(v.version);
                        validateMinimumVersionForCollab(version);
                        validateRuntimeOptions(version, { createBlobPayloadPending: v.pending === true ? true : undefined });
                        record('compat', getMinVersionForCollabDefaults(version));
                        break;
                    }
                    case 'reloadSummary': {
                        const summary = blobs.summarize().summary;
                        if (summary.type !== 1)
                            throw Error('not tree');
                        const snapshotBlobs: Record<string, string> = {};
                        let table = '[]';
                        for (const [name, entry] of Object.entries(summary.tree)) {
                            if (entry.type === 4) snapshotBlobs[name] = entry.id;
                            else if (name === '.redirectTable' && entry.type === 2 && typeof entry.content === 'string') {
                                snapshotBlobs[name] = 'redirectBlob';
                                table = entry.content;
                            }
                        }
                        const info = await loadBlobManagerLoadInfo({
                            attachState: runtime.attachState,
                            baseSnapshot: { id: 'root', blobs: {}, trees: { '.blobs': { id: 'blobs', blobs: snapshotBlobs, trees: {} } } },
                            storage: {
                                readBlob: async () => new TextEncoder().encode(table).buffer,
                                getSnapshotTree: async () => null,
                                getVersions: async () => [],
                                createBlob: async () => { throw Error('unused createBlob'); },
                                uploadSummaryWithContext: async () => { throw Error('unused uploadSummary'); },
                            },
                        });
                        blobs = manager(undefined, info);
                        break;
                    }
                    case 'route': {
                        const envelope = { type: String(v.type), timestamp: 10, sequenceNumber: 20, clientId: 'peer', clientSequenceNumber: 1, minimumSequenceNumber: 0, referenceSequenceNumber: 0, metadata: v.metadata };
                        const contents: IRuntimeMessagesContent[] = (v.contents as unknown[]).map((contents, index) => ({ contents, localOpMetadata: index, clientSequenceNumber: index + 1 }));
                        cr['validateAndProcessRuntimeMessages'](envelope as Parameters<ContainerRuntime['validateAndProcessRuntimeMessages']>[0], contents, Boolean(v.local), Boolean(v.saved));
                        break;
                    }
                    case 'signal': {
                        const envelope = { ...(v.address === undefined ? {} : { address: String(v.address) }), contents: { type: 'cursor', content: v.payload as OpaqueJsonDeserialized<unknown> } };
                        const target = v.target === undefined ? undefined : String(v.target);
                        if (target === undefined)
                            cr['signalTelemetryManager'].applyTrackingToBroadcastSignalEnvelope(envelope);
                        record('signalWire', { envelope, ...(target === undefined ? {} : { target }) });
                        cr.processSignal({ clientId: v.client === 'server' ? null : String(v.client ?? 'peer'), content: envelope, ...(target === undefined ? {} : { targetClientId: target }) }, Boolean(v.local));
                        break;
                    }
                    case 'create': {
                        setEntropyContext(`h4:${s.seed}:${handles.length}`);
                        const controller = new AbortController();
                        controllers.push(controller);
                        const promise = blobs.createBlob(Uint8Array.from(v.bytes as number[]).buffer, controller.signal);
                        await settle();
                        if (!s.pending && !s.detached) {
                            const m = wire.at(-1);
                            if (!m)
                                throw Error('no attach');
                            blobs.processBlobAttachMessage({ metadata: m } as Parameters<BlobManager['processBlobAttachMessage']>[0], true);
                        }
                        const h = await promise as BlobHandle;
                        handles.push(h);
                        record('handle', { path: h.absolutePath, payloadPending: h.payloadPending, payloadState: h.payloadState });
                        break;
                    }
                    case 'defer':
                        deferred = Boolean(v.enabled);
                        break;
                    case 'finish':
                        uploads.shift()?.();
                        await settle();
                        break;
                    case 'abort':
                        controllers[Number(v.index)]?.abort();
                        await settle();
                        break;
                    case 'share':
                        handles[Number(v.index)]?.sharePayload();
                        await settle();
                        break;
                    case 'attach':
                        handles[Number(v.index)]?.attachGraph();
                        await settle();
                        break;
                    case 'ack': {
                        const m = wire[Number(v.index)];
                        if (!m)
                            throw Error('no attach');
                        blobs.processBlobAttachMessage({ metadata: m } as Parameters<BlobManager['processBlobAttachMessage']>[0], Boolean(v.local));
                        await settle();
                        break;
                    }
                    case 'remote':
                        blobs.processBlobAttachMessage({ metadata: v } as Parameters<BlobManager['processBlobAttachMessage']>[0], false);
                        break;
                    case 'resubmit': {
                        const m = wire[Number(v.index)];
                        blobs.reSubmit(m);
                        await settle();
                        break;
                    }
                    case 'time':
                        now = Number(v.now);
                        break;
                    case 'restore':
                        blobs = manager(blobs.getPendingBlobs());
                        break;
                    case 'resume':
                        void blobs.sharePendingBlobs();
                        await settle();
                        break;
                    case 'patch':
                        blobs.patchRedirectTable(new Map(v.entries as [
                            string,
                            string
                        ][]));
                        break;
                    case 'sweep':
                        record('sweep', blobs.deleteSweepReadyNodes(v.routes as string[]));
                        break;
                    case 'read': {
                        const id = String(v.id);
                        record('read', Array.from(new Uint8Array(await blobs.getBlob(id, false))));
                        break;
                    }
                    default: throw Error('bad command');
                }
            }
            catch {
                record('error', command.kind);
            }
            await settle();
            record('state', { wire: wire.map(metadata => ({ type: 'blobAttach', metadata })), summary: blobs.summarize(), gc: blobs.getGCData(), pending: blobs.getPendingBlobs() ?? null, outstanding: blobs.hasOutstandingBlobWork, handles: handles.map(h => ({ path: h.absolutePath, payloadState: h.payloadState, failed: h.payloadShareError !== undefined, isAttached: h.isAttached })) });
        }
        return JSON.stringify(results);
    }
    finally {
        Date.now = previousNow;
    }
}
