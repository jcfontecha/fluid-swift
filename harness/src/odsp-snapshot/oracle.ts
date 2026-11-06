import type { IBlob, ISnapshot, ISnapshotTree } from '@fluidframework/driver-definitions/internal';
import { MockLogger } from '@fluidframework/telemetry-utils/internal';
import { parseCompactSnapshotResponse } from '../../node_modules/@fluidframework/odsp-driver/lib/compactSnapshotParser.js';
import { convertToCompactSnapshot } from '../../node_modules/@fluidframework/odsp-driver/lib/compactSnapshotWriter.js';
import { ReadBuffer } from '../../node_modules/@fluidframework/odsp-driver/lib/ReadBufferUtils.js';
import { TreeBuilderSerializer } from '../../node_modules/@fluidframework/odsp-driver/lib/WriteBufferUtils.js';
import {
    BlobCore,
    NodeCore,
    TreeBuilder,
    type NodeTypes,
} from '../../node_modules/@fluidframework/odsp-driver/lib/zipItDataRepresentationUtils.js';

// The TS oracle for the compact snapshot codec. Everything here calls the installed 3.11.0
// `@fluidframework/odsp-driver` lib files directly; nothing is reimplemented.

// ---------------------------------------------------------------------------------------------
// Wire shapes shared by the harness and the Swift peer (see PROTOCOL.md, "H10").
// ---------------------------------------------------------------------------------------------

export interface TreeSpec {
    id?: string;
    blobs: Record<string, string>;
    trees: Record<string, TreeSpec>;
    unreferenced?: boolean;
    groupId?: string;
}

export type BlobSpec =
    | { kind: 'buffer'; hex: string }
    | { kind: 'iblob'; contents: string; encoding?: 'utf-8' | 'base64' };

export interface SnapshotSpec {
    snapshotTree: TreeSpec;
    /** A JS `Map`: entry order is write order. */
    blobContents: [string, BlobSpec][];
    ops: unknown[];
    sequenceNumber?: number;
    latestSequenceNumber?: number;
}

/** A tree element for the raw (ZipIt) layer. */
export type RawElement =
    | { k: 'node'; t: 'set' | 'list'; c: RawElement[] }
    | { k: 'num'; v: number | null }
    | { k: 'bool'; v: boolean }
    | { k: 'str'; v: string; d: boolean }
    | { k: 'blob'; hex: string };

export type RawNode = Extract<RawElement, { k: 'node' }>;

/** What `classify` makes of a thrown value; mirrored by the Swift peer's error encoding. */
export type ErrorClass =
    | { kind: 'assert'; code: string }
    | { kind: 'invalidCode'; code: number }
    | { kind: 'bufferParsing'; message: string; nodeType: string; expectedNodeType: string }
    | { kind: 'undefinedAccess' }
    | { kind: 'invalidJSON' }
    | { kind: 'sequenceNumberOutOfRange' }
    | { kind: 'other'; message: string };

export type Outcome = { ok: unknown } | { err: ErrorClass };

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

export function toHex(bytes: Uint8Array): string {
    return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('hex');
}

export function fromHex(hex: string): Uint8Array {
    return new Uint8Array(Buffer.from(hex, 'hex'));
}

/** Fluid's `assert` logs every failure; the fuzzer provokes thousands of them on purpose. */
function quietly<T>(body: () => T): T {
    const log = console.log;
    console.log = () => undefined;
    try {
        return body();
    } finally {
        console.log = log;
    }
}

export function classify(error: unknown): ErrorClass {
    if (error instanceof TypeError) return { kind: 'undefinedAccess' };
    if (error instanceof SyntaxError) return { kind: 'invalidJSON' };
    if (!(error instanceof Error)) return { kind: 'other', message: String(error) };
    const assertion = /^0x[0-9a-f]{3,}$/.exec(error.message);
    if (assertion) return { kind: 'assert', code: error.message };
    const invalid = /^Invalid code: (\d+)$/.exec(error.message);
    if (invalid) return { kind: 'invalidCode', code: Number(invalid[1]) };
    const props = error as Error & { nodeType?: string; expectedNodeType?: string; errorType?: string };
    if (error.message.startsWith('Buffer parsing exception: ') && props.errorType === 'incorrectServerResponse') {
        return {
            kind: 'bufferParsing',
            message: error.message,
            nodeType: String(props.nodeType),
            expectedNodeType: String(props.expectedNodeType),
        };
    }
    return { kind: 'other', message: `${error.constructor.name}: ${error.message}` };
}

function attempt(body: () => unknown): Outcome {
    try {
        return { ok: quietly(body) };
    } catch (error) {
        return { err: classify(error) };
    }
}

/** Builds an own property even for the key `__proto__`, as `JSON.parse` does. */
export function setOwn<T>(target: Record<string, T>, key: string, value: T): void {
    Object.defineProperty(target, key, { value, enumerable: true, writable: true, configurable: true });
}

// ---------------------------------------------------------------------------------------------
// Snapshot layer
// ---------------------------------------------------------------------------------------------

/**
 * `ISnapshot.blobContents` is typed `Map<string, ArrayBuffer>`, but the writer also accepts `IBlob`
 * values at runtime (it branches on `instanceof ArrayBuffer`). That path is part of the contract
 * being ported, so the spec's `iblob` entries are passed through the declared type here.
 */
