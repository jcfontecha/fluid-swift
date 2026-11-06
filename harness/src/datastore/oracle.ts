import { toFluidHandleInternal } from '@fluidframework/runtime-utils/internal';
import { createRootSummarizerNodeWithGC } from '../../node_modules/@fluidframework/container-runtime/lib/summary/summarizerNode/summarizerNodeWithGc.js';
import { SummaryType, type ISummaryTree } from '@fluidframework/driver-definitions/internal';
import type { ISnapshotTree } from '@fluidframework/driver-definitions/internal';
import { DataStoreMessageType } from '../../node_modules/@fluidframework/datastore/lib/dataStoreRuntime.js';
import { wrapSummaryInChannelsTree } from '../../node_modules/@fluidframework/container-runtime/lib/summary/index.js';
import { addBlobToSummary } from '@fluidframework/runtime-utils/internal';
import type { IFluidHandle } from '@fluidframework/core-interfaces';
import assert from 'node:assert/strict';
import { AttachState } from '@fluidframework/container-definitions/internal';
import { FluidDataStoreRuntime } from '@fluidframework/datastore/internal';
import { MockFluidDataStoreContext } from '@fluidframework/test-runtime-utils/internal';
import { SharedMap, SharedDirectory } from '@fluidframework/map/internal';
import { SharedCounter } from '@fluidframework/counter/internal';
import type { IChannel } from '@fluidframework/datastore-definitions/internal';
import type { IFluidDataStoreContext } from '@fluidframework/runtime-definitions/internal';
export interface Scenario { seed: number }
export async function run({ seed }: Scenario): Promise<string> {
    const wire: unknown[] = [];
    const metadata: unknown[] = [];
    const signalWire: unknown[] = [];
    const context = new MockFluidDataStoreContext('store');
    context.attachState = AttachState.Detached;
    context.clientId = 'client';
    context.IFluidHandleContext = {
        get IFluidHandleContext() { return this; },
        absolutePath: '', isAttached: false, attachGraph() {},
        async resolveHandle() { throw Error('unused'); },
    };
    const submit: IFluidDataStoreContext['submitMessage'] = (type, content, md) => {
        wire.push({ type, content });
        metadata.push(md);
    };
    const submitSignal: IFluidDataStoreContext['submitSignal'] = (type, content, targetClientId) => signalWire.push({ type, content, targetClientId });
    Object.assign(context, { submitSignal, submitMessage: submit, makeLocallyVisible() {}, setChannelDirty() {} });
    const factories = [SharedMap.getFactory(), SharedDirectory.getFactory(), SharedCounter.getFactory()];
    const runtime: FluidDataStoreRuntime = new FluidDataStoreRuntime(context, { get: type => factories.find(f => f.type === type) }, false, async () => runtime);
    const map = runtime.createChannel('map', SharedMap.getFactory().type) as SharedMap;
    const directory = runtime.createChannel('directory', SharedDirectory.getFactory().type) as SharedDirectory;
    const counter = runtime.createChannel('counter', seed % 2 === 0 ? 'counter' : SharedCounter.getFactory().type) as SharedCounter;
    map.set('seed', seed);
    directory.set('seed', seed);
    counter.increment(seed % 17);
    for (let i = 0; i < 8; i++) {
        const key = String((seed * 17 + i * 7) % 11);
        map.set(key, { n: seed - i, text: i % 2 === 0 ? 'lone\ud800' : 'emoji🙂' });
        if ((seed + i) % 3 === 0) map.delete(key);
    }
    map.set('ref', counter.handle);
    for (const channel of [map, directory]) channel.bindToContext();
    runtime.makeVisibleAndAttachGraph();
    const attach = runtime.getAttachSummary().summary;
    runtime.setAttachState(AttachState.Attaching);
    context.attachState = AttachState.Attached;
    runtime.setAttachState(AttachState.Attached);
    counter.increment(9);
    const rolled = wire.pop() as { type: DataStoreMessageType.ChannelOp; content: unknown };
    assert(runtime.rollback);
    runtime.rollback(rolled.type, rolled.content, metadata.pop());
    map.set('counter', counter.handle);
    counter.increment(3);
    directory.set('hello', `value${seed}`);
    const last = wire.pop() as { type: DataStoreMessageType.ChannelOp; content: unknown };
    const lastMetadata = metadata.pop();
    context.connected = false;
    runtime.setConnectionState(false);
    context.connected = true;
    runtime.setConnectionState(true, 'client');
    runtime.reSubmit(last.type, last.content, lastMetadata, false);
    const submitted = [...wire];
    let sequenceNumber = 0;
    for (let i = 0; i < submitted.length; i++) {
        const message = submitted[i] as { type: string; content: unknown };
        runtime.processMessages({ envelope: { type: message.type, clientId: 'client', sequenceNumber: ++sequenceNumber, minimumSequenceNumber: 0, referenceSequenceNumber: 0, timestamp: 0 }, local: true,
            messagesContent: [{ contents: message.content, localOpMetadata: metadata[i], clientSequenceNumber: i + 1 }] });
    }
    runtime.processMessages({ envelope: { type: 'op', clientId: 'other', sequenceNumber: ++sequenceNumber, minimumSequenceNumber: 0, referenceSequenceNumber: 0, timestamp: 0 }, local: false,
        messagesContent: [1, 2].map(incrementAmount => ({ contents: { address: 'counter', contents: { type: 'increment', incrementAmount } }, clientSequenceNumber: incrementAmount, localOpMetadata: undefined })) });
    const signals: unknown[] = [];
    runtime.on('signal', (message, local) => signals.push({ message, local }));
    runtime.submitSignal('cursor', seed, seed % 2 === 0 ? 'target' : undefined);
    runtime.processSignal({ clientId: 'other', type: 'test', content: seed }, false);
    const summary = (await runtime.summarize(true, false)).summary;
    const gc = await runtime.getGCData(true);
    assert.equal(summary.type, SummaryType.Tree);
    const blobs = new Map<string, ArrayBufferLike>();
    function snapshot(tree: ISummaryTree): ISnapshotTree {
        const result: ISnapshotTree = { blobs: {}, trees: {} };
        for (const [key, entry] of Object.entries(tree.tree)) {
            if (entry.type === SummaryType.Tree) result.trees[key] = snapshot(entry);
            else if (entry.type === SummaryType.Blob) {
                assert.equal(typeof entry.content, 'string');
                const id = String(blobs.size);
                blobs.set(id, new TextEncoder().encode(entry.content as string).buffer);
                result.blobs[key] = id;
            } else throw Error('unexpected summary variant');
        }
        return result;
    }
    const reloadContext = new MockFluidDataStoreContext('store', true);
    reloadContext.clientId = 'client';
    reloadContext.attachState = AttachState.Attached;
    reloadContext.baseSnapshot = snapshot(summary as ISummaryTree);
    reloadContext.isLocalDataStore = false;
    reloadContext.IFluidHandleContext = context.IFluidHandleContext;
    reloadContext.storage = { async readBlob(id) { const blob = blobs.get(id); assert(blob); return blob; } };
    const root = createRootSummarizerNodeWithGC({ send() {} }, async () => { throw Error('unused'); }, 0, 0, { gcDisabled: false });
    reloadContext.getCreateChildSummarizerNodeFn = (id, param) => (summarize, gcFn) => root.createChild(summarize, id, param, {}, gcFn);
    Object.assign(reloadContext, { setChannelDirty() {}, submitMessage: submit, addedGCOutboundRoute() {} });
    const reload: FluidDataStoreRuntime = new FluidDataStoreRuntime(reloadContext, { get: type => factories.find(f => f.type === type) }, true, async () => reload);
    reload.processMessages({ envelope: { type: 'op', clientId: 'other', sequenceNumber: ++sequenceNumber, minimumSequenceNumber: 0, referenceSequenceNumber: 0, timestamp: 0 }, local: false,
        messagesContent: [{ contents: { address: 'counter', contents: { type: 'increment', incrementAmount: 7 } }, clientSequenceNumber: 1, localOpMetadata: undefined }] });
    const loadedCounter = await reload.getChannel('counter') as SharedCounter;
    assert.equal(loadedCounter.value, counter.value + 7);
    const stashed = { type: 'op', content: { address: 'counter', contents: { type: 'increment', incrementAmount: 4 } } };
    const stashedMetadata = await reload.applyStashedOp(stashed);
    reload.reSubmit(DataStoreMessageType.ChannelOp, stashed.content, stashedMetadata, false);
    const reloadedSummary = (await reload.summarize(true, false)).summary;
    const reloadedGC = await reload.getGCData(true);
    const late = runtime.createChannel('late', SharedCounter.getFactory().type) as SharedCounter;
    late.increment(2);
    late.bindToContext();
    const attachMessage = wire.at(-1) as { type: string; content: unknown };
    reload.processMessages({ envelope: { type: attachMessage.type, clientId: 'other', sequenceNumber: ++sequenceNumber, minimumSequenceNumber: 0, referenceSequenceNumber: 0, timestamp: 0 }, local: false,
        messagesContent: [{ contents: attachMessage.content, clientSequenceNumber: 1, localOpMetadata: undefined }] });
    const stashContext = new MockFluidDataStoreContext('store', true);
    stashContext.attachState = AttachState.Attached;
    stashContext.IFluidHandleContext = context.IFluidHandleContext;
    Object.assign(stashContext, { makeLocallyVisible() {}, setChannelDirty() {}, addedGCOutboundRoute() {} });
    const stashRuntime: FluidDataStoreRuntime = new FluidDataStoreRuntime(stashContext, { get: type => factories.find(f => f.type === type) }, true, async () => stashRuntime);
    await stashRuntime.applyStashedOp(attachMessage);
    const stashedLate = await stashRuntime.getChannel('late') as SharedCounter;
    assert.equal(stashedLate.value, 2);
    const loadedLate = await reload.getChannel('late') as SharedCounter;
    assert.equal(loadedLate.value, 2);
    const lateResult = await reload.summarize(true, false);
    const lateSummary = lateResult.summary;
    wrapSummaryInChannelsTree(lateResult);
    addBlobToSummary(lateResult, '.component', JSON.stringify({ pkg: JSON.stringify(['test']), summaryFormatVersion: 2, isRootDataStore: true }));
    const fullSummary = lateResult.summary;
    assert.equal(counter.value, seed % 17 + 6);
    assert.equal(map.get('seed'), seed);
    const storedHandle = map.get<IFluidHandle>('counter');
    assert(storedHandle);
    return JSON.stringify({ wire: wire.map(message => ({ type: 'component', contents: { address: 'store', contents: message } })), attach, summary, gc, reloadedSummary, reloadedGC, lateSummary, fullSummary, signals, signalWire, storedHandle: toFluidHandleInternal(storedHandle).absolutePath, handles: [map, directory, counter].map((c: IChannel) => toFluidHandleInternal(c.handle).absolutePath), state: { counter: counter.value, map: map.get('seed'), directory: directory.get('hello') } });
}
