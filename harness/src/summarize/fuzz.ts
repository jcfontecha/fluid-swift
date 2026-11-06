import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { resolve } from 'node:path';
import { mkdirSync, writeFileSync } from 'node:fs';
import { run } from './oracle.js';
import type { ISequencedDocumentMessage } from '@fluidframework/driver-definitions/internal';
import { materialize, responseSchema } from './summary.js';
import { containerOracle } from './container-oracle.js';
const root = resolve(import.meta.dirname, '../../..');
const self = process.argv.includes('--self');
const count = Number(process.argv.find(a => a.startsWith('--seeds='))?.slice(8) ?? 1000);
const plant = process.argv.includes('--plant-divergence');
if (!self) execFileSync('swift', ['build', '--scratch-path', '.build/m3', '--product', 'FluidSummaryPeer'], { cwd: root, stdio: 'inherit' });
const child = self ? undefined : spawn(resolve(root, '.build/m3/debug/FluidSummaryPeer'), [], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = child ? createInterface({ input: child.stdout })[Symbol.asyncIterator]() : undefined;
try {
    async function native(input: object): Promise<string> {
        assert(child && lines);
        child.stdin.write(JSON.stringify(input) + '\n');
        const line = await lines.next();
        assert(!line.done, 'summary peer exited');
        return line.value;
    }
    for (let seed = 0; seed < count; seed++) {
        const expected = JSON.stringify(await run(seed));
        let actual: string;
        if (self) actual = JSON.stringify(await run(seed));
        else {
            assert(child && lines);
            child.stdin.write(JSON.stringify({ seed }) + '\n');
            const line = await lines.next();
            assert(!line.done, 'summary peer exited');
            actual = line.value;
        }
        if (plant) actual = actual.replace('__gc_root', '__wrong_gc_root');
        if (actual !== expected) {
            mkdirSync(resolve(root, 'harness/traces/summarize'), { recursive: true });
            writeFileSync(resolve(root, `harness/traces/summarize/${seed}.json`), JSON.stringify({ seed, expected: JSON.parse(expected), actual: JSON.parse(actual) }, null, 2));
        }
        assert.equal(actual, expected, `summary seed ${seed}`);
        const source = await containerOracle(seed);
        for (const fullTree of [true, false]) {
            const baseline = fullTree ? source.initial : source.full.summary;
            const messages: ISequencedDocumentMessage[] = [];
            for (let index = 0; index < seed % 11; index++) {
                const client = `editor${index % 3}`;
                const editor = await containerOracle(seed, baseline, true, messages, { client, index });
                assert(editor.outbound.length > 0, 'real editor did not submit');
                for (const wire of editor.outbound) {
                    assert(wire.contents);
                    messages.push({ type: 'op', clientId: client, sequenceNumber: messages.length + 1,
                        clientSequenceNumber: index + 1, minimumSequenceNumber: 0,
                        referenceSequenceNumber: wire.referenceSequenceNumber ?? 0, timestamp: 100 + index,
                        contents: JSON.parse(wire.contents) as unknown, metadata: wire.metadata, compression: wire.compression });
                }
            }
            const oracle = await containerOracle(seed, baseline, fullTree, messages);
            const target = { full: oracle.full, gc: oracle.gc, state: oracle.state };
            const twin = self ? await containerOracle(seed, baseline, fullTree, messages) : undefined;
            const loaded = twin ? JSON.stringify({ full: twin.full, gc: twin.gc, state: twin.state }) : await native({ seed, baseline, fullTree, messages });
            const expectedText = JSON.stringify(target);
            if (loaded !== expectedText) {
                mkdirSync(resolve(root, 'harness/traces/summarize'), { recursive: true });
                writeFileSync(resolve(root, `harness/traces/summarize/container-${seed}.json`), JSON.stringify({ seed, baseline, fullTree, messages, expected: target, actual: JSON.parse(loaded) }, null, 2));
            }
            assert.equal(loaded, expectedText, `container summary seed ${seed}, full=${fullTree}`);
            const nativeSummary = materialize(responseSchema.parse(JSON.parse(loaded)).full.summary, baseline);
            const crossTS = await containerOracle(seed, nativeSummary, true);
            const crossExpected = JSON.stringify({ full: crossTS.full, gc: crossTS.gc, state: crossTS.state });
            const crossSwift = self ? await containerOracle(seed, materialize(oracle.full.summary, baseline), true) : undefined;
            const crossActual = crossSwift ? JSON.stringify({ full: crossSwift.full, gc: crossSwift.gc, state: crossSwift.state }) : await native({ seed, baseline: materialize(oracle.full.summary, baseline), fullTree: true });
            assert.equal(crossActual, crossExpected, `cross-load seed ${seed}, full=${fullTree}`);
        }
    }
    console.log(`Summary container + GC ${self ? 'TS self-check' : 'Swift differential'}: ${count} seeds passed`);
} finally { child?.kill(); }
