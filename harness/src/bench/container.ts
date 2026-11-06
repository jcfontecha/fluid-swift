// Benchmark-local adaptation of ../summarize/container-oracle.ts.
// Uses the real 3.11.0 runtime, datastore factories, summaries and op routing.
import assert from 'node:assert/strict';
import { z } from 'zod';
import type { ISequencedDocumentMessage, ISummaryTree, ISnapshotTree } from '@fluidframework/driver-definitions/internal';
import { SummaryType } from '@fluidframework/driver-definitions/internal';
import { SummarizerNodeWithGC } from '../../node_modules/@fluidframework/container-runtime/lib/summary/summarizerNode/summarizerNodeWithGc.js';
import { isFluidHandle, toFluidHandleInternal } from '@fluidframework/runtime-utils/internal';
import { setEntropyContext } from '../entropy.js';
import { AttachState, type IBatchMessage, type IContainerContext, type IContainerStorageService } from '@fluidframework/container-definitions/internal';
import { ContainerRuntime } from '@fluidframework/container-runtime/internal';
import { FluidDataStoreRuntime } from '@fluidframework/datastore/internal';
import { MockDeltaManager, MockAudience, MockQuorumClients } from '@fluidframework/test-runtime-utils/internal';
import { SharedMap, SharedDirectory } from '@fluidframework/map/internal';
import { SharedCounter } from '@fluidframework/counter/internal';
import { SharedCounter as CounterClass } from '../../node_modules/@fluidframework/counter/lib/counter.js';
import { SharedMap as MapClass } from '../../node_modules/@fluidframework/map/lib/map.js';
import { SharedDirectory as DirectoryClass } from '../../node_modules/@fluidframework/map/lib/directory.js';
import { FlushMode, type IFluidDataStoreFactory } from '@fluidframework/runtime-definitions/internal';
export interface EditorAction { client: string; index: number }

