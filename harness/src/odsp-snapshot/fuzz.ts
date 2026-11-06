import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { Random } from '../random.js';
import { genGrammarBytes, genRawTree, genShapeSnapshot, genSnapshotSpec, mutate } from './generate.js';
import {
    fromHex,
    toHex,
    tsParseSnapshot,
    tsParseTree,
    tsWriteSnapshot,
    tsWriteTree,
    type Outcome,
    type RawElement,
} from './oracle.js';
import { OraclePeer, outcomeOf, ProcessPeer, type Peer } from './peer.js';

// H10: differential fuzz of the ODSP compact snapshot codec against the installed
// @fluidframework/odsp-driver 3.11.0. See PROTOCOL.md, "H10".

const root = resolve(import.meta.dirname, '../../..');
const self = process.argv.includes('--self');
const scratchPath = process.argv.find(arg => arg.startsWith('--scratch-path='))?.slice('--scratch-path='.length) ?? '.build/h10';
const count = Number(process.argv.find(a => a.startsWith('--seeds='))?.split('=')[1] ?? 1000);

class Mismatch extends Error {
    constructor(
        readonly step: string,
        readonly expected: string,
        readonly actual: string,
        readonly input: unknown,
    ) {
        super(`${step}: Swift and TS disagree`);
    }
}

const stats = new Map<string, number>();

function record(step: string, outcome: Outcome): void {
    const label = 'ok' in outcome ? 'ok' : `err:${outcome.err.kind}${outcome.err.kind === 'assert' ? `:${outcome.err.code}` : ''}`;
    const key = `${step} ${label}`;
    stats.set(key, (stats.get(key) ?? 0) + 1);
}

/** Exact text comparison of the TS outcome against the peer's reply. */
function expectSame(step: string, expected: Outcome, actual: string, input: unknown): void {
    const expectedText = JSON.stringify(expected);
    record(step, expected);
    if (expectedText !== actual) throw new Mismatch(step, expectedText, actual, input);
}

function hexOf(outcome: Outcome): string | undefined {
    return 'ok' in outcome && typeof outcome.ok === 'string' ? outcome.ok : undefined;
}

async function compareParses(peer: Peer, step: string, hex: string): Promise<void> {
    expectSame(`${step}/parseSnapshot`, tsParseSnapshot(hex), await peer.parseSnapshot(hex), hex);
    expectSame(`${step}/parseTree`, tsParseTree(hex), await peer.parseTree(hex), hex);
}

async function compareWrite(peer: Peer, step: string, rootElements: RawElement[]): Promise<string | undefined> {
    const expected = tsWriteTree(rootElements);
    expectSame(`${step}/writeTree`, expected, await peer.writeTree(rootElements), rootElements);
    return hexOf(expected);
}

async function runSeed(seed: number, peer: Peer): Promise<void> {
    const r = new Random(seed);

    // 1. Random ISnapshot values through both writers; every parse direction; mutated bytes.
    const spec = genSnapshotSpec(r);
    const tsWritten = tsWriteSnapshot(spec);
    const swiftWriteText = await peer.writeSnapshot(spec);
    expectSame('snapshot/writeSnapshot', tsWritten, swiftWriteText, spec);
    const tsHex = hexOf(tsWritten);
    if (tsHex !== undefined) {
        const expectedParse = tsParseSnapshot(tsHex);
        expectSame('snapshot/parse TS bytes in Swift', expectedParse, await peer.parseSnapshot(tsHex), tsHex);
        // Swift's bytes parsed by TS must round-trip to the same snapshot as TS's own bytes.
        const swiftHex = hexOf(outcomeOf(swiftWriteText));
        if (swiftHex === undefined) throw new Mismatch('snapshot/swift bytes', 'bytes', swiftWriteText, spec);
        expectSame('snapshot/parse Swift bytes in TS', expectedParse, JSON.stringify(tsParseSnapshot(swiftHex)), swiftHex);
        await compareParses(peer, 'snapshot/tree', tsHex);
        for (let i = 0; i < 4; i++) await compareParses(peer, 'snapshot/mutated', toHex(mutate(r, fromHex(tsHex))));
    }

    // 2. Arbitrary ZipIt trees: writer bytes and tree structure in both directions.
    const raw = genRawTree(r);
    const rawHex = await compareWrite(peer, 'raw', raw);
    if (rawHex !== undefined) {
        await compareParses(peer, 'raw', rawHex);
        await compareParses(peer, 'raw/mutated', toHex(mutate(r, fromHex(rawHex))));
    }

    // 3. Hand-shaped snapshots: every reader path, valid and malformed.
    const shape = genShapeSnapshot(r);
    const shapeHex = await compareWrite(peer, 'shape', shape);
    if (shapeHex !== undefined) {
        await compareParses(peer, 'shape', shapeHex);
        for (let i = 0; i < 2; i++) await compareParses(peer, 'shape/mutated', toHex(mutate(r, fromHex(shapeHex))));
    }

    // 4. Every marker of the grammar written directly, including the ones the TS writer never emits.
    await compareParses(peer, 'grammar', toHex(genGrammarBytes(r)));
}

if (!self) {
    execFileSync('swift', ['build', '--scratch-path', scratchPath, '--product', 'FluidOdspSnapshotPeer', '-c', 'release'], {
        cwd: root,
        stdio: 'inherit',
    });
}
const peer: Peer = self ? new OraclePeer() : new ProcessPeer(resolve(root, scratchPath, 'release/FluidOdspSnapshotPeer'));
let seed = 0;
try {
    for (; seed < count; seed++) {
        await runSeed(seed, peer);
        if ((seed + 1) % 100 === 0) console.log(`${seed + 1} seeds passed`);
    }
    console.log(`${self ? 'TS self-check' : 'Swift differential'}: ${count} seeds passed in all three directions`);
    for (const [key, n] of [...stats].sort(([a], [b]) => a.localeCompare(b))) console.log(`  ${key}: ${n}`);
    // A run that never reaches successful parses proves nothing.
    const parsedOk = stats.get('snapshot/parse TS bytes in Swift ok') ?? 0;
    if (count >= 100 && parsedOk < count / 2) throw new Error(`generator regression: only ${parsedOk} snapshots parsed`);
} catch (error) {
    mkdirSync(resolve(root, 'harness/traces/odsp-snapshot'), { recursive: true });
    const detail = error instanceof Mismatch ? { step: error.step, expected: error.expected, actual: error.actual, input: error.input } : {};
    writeFileSync(resolve(root, `harness/traces/odsp-snapshot/${seed}.json`), JSON.stringify({ seed, error: String(error), ...detail }, null, 2));
    console.error(error instanceof Mismatch ? `seed ${seed}: ${error.step}\n  expected ${error.expected.slice(0, 600)}\n  actual   ${error.actual.slice(0, 600)}` : error);
    process.exitCode = 1;
} finally {
    peer.close();
}