function buildBlobContents(spec: SnapshotSpec): ISnapshot['blobContents'] {
    const map = new Map<string, ArrayBuffer | Partial<IBlob>>();
    for (const [id, blob] of spec.blobContents) {
        if (blob.kind === 'buffer') {
            const bytes = fromHex(blob.hex);
            map.set(id, bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer);
        } else {
            map.set(id, { contents: blob.contents, encoding: blob.encoding });
        }
    }
    return map as unknown as ISnapshot['blobContents'];
}

export function buildSnapshot(spec: SnapshotSpec): ISnapshot {
    return {
        snapshotTree: spec.snapshotTree as ISnapshotTree,
        blobContents: buildBlobContents(spec),
        ops: spec.ops as ISnapshot['ops'],
        sequenceNumber: spec.sequenceNumber,
        latestSequenceNumber: spec.latestSequenceNumber,
        snapshotFormatV: 1,
    };
}

export function tsWriteSnapshot(spec: SnapshotSpec): Outcome {
    return attempt(() => toHex(convertToCompactSnapshot(buildSnapshot(spec))));
}

/** Fixed key order: `id`, `blobs`, `trees`, `unreferenced`, `groupId`. */
function canonicalTree(tree: ISnapshotTree): Record<string, unknown> {
    const result: Record<string, unknown> = {};
    if (tree.id !== undefined) result.id = tree.id;
    result.blobs = Object.fromEntries(Object.entries(tree.blobs));
    result.trees = Object.fromEntries(Object.entries(tree.trees).map(([name, child]) => [name, canonicalTree(child)]));
    if (tree.unreferenced !== undefined) result.unreferenced = tree.unreferenced;
    if (tree.groupId !== undefined) result.groupId = tree.groupId;
    return result;
}

const MAX_SAFE = Number.MAX_SAFE_INTEGER;

export function tsParseSnapshot(hex: string): Outcome {
    return normalizeTsOutcome(attempt(() => {
        const parsed = parseCompactSnapshotResponse(fromHex(hex), new MockLogger().toTelemetryLogger());
        const sequenceNumber = parsed.sequenceNumber;
        if (sequenceNumber === undefined) throw new Error('parser result has no sequenceNumber');
        // Swift protocol counters are exact integers below 2^53 (ARCHITECTURE §3); TS accepts any number.
        if (!(sequenceNumber <= MAX_SAFE) || (parsed.latestSequenceNumber !== undefined && parsed.latestSequenceNumber > MAX_SAFE)) {
            throw new RangeError('sequenceNumberOutOfRange');
        }
        const canonical: Record<string, unknown> = {
            snapshotTree: canonicalTree(parsed.snapshotTree),
            blobContents: [...parsed.blobContents].map(([id, bytes]) => [id, toHex(new Uint8Array(bytes))]),
            ops: parsed.ops,
            sequenceNumber,
        };
        if (parsed.latestSequenceNumber !== undefined) canonical.latestSequenceNumber = parsed.latestSequenceNumber;
        canonical.snapshotFormatV = parsed.snapshotFormatV;
        canonical.telemetry = {
            slowTreeStructureCount: parsed.telemetryProps.slowTreeStructureCount,
            slowBlobStructureCount: parsed.telemetryProps.slowBlobStructureCount,
            treeStructureCountWithGroupId: parsed.telemetryProps.treeStructureCountWithGroupId,
        };
        return canonical;
    }));
}

/** The TS parser accepting a value Swift deliberately rejects (documented range deviation). */
function normalizeTsOutcome(outcome: Outcome): Outcome {
    if ('err' in outcome && outcome.err.kind === 'other' && outcome.err.message === 'RangeError: sequenceNumberOutOfRange') {
        return { err: { kind: 'sequenceNumberOutOfRange' } };
    }
    return outcome;
}

// ---------------------------------------------------------------------------------------------
// Raw (ZipIt) layer
// ---------------------------------------------------------------------------------------------

function fillNode(target: NodeCore, children: RawElement[]): void {
    for (const child of children) {
        switch (child.k) {
            case 'node':
                fillNode(target.addNode(child.t), child.c);
                break;
            case 'num':
                target.addNumber(child.v === null ? undefined : child.v);
                break;
            case 'bool':
                target.addBool(child.v);
                break;
            case 'str':
                if (child.d) target.addDictionaryString(child.v);
                else target.addString(child.v);
                break;
            case 'blob':
                target.addBlob(fromHex(child.hex));
                break;
        }
    }
}

export function tsWriteTree(root: RawElement[]): Outcome {
    return attempt(() => {
        const builder = new TreeBuilderSerializer();
        fillNode(builder, root);
        return toHex(builder.serialize());
    });
}

function dumpElement(element: NodeTypes): RawElement {
    if (element instanceof NodeCore) {
        return { k: 'node', t: element.type, c: [...element].map(dumpElement) };
    }
    if (element instanceof BlobCore) {
        return { k: 'blob', hex: toHex(element.buffer) };
    }
    if (typeof element === 'number') return { k: 'num', v: element };
    if (typeof element === 'boolean') return { k: 'bool', v: element };
    return { k: 'str', v: element.content, d: element.dictionary };
}

export function tsParseTree(hex: string): Outcome {
    return attempt(() => {
        const { builder } = TreeBuilder.load(new ReadBuffer(fromHex(hex)), new MockLogger().toTelemetryLogger());
        return [...builder].map(dumpElement);
    });
}