export async function containerOracle(seed: number, baseline?: ISummaryTree, fullTree = true, messages: ISequencedDocumentMessage[] = [], edit?: EditorAction, bench?: { keys: number; measure?: boolean }) {
    setEntropyContext(`summary:${seed}`);
    const blobs = new Map<string, ArrayBufferLike>();
    const storage: IContainerStorageService = {
        async getSnapshotTree() { return null; },
        async getVersions() { return []; },
        async createBlob(file) {
            const id = `blob${blobs.size}`;
            blobs.set(id, file);
            return { id };
        },
        async readBlob(id) {
            const value = blobs.get(id);
            assert(value);
            return value;
        },
        async uploadSummaryWithContext() { throw Error('uploads excluded'); },
    };
    function snapshot(summary: ISummaryTree): ISnapshotTree {
        const result: ISnapshotTree = { blobs: {}, trees: {}, ...(summary.unreferenced ? { unreferenced: true } : {}) };
        for (const [name, value] of Object.entries(summary.tree)) {
            if (value.type === SummaryType.Tree) result.trees[name] = snapshot(value);
            else if (value.type === SummaryType.Blob) {
                assert.equal(typeof value.content, 'string');
                const id = `summary${blobs.size}`;
                blobs.set(id, new TextEncoder().encode(value.content as string).buffer);
                result.blobs[name] = id;
            } else if (value.type === SummaryType.Attachment) result.blobs[name] = value.id;
            else throw Error('materialize summary before load');
        }
        return result;
    }
    const deltaManager = new MockDeltaManager();
    deltaManager.lastMessage = { clientId: 'sequencer', clientSequenceNumber: 0, minimumSequenceNumber: 0, referenceSequenceNumber: 0, sequenceNumber: 0, timestamp: 100, type: 'op', contents: undefined };
    if (baseline) {
        const metadata = baseline.tree['.metadata'];
        assert(metadata?.type === SummaryType.Blob && typeof metadata.content === 'string');
        const parsed = z.object({ lastMessage: z.object({ sequenceNumber: z.number() }).optional(), message: z.object({ sequenceNumber: z.number() }).optional() }).parse(JSON.parse(metadata.content));
        deltaManager.lastSequenceNumber = parsed.lastMessage?.sequenceNumber ?? parsed.message?.sequenceNumber ?? 0;
        deltaManager.initialSequenceNumber = deltaManager.lastSequenceNumber;
        deltaManager.lastMessage = undefined;
    }
    const outbound: IBatchMessage[] = [];
    let csn = 0;
    const context = {
        options: {}, id: 'summary-test', clientId: 'reader', clientDetails: { capabilities: { interactive: true } },
        storage, connected: false as boolean, baseSnapshot: baseline ? snapshot(baseline) : undefined, deltaManager,
        quorum: new MockQuorumClients(), audience: new MockAudience(), taggedLogger: { send() {} },
        scope: {}, attachState: (baseline ? AttachState.Attached : AttachState.Detached) as AttachState,
        submitFn(_type, contents, _batch, metadata) {
            outbound.push({ contents: JSON.stringify(contents), metadata });
            return ++csn;
        },
        submitBatchFn(batch) {
            outbound.push(...batch);
            csn += batch.length;
            return csn;
        },
        submitSummaryFn() { throw Error('uploads excluded'); },
        submitSignalFn() {},
        closeFn(error) { if (error) throw error; },
        getLoadedFromVersion() { return undefined; },
        updateDirtyContainerState() {},
        loader: { async resolve() { throw Error('unused'); } },
    } satisfies IContainerContext;
    const factories = [SharedMap.getFactory(), SharedDirectory.getFactory(), SharedCounter.getFactory()];
    const stores: FluidDataStoreRuntime[] = [];
    const factory: IFluidDataStoreFactory = {
        type: 'test', get IFluidDataStoreFactory() { return this; },
        async instantiateDataStore(ctx, existing) {
            const runtime: FluidDataStoreRuntime = new FluidDataStoreRuntime(ctx, { get: type => factories.find(f => f.type === type) }, existing, async () => runtime);
            stores.push(runtime);
            return runtime;
        },
    };
    async function state(runtime: ContainerRuntime, summary: ISummaryTree) {
        const channels = summary.tree['.channels'];
        assert(channels?.type === SummaryType.Tree);
        const result: unknown[] = [];
        for (const id of Object.keys(channels.tree).sort()) {
            await runtime.resolveHandle({ url: `/${id}` });
            const store = stores.find(s => s.id === id);
            assert(store);
            const channelState: unknown[] = [];
            const entry = channels.tree[id];
            assert(entry?.type === SummaryType.Tree);
            const channelTree = entry.tree['.channels'];
            assert(channelTree?.type === SummaryType.Tree);
            for (const channelId of Object.keys(channelTree.tree).sort()) {
                const channel = await store.getChannel(channelId);
                if (channel instanceof CounterClass) channelState.push({ id: channelId, value: channel.value });
                else if (channel instanceof MapClass || channel instanceof DirectoryClass) channelState.push({ id: channelId, entries: [...channel.entries()].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0) });
                else throw Error('unexpected channel');
            }
            result.push({ id, channels: channelState });
        }
        return JSON.parse(JSON.stringify(result, (_key, value: unknown) => {
            if (isFluidHandle(value)) return { type: '__fluid_handle__', url: toFluidHandleInternal(value).absolutePath };
            return value;
        })) as unknown;
    }
    const runtime = await ContainerRuntime.loadRuntime({
        context,
        existing: baseline !== undefined,
        oldestSupportedClient: seed % 2 === 0 ? '2.0.0' : '3.4.0',
        registry: {
            get IFluidDataStoreRegistry() { return this; },
            async get(name) { return name === 'test' ? factory : undefined; },
        },
        provideEntryPoint: async () => ({}),
        runtimeOptions: { enableRuntimeIdCompressor: 'on', flushMode: edit ? FlushMode.Immediate : FlushMode.TurnBased },
    });
    try {
        if (baseline) {
            if (bench?.measure) {
                await runtime.resolveHandle({ url: '/A' });
                const map = await stores.find(s => s.id === 'A')!.getChannel('map') as SharedMap;
                for (const message of messages) {
                    deltaManager.lastMessage = message;
                    deltaManager.lastSequenceNumber = message.sequenceNumber;
                    runtime.process(message, false);
                }
                assert.equal(map.size, 103003);
                assert.equal(map.get("catchup2999"), 2999);
                return map.size;
            }
            for (const message of messages) {
                deltaManager.lastMessage = message;
                deltaManager.lastSequenceNumber = message.sequenceNumber;
                runtime.process(message, false);
            }
            if (edit) {
                context.connected = true;
                context.clientId = edit.client;
                context.audience.setCurrentClientId(edit.client);
                runtime.setConnectionState(true, edit.client);
                await runtime.resolveHandle({ url: '/A' });
                const store = stores.find(s => s.id === 'A');
                assert(store);
                const channel = await store.getChannel(edit.index % 3 === 0 ? 'counter' : edit.index % 3 === 1 ? 'map' : 'directory');
                if (channel instanceof CounterClass) channel.increment(edit.index - 3);
                else if (channel instanceof MapClass || channel instanceof DirectoryClass) channel.set(String(edit.index % 3), { seed, index: edit.index });
                else throw Error('unexpected editor channel');
            }
            const node: unknown = Reflect.get(runtime, 'summarizerNode');
            assert(node instanceof SummarizerNodeWithGC);
            node.startSummary(deltaManager.lastSequenceNumber, { send() {} }, 0);
            const full = await runtime.summarize({ fullTree, trackState: true });
            node.clearSummary();
            return { full: { summary: full.summary, stats: full.stats }, gc: await runtime.getGCData(true), initial: baseline, state: await state(runtime, baseline), outbound };
        }
        const dataStore = await runtime.createDataStore(['test']);
        await dataStore.trySetAlias('root');
        const store = stores[0];
        assert(store);
        const map = store.createChannel('map', SharedMap.getFactory().type) as SharedMap;
        const directory = store.createChannel('directory', SharedDirectory.getFactory().type) as SharedDirectory;
        const counter = store.createChannel('counter', SharedCounter.getFactory().type) as SharedCounter;
        map.set('seed', seed);
        for (let i = 0; i < (bench?.keys ?? 0); i++) map.set(`k${i}`, i);
        directory.set('ref', map.handle);
        counter.increment(seed % 19);
        assert(runtime.idCompressor);
        for (let i = 0; i <= seed % 7; i++) runtime.idCompressor.generateCompressedId();
        for (const channel of [map, directory, counter]) channel.bindToContext();
        store.makeVisibleAndAttachGraph();
        await runtime.createDataStore(['test']);
        const other = stores[1];
        assert(other);
        const otherMap = other.createChannel('map', SharedMap.getFactory().type) as SharedMap;
        otherMap.set('back', map.handle);
        otherMap.bindToContext();
        other.makeVisibleAndAttachGraph();
        if (seed % 2 === 0) map.set('other', otherMap.handle);
        const blob = await runtime.uploadBlob(new TextEncoder().encode(`blob:${seed}`).buffer);
        map.set('blob', blob);
        const initial = runtime.createSummary();
        context.attachState = AttachState.Attaching;
        runtime.setAttachState(AttachState.Attaching);
        context.attachState = AttachState.Attached;
        runtime.setAttachState(AttachState.Attached);
        const full = await runtime.summarize({ fullTree: true, trackState: false });
        const gc = await runtime.getGCData(true);
        return { full: { summary: full.summary, stats: full.stats }, gc, initial, state: await state(runtime, initial), outbound };
    } finally { runtime.dispose(); }
}
