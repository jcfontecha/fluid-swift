import "./determinism.js";
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { readFileSync, writeFileSync } from 'node:fs';
import { SharedMap } from '@fluidframework/map/internal';
import { TextSegment } from '../../node_modules/@fluidframework/merge-tree/lib/textSegment.js';
import { SharedString } from '@fluidframework/sequence/internal';
import { MockFluidDataStoreRuntime, MockObjectStorageService } from '@fluidframework/test-runtime-utils/internal';
import { IdCompressor } from '../../node_modules/@fluidframework/id-compressor/lib/idCompressor.js';
import { containerOracle } from './container.js';

const name = process.argv[2] ?? 'string-10000';
const runtime = () => new MockFluidDataStoreRuntime({ clientId: 'attached' });
let state = 0x12345678;
function next(bound: number) {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state % bound;
}
function message(contents: unknown, sequenceNumber: number, clientId = 'remote') {
    return { contents, type: 'op', clientId, sequenceNumber, referenceSequenceNumber: sequenceNumber - 1,
        minimumSequenceNumber: Math.max(0, sequenceNumber - 64), clientSequenceNumber: sequenceNumber, timestamp: 0 };
}
async function measure(count: number, body: () => unknown | Promise<unknown>) {
    const setupPeakRSSBytes = process.resourceUsage().maxRSS * 1024;
    const start = performance.now();
    const checksum = await body();
    const ms = performance.now() - start;
    console.log(JSON.stringify({ workload: name, count, ms, peakRSSBytes: process.resourceUsage().maxRSS * 1024, setupPeakRSSBytes, checksum }));
}
if (name.startsWith('string-') || name === 'typing') {
    const size = name === 'typing' ? 1000000 : Number(name.slice(7));
    const s = SharedString.getFactory().create(runtime(), 'local');
    s.insertText(0, 'x'.repeat(size));
    const client = Reflect.get(s, 'client');
    client.startOrUpdateCollaboration('attached');
    const count = name === 'typing' ? 100 : 3000;
    await measure(count, () => {
        for (let i = 1; i <= count; i++) {
            const pos = next(s.getLength() - 2);
            if (name === 'typing') {
                const op = client.insertSegmentLocal(pos, new TextSegment('z'));
                client.applyMsg(message(op, i, 'attached'));
            } else {
                const op = i % 3 === 0 ? { type: 0, pos1: pos, seg: 'z' }
                    : i % 3 === 1 ? { type: 1, pos1: pos, pos2: pos + 1 }
                    : { type: 2, pos1: pos, pos2: pos + 1, props: { bold: true } };
                Reflect.get(s, 'processMessagesCore').call(s, { envelope: message(op, i, `remote${i % 16}`), local: false, messagesContent: [{ contents: op, clientSequenceNumber: i, localOpMetadata: undefined }] });
            }
        }
        assert.equal(s.getLength(), size + (name === 'typing' ? count : 0));
        return s.getLength();
    });
} else if (name === 'map-ops') {
    const map = SharedMap.getFactory().create(runtime(), 'map');
    await measure(10000, () => {
        for (let i = 1; i <= 10000; i++) {
            const op = i % 2 === 1
                ? { type: 'set', key: `k${Math.floor(i / 2)}`, value: { type: 'Plain', value: i } }
                : { type: 'delete', key: `k${Math.floor((i - 1) / 2)}` };
            Reflect.get(map, 'processMessagesCore').call(map, { envelope: message(op, i), local: false, messagesContent: [{ contents: op, clientSequenceNumber: i, localOpMetadata: undefined }] });
        }
        assert.equal(map.size, 0);
        return map.size;
    });
} else if (name === 'map-summary' || name === 'map-load') {
    const map = SharedMap.getFactory().create(runtime(), 'map');
    for (let i = 0; i < 100000; i++) map.set(`k${i}`, i);
    const summarize = () => map.getAttachSummary().summary;
    if (name === 'map-summary') await measure(100000, () => Object.keys(summarize().tree).length);
    else {
        const summary = summarize();
        const blobs = Object.fromEntries(Object.entries(summary.tree).map(([k, v]) => [k, Reflect.get(v, 'content')]));
        await measure(100000, async () => {
            const loaded = SharedMap.getFactory().create(runtime(), 'loaded');
            await Reflect.get(loaded, 'loadCore').call(loaded, new MockObjectStorageService(blobs));
            assert.equal(loaded.size, 100000);
            return loaded.size;
        });
    }
} else if (name === 'ids') {
    const c = new IdCompressor('00000000-0000-4000-8000-000000000001' as never, undefined, 2);
    await measure(100000, () => {
        let total = 0;
        for (let batch = 0; batch < 100; batch++) {
            const ids = Array.from({ length: 1000 }, () => c.generateCompressedId());
            c.finalizeCreationRange(c.takeNextCreationRange());
            for (const id of ids) total += c.normalizeToSessionSpace(c.normalizeToOpSpace(id), c.localSessionId);
        }
        return total;
    });
} else if (name === 'generate') {
    const result = await containerOracle(42, undefined, true, [], undefined, { keys: 100000 });
    assert(typeof result !== 'number');
    const edit = await containerOracle(42, result.initial, true, [], { client: 'remote', index: 1 });
    assert(typeof edit !== 'number');
    const wire = edit.outbound.at(-1)!;
    const template = JSON.parse(wire.contents!);
    console.error('Container op template:', JSON.stringify(template));
    const messages = Array.from({ length: 3000 }, (_, i) => {
        const op = structuredClone(template);
        op.contents.contents.content.contents.key = `catchup${i}`;
        op.contents.contents.content.contents.value = { type: 'Plain', value: i };
        return message(op, i + 1);
    });
    writeFileSync(new URL('../../../Benchmarks/container.json', import.meta.url), JSON.stringify({ summary: result.initial, messages }));
} else if (name === 'container') {
    const fixture = JSON.parse(readFileSync(new URL('../../../Benchmarks/container.json', import.meta.url), 'utf8'));
    await measure(fixture.messages.length, () => containerOracle(42, fixture.summary, true, fixture.messages, undefined, { keys: 0, measure: true }));
} else throw Error(`Unknown workload ${name}`);
