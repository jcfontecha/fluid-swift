import { Random } from '../random.js';
import { setOwn, toHex, type BlobSpec, type RawElement, type RawNode, type SnapshotSpec, type TreeSpec } from './oracle.js';

// Seeded generators for the compact snapshot differential. Every generator is a pure function of
// its `Random`, so a failing seed reproduces exactly.

function chance(r: Random, probability: number): boolean {
    return r.int(10000) < probability * 10000;
}

function bytesOf(r: Random, length: number): Uint8Array {
    const bytes = new Uint8Array(length);
    for (let i = 0; i < length; i++) bytes[i] = r.int(256);
    return bytes;
}

// ---------------------------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------------------------

const NAME_POOL = [
    'content', 'header', 'body', '.channels', '.protocol', '.app', '.metadata', 'attributes', 'gc', 'a', 'z',
    '1', '2', '10', '0', '4294967294', '4294967295', '__proto__', 'constructor', 'toString', 'hasOwnProperty',
    'é', '日本語', '😀', 'á', '', ' ', 'name', 'children', 'value', 'id', 'data', 'groupId', 'unreferenced',
];

const ALPHABET = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/-_.';

function word(r: Random, max = 12): string {
    let text = '';
    const length = 1 + r.int(max);
    for (let i = 0; i < length; i++) text += ALPHABET.charAt(r.int(ALPHABET.length));
    return text;
}

/** Arbitrary text: ASCII, BMP, astral, empty, long, occasionally with a lone surrogate. */
export function text(r: Random): string {
    switch (r.int(12)) {
        case 0: return '';
        case 1: return 'héllo wörld';
        case 2: return '日本語のテキスト';
        case 3: return 'astral 😀🎉 pair';
        case 4: return word(r, 300);
        case 5: return 'a'.repeat(r.pick([254, 255, 256, 257, 300]));
        case 6: return `lone${String.fromCharCode(0xd800 + r.int(0x400))}tail`;
        case 7: return `low${String.fromCharCode(0xdc00 + r.int(0x400))}`;
        default: return word(r);
    }
}

function name(r: Random): string {
    return chance(r, 0.55) ? r.pick(NAME_POOL) : text(r);
}

// ---------------------------------------------------------------------------------------------
// Snapshot specs
// ---------------------------------------------------------------------------------------------

function genTree(r: Random, depth: number, root: boolean): TreeSpec {
    const tree: TreeSpec = { blobs: {}, trees: {} };
    if (root) {
        if (!chance(r, 0.03)) tree.id = chance(r, 0.1) ? '' : word(r, 20);
    } else if (chance(r, 0.05)) {
        tree.id = word(r, 8); // subtree ids are not serialized
    }
    const wide = root && chance(r, 0.06);
    const trees = wide ? 260 + r.int(60) : depth > 0 ? r.int(5) : 0;
    const blobs = wide ? r.int(40) : r.int(5);
    for (let i = 0; i < trees; i++) {
        const key = wide ? `wide${i}-${word(r, 3)}` : name(r);
        setOwn(tree.trees, key, genTree(r, depth - 1, false));
    }
    for (let i = 0; i < blobs; i++) {
        const key = wide ? `wblob${i}` : name(r);
        setOwn(tree.blobs, key, word(r, 30));
    }
    if (chance(r, 0.25)) tree.unreferenced = chance(r, 0.95);
    if (chance(r, 0.2)) tree.groupId = chance(r, 0.15) ? '' : `G${r.int(6)}`;
    return tree;
}

function genBase64Variant(r: Random, bytes: Uint8Array): string {
    const standard = Buffer.from(bytes).toString('base64');
    switch (r.int(7)) {
        case 0: return standard.replace(/=+$/, '');
        case 1: return standard.replace(/\+/g, '-').replace(/\//g, '_');
        case 2: return standard.replace(/(.{4})/g, '$1\n');
        case 3: return `${standard}!!`;
        case 4: return `  ${standard}  `;
        case 5: return `${standard}=A==AAAA`;
        default: return standard;
    }
}

function genBlob(r: Random): BlobSpec {
    switch (r.int(10)) {
        case 0: return { kind: 'buffer', hex: '' };
        case 1: return { kind: 'buffer', hex: toHex(bytesOf(r, 1 + r.int(10))) };
        case 2: return { kind: 'buffer', hex: toHex(bytesOf(r, r.pick([254, 255, 256, 257, 65535, 65536, 65537]))) };
        case 3: return { kind: 'buffer', hex: toHex(Buffer.from(JSON.stringify({ k: text(r), n: r.int(1000) }))) };
        case 4: return { kind: 'iblob', contents: text(r) };
        case 5: return { kind: 'iblob', contents: text(r), encoding: 'utf-8' };
        case 6: return { kind: 'iblob', contents: genBase64Variant(r, bytesOf(r, r.int(60))), encoding: 'base64' };
        case 7: return { kind: 'iblob', contents: '', encoding: 'base64' };
        case 8: return { kind: 'buffer', hex: toHex(bytesOf(r, 70000)) };
        default: return { kind: 'buffer', hex: toHex(bytesOf(r, 1 + r.int(2000))) };
    }
}

function randJSON(r: Random, depth: number): unknown {
    switch (r.int(depth > 2 ? 6 : 9)) {
        case 0: return null;
        case 1: return chance(r, 0.5);
        case 2: return r.int(100000) - 500;
        case 3: return r.pick([0.5, 1e21, 1.5e-7, 123456789.125, 4294967296, 9007199254740991]);
        case 4:
        case 5: return text(r);
        case 6: return Array.from({ length: r.int(4) }, () => randJSON(r, depth + 1));
        default: {
            const object: Record<string, unknown> = {};
            for (let i = 0; i < r.int(4); i++) object[word(r, 6)] = randJSON(r, depth + 1);
            return object;
        }
    }
}

function genOps(r: Random, first: number): unknown[] {
    const count = chance(r, 0.35) ? 0 : 1 + r.int(6);
    const ops: unknown[] = [];
    for (let i = 0; i < count; i++) {
        const op: Record<string, unknown> = {
            clientId: chance(r, 0.2) ? null : word(r, 8),
            clientSequenceNumber: r.int(50) - 1,
            contents: randJSON(r, 0),
            minimumSequenceNumber: r.int(first + 1),
            referenceSequenceNumber: r.int(first + 1),
            sequenceNumber: first + i,
            timestamp: 1623883807452 + r.int(100000),
            type: r.pick(['op', 'join', 'leave', 'noop']),
        };
        ops.push(op);
    }
    if (ops.length > 0 && chance(r, 0.04)) {
        // Writer corner cases: no sequence number (section silently omitted), non-object, null.
        const choice = r.int(3);
        const index = r.pick([0, ops.length - 1]);
        ops[index] = choice === 0 ? { type: 'noop' } : choice === 1 ? 'text op' : null;
    }
    return ops;
}

export function genSnapshotSpec(r: Random): SnapshotSpec {
    const snapshotTree = genTree(r, 3, true);
    const blobContents: [string, BlobSpec][] = [];
    const used = new Set<string>();
    const blobIds = [...collectBlobIds(snapshotTree)];
    const count = chance(r, 0.15) ? 0 : 1 + r.int(8);
    for (let i = 0; i < count; i++) {
        const id = blobIds.length > 0 && chance(r, 0.6) ? r.pick(blobIds) : `blob-${word(r, 10)}`;
        if (used.has(id)) continue;
        used.add(id);
        blobContents.push([id, genBlob(r)]);
    }
    const first = chance(r, 0.1) ? 0 : 1 + r.int(5000);
    const spec: SnapshotSpec = { snapshotTree, blobContents, ops: genOps(r, first) };
    if (!chance(r, 0.03)) {
        spec.sequenceNumber = r.pick([0, 0, 1, r.int(1000), r.int(2 ** 31), 2 ** 32, 2 ** 40 + r.int(1000), 2 ** 53 - 1]);
    }
    if (chance(r, 0.5)) {
        spec.latestSequenceNumber = r.pick([0, 1, r.int(1000), 2 ** 32 + 1, 2 ** 53 - 1, 2 ** 53 + 1024]);
    }
    return spec;
}

function collectBlobIds(tree: TreeSpec): Set<string> {
    const ids = new Set<string>(Object.values(tree.blobs));
    for (const child of Object.values(tree.trees)) for (const id of collectBlobIds(child)) ids.add(id);
    return ids;
}

// ---------------------------------------------------------------------------------------------
// Raw ZipIt trees
// ---------------------------------------------------------------------------------------------

export const S = (v: string, d = false): RawElement => ({ k: 'str', v, d });
export const D = (v: string): RawElement => S(v, true);
export const N = (v: number | null): RawElement => ({ k: 'num', v });
export const B = (v: boolean): RawElement => ({ k: 'bool', v });
export const BL = (hex: string): RawElement => ({ k: 'blob', hex });
export const node = (t: 'set' | 'list', ...c: RawElement[]): RawNode => ({ k: 'node', t, c });

const INTEGERS = [
    0, 1, 2, 127, 128, 255, 256, 257, 65535, 65536, 2 ** 24 - 1, 2 ** 24, 2 ** 31, 2 ** 32 - 1, 2 ** 32,
    2 ** 40 + 12345, 2 ** 53 - 1, 2 ** 53, 2 ** 53 + 2, 2 ** 56, 2 ** 63, 2 ** 64 - 2048, 2 ** 64,
];

function rawNumber(r: Random): number | null {
    if (chance(r, 0.04)) return r.pick([-1, 1.5, 0.1, null]);
    return chance(r, 0.6) ? r.pick(INTEGERS) : r.int(2 ** 30);
}

function rawElement(r: Random, depth: number, names: string[]): RawElement {
    switch (r.int(depth > 0 ? 9 : 7)) {
        case 0: return N(rawNumber(r));
        case 1: return B(chance(r, 0.5));
        case 2: return S(text(r));
        case 3:
        case 4: return D(names.length > 0 && chance(r, 0.5) ? r.pick(names) : text(r));
        case 5: return BL(toHex(bytesOf(r, r.pick([0, 1, 5, 254, 255, 256, 257, 1000, 65536]))));
        case 6: return S(r.pick(['', 'plain', 'é', '😀']));
        default: return rawNode(r, depth - 1, names);
    }
}

function rawNode(r: Random, depth: number, names: string[]): RawNode {
    const result = node(r.pick(['set', 'list']));
    const count = r.int(7);
    for (let i = 0; i < count; i++) result.c.push(rawElement(r, depth, names));
    return result;
}

/** Top-level children of a `TreeBuilder`: arbitrary mixes of every element kind. */
export function genRawTree(r: Random): RawElement[] {
    const names = Array.from({ length: 6 }, () => word(r, 6));
    const top: RawElement[] = [];
    const count = r.int(6);
    for (let i = 0; i < count; i++) top.push(rawElement(r, 3, names));
    if (chance(r, 0.15)) {
        // More than 255 distinct dictionary strings: IDs 256+ need big declarations and 2-byte references.
        const many = node('set');
        const total = 250 + r.int(40);
        for (let i = 0; i < total; i++) many.c.push(D(`key-${i}`));
        for (let i = 0; i < 20; i++) many.c.push(D(`key-${r.int(total)}`));
        top.push(many);
    }
    if (chance(r, 0.1)) top.push(S('x'.repeat(r.pick([255, 256, 65535, 65536, 70000])), chance(r, 0.5)));
    return top;
}

// ---------------------------------------------------------------------------------------------
// Hand-shaped snapshots: valid and near-valid `application/ms-fluid` structure built with the raw
// writer, so the reader's fast paths, general paths and failures are all reached.
// ---------------------------------------------------------------------------------------------

type Pair = RawElement[];

function shuffled<T>(r: Random, items: T[]): T[] {
    const copy = [...items];
    for (let i = copy.length - 1; i > 0; i--) {
        const j = r.int(i + 1);
        const a = copy[i];
        const b = copy[j];
        if (a === undefined || b === undefined) throw new Error('shuffle');
        copy[i] = b;
        copy[j] = a;
    }
    return copy;
}

function key(r: Random, k: string): RawElement {
    return chance(r, 0.85) ? D(k) : S(k);
}

function entryName(r: Random): RawElement {
    return chance(r, 0.9) ? D(name(r)) : S(name(r));
}

function genEntry(r: Random, depth: number): RawElement {
    const nm = (): Pair => [key(r, 'name'), entryName(r)];
    const children = (): Pair => [key(r, 'children'), node(chance(r, 0.95) ? 'list' : 'set', ...genEntries(r, depth - 1))];
    const value = (): Pair => [key(r, 'value'), S(word(r, 12))];
    switch (r.int(14)) {
        case 0: return node('set', ...nm());
        case 1: return node('set', ...nm(), ...children());
        case 2: return node('set', ...nm(), ...value());
        case 3: return node('set', ...nm(), key(r, 'nodeType'), N(chance(r, 0.9) ? 3 : r.int(9)), ...value());
        case 4: return node('set', ...nm(), key(r, 'unreferenced'), B(true), ...children());
        case 5: return node('set', ...nm(), key(r, 'unreferenced'), B(chance(r, 0.5)), ...children());
        case 6: return node('set', ...nm(), key(r, 'unreferenced'), r.pick([N(1), S('true'), B(true)]));
        case 7: {
            // General path: every property in random order, plus unknown fields and duplicates.
            const pairs: Pair[] = [nm()];
            if (chance(r, 0.6)) pairs.push(children());
            if (chance(r, 0.2)) pairs.push(value());
            if (chance(r, 0.3)) pairs.push([key(r, 'unreferenced'), B(chance(r, 0.9))]);
            if (chance(r, 0.4)) pairs.push([key(r, 'groupId'), chance(r, 0.9) ? D(`G${r.int(4)}`) : N(7)]);
            if (chance(r, 0.2)) pairs.push([key(r, word(r, 5)), rawElement(r, 0, [])]);
            if (chance(r, 0.1)) pairs.push(nm());
            return node('set', ...shuffled(r, pairs).flat());
        }
        case 8: return node('set', ...nm(), key(r, 'groupId'), D(`G${r.int(3)}`));
        case 9: return node('set', ...nm(), ...children(), key(r, 'groupId'), D('G9'));
        case 10: {
            // Error shapes: odd length, missing name, non-string key, wrong value types.
            const choice = r.int(6);
            if (choice === 0) return node('set', ...nm(), key(r, 'value'));
            if (choice === 1) return node('set', ...value());
            if (choice === 2) return node('set', N(1), S('x'));
            if (choice === 3) return node('set', ...nm(), key(r, 'value'), N(5));
            if (choice === 4) return node('set', ...nm(), key(r, 'children'), S('not a node'));
            return node('set', key(r, 'name'), N(3));
        }
        case 11: return node('set', D('__proto__'), rawElement(r, 0, []), ...nm());
        case 12: return r.pick([S('stray'), N(4), B(true), BL('aa')]);
        default: return node('set', ...nm());
    }
}

function genEntries(r: Random, depth: number): RawElement[] {
    if (depth < 0) return [];
    return Array.from({ length: r.int(5) }, () => genEntry(r, depth));
}

function genBlobEntries(r: Random): RawElement[] {
    const entries: RawElement[] = [];
    const count = r.int(5);
    for (let i = 0; i < count; i++) {
        const id: Pair = [key(r, 'id'), S(chance(r, 0.7) ? `b${i}` : `dup${r.int(2)}`)];
        const data: Pair = [chance(r, 0.9) ? S('data') : D('data'), BL(toHex(bytesOf(r, r.pick([0, 1, 7, 256, 300]))))];
        switch (r.int(8)) {
            case 0: entries.push(node('set', ...data, ...id)); break;
            case 1: entries.push(node('set', ...id, ...data, key(r, 'extra'), N(1))); break;
            case 2: entries.push(node('set', ...id)); break;
            case 3: entries.push(node('set', ...id, S('data'), S('text'))); break;
            case 4: entries.push(node('set', S('id'), N(5), ...data)); break;
            case 5: entries.push(r.pick([S('x'), N(1)])); break;
            default: entries.push(node('set', ...id, ...data));
        }
    }
    return entries;
}

function genDeltas(r: Random): Pair[] {
    const first = r.int(100);
    const count = r.pick([0, 0, 1, 2, 5]);
    const texts: RawElement[] = [];
    for (let i = 0; i < count; i++) {
        const body = r.int(15);
        if (body === 0) texts.push(S('{'));
        else if (body === 1) texts.push(S('null'));
        else if (body === 2) texts.push(S('5'));
        else if (body === 3) texts.push(N(1));
        else if (body === 4) texts.push(S(`{"sequenceNumber":"${first + i}"}`));
        else if (body === 5) texts.push(S('[1, 2'));
        else texts.push(S(JSON.stringify({ sequenceNumber: first + i, type: 'op', contents: text(r) })));
    }
    const firstValue = chance(r, 0.85) ? N(first) : r.pick([N(first + 1), S('x'), N(null)]);
    return [
        [key(r, 'firstSequenceNumber'), firstValue],
        [key(r, 'deltas'), node(chance(r, 0.95) ? 'list' : 'set', ...texts)],
    ];
}

function genVersion(r: Random, good: string, others: string[]): RawElement {
    if (chance(r, 0.8)) return S(good);
    return chance(r, 0.85) ? S(r.pick(others)) : r.pick([N(1), B(true)]);
}

export function genShapeSnapshot(r: Random): RawElement[] {
    const pairs: Pair[] = [];
    pairs.push([key(r, 'mrv'), genVersion(r, '1.0', ['1', '0.5', '1.00', '2.0', 'abc', '', ' 1', '1.0.0', '0x1', '1e0', '.5', '-1', 'Infinity', '1.5'])]);
    pairs.push([key(r, 'cv'), genVersion(r, '1.0', ['1', '1.00', '0.9', '1.1', 'abc', '', '1.0.0', '1.0 ', '+1.0'])]);
    if (!chance(r, 0.1)) {
        const lsn = chance(r, 0.9) ? N(r.pick([0, 1, 50, 2 ** 40])) : r.pick([S('7'), B(true), N(2 ** 53 + 1024)]);
        pairs.push([key(r, 'lsn'), lsn]);
    }
    const snapshot: Pair[] = [];
    if (!chance(r, 0.03)) snapshot.push([key(r, 'id'), chance(r, 0.95) ? S(word(r, 10)) : N(1)]);
    snapshot.push([key(r, 'message'), S('Snapshot@0')]);
    if (!chance(r, 0.03)) snapshot.push([key(r, 'sequenceNumber'), chance(r, 0.95) ? N(r.pick([0, 3, 2 ** 33, 2 ** 53 - 1, 2 ** 53 + 2048])) : S('0')]);
    if (!chance(r, 0.02)) {
        const list = chance(r, 0.94) ? node('list', ...genEntries(r, 3)) : r.pick([node('set', ...genEntries(r, 1)), S('x'), N(0)]);
        snapshot.push([key(r, 'treeNodes'), list]);
    }
    pairs.push([key(r, 'snapshot'), chance(r, 0.97) ? node('set', ...shuffled(r, snapshot).flat()) : r.pick([S('no'), node('set', ...snapshot.flat().slice(1))])]);
    if (!chance(r, 0.03)) pairs.push([key(r, 'blobs'), chance(r, 0.97) ? node('list', ...genBlobEntries(r)) : r.pick([S('no'), N(1)])]);
    if (chance(r, 0.5)) pairs.push([key(r, 'deltas'), node('set', ...genDeltas(r).flat())]);
    if (chance(r, 0.1)) pairs.push([key(r, word(r, 5)), rawElement(r, 0, [])]);
    if (chance(r, 0.05)) pairs.push(pairs[r.int(pairs.length)] ?? []);
    const ordered = chance(r, 0.25) ? shuffled(r, pairs) : pairs;
    const body = ordered.flat();
    if (chance(r, 0.03)) body.pop();
    const top: RawElement[] = [node('set', ...body)];
    if (chance(r, 0.03)) top.push(node('set'));
    if (chance(r, 0.02)) top.length = 0;
    if (chance(r, 0.02)) top[0] = r.pick([S('root'), N(1), node('list')]);
    return top;
}

// ---------------------------------------------------------------------------------------------
// Byte-level mutations
// ---------------------------------------------------------------------------------------------

const MARKERS = [0x01, 0x03, 0x05, 0x07, 0x09, 0x0b, 0x0c, 0x0d, 0x0e, 0x11, 0x14, 0x15, 0x20, 0x21, 0x31, 0x32, 0x33, 0x34, 0x00, 0x0a, 0x16, 0x25, 0x30, 0xff, 0x24, 0x08, 0x02];

export function mutate(r: Random, input: Uint8Array): Uint8Array {
    if (input.length === 0) return Uint8Array.of(r.pick(MARKERS));
    const bytes = Array.from(input);
    const edits = 1 + r.int(3);
    for (let i = 0; i < edits; i++) {
        const at = r.int(bytes.length);
        switch (r.int(9)) {
            case 0: bytes.length = at; break;
            case 1: bytes[at] = r.int(256); break;
            case 2: bytes.splice(at, 0, r.int(256)); break;
            case 3: bytes.splice(at, 1 + r.int(4)); break;
            case 4: bytes[at] = r.pick(MARKERS); break;
            case 5: bytes.splice(at, 0, r.pick(MARKERS), r.pick(MARKERS)); break;
            case 6: bytes.push(...bytesOf(r, 1 + r.int(8))); break;
            case 7: bytes[at] = 0; break;
            default: bytes[at] = (bytes[at] ?? 0) ^ (1 << r.int(8));
        }
        if (bytes.length === 0) bytes.push(r.pick(MARKERS));
    }
    return Uint8Array.from(bytes);
}

// ---------------------------------------------------------------------------------------------
// Grammar bytes: every valid marker, written directly (the TS writer never emits the "signed"
// integer markers, 16/32-bit string lengths, 8-byte blob lengths or 2/4-byte dictionary references).
// ---------------------------------------------------------------------------------------------

function littleEndian(value: number, width: number): number[] {
    const out: number[] = [];
    let rest = BigInt(value);
    for (let i = 0; i < width; i++) {
        out.push(Number(rest & 0xffn));
        rest >>= 8n;
    }
    return out;
}

function randomUnsigned(r: Random, width: number): number[] {
    // High bits set on purpose: a signed reading would differ from the oracle's unsigned one.
    const bytes = Array.from(bytesOf(r, width));
    if (chance(r, 0.5)) bytes[width - 1] = 0x80 | (bytes[width - 1] ?? 0);
    if (chance(r, 0.1)) return bytes.map(() => 0xff);
    return bytes;
}

function textBytes(r: Random): number[] {
    const choice = r.int(20);
    if (choice === 0) return [0x61, 0x00, 0x62]; // embedded NUL: fails in TS (0x3ea)
    if (choice === 1) return Array.from(bytesOf(r, 1 + r.int(6))); // arbitrary, mostly invalid UTF-8
    if (choice === 2) return [0xe2, 0x82]; // truncated sequence
    if (choice === 3) return [0xef, 0xbb, 0xbf, 0x41]; // BOM is kept by Buffer.toString
    return Array.from(Buffer.from(text(r), 'utf8'));
}

export function genGrammarBytes(r: Random): Uint8Array {
    const out: number[] = [];
    const declared: number[] = [];
    let open = 0;

    function emit(depth: number): void {
        switch (r.int(depth < 3 ? 22 : 20)) {
            case 0: out.push(0x01); break;
            case 1: out.push(r.pick([0x02, 0x03]), ...randomUnsigned(r, 1)); break;
            case 2: out.push(r.pick([0x04, 0x05]), ...randomUnsigned(r, 2)); break;
            case 3: out.push(r.pick([0x06, 0x07]), ...randomUnsigned(r, 4)); break;
            case 4: out.push(r.pick([0x08, 0x09]), ...randomUnsigned(r, 8)); break;
            case 5: out.push(r.pick([0x0b, 0x0c, 0x0d])); break;
            case 6: { const t = textBytes(r); out.push(0x0e, ...littleEndian(t.length, 1), ...t); break; }
            case 7: { const t = textBytes(r); out.push(0x0f, ...littleEndian(t.length, 2), ...t); break; }
            case 8: { const t = textBytes(r); out.push(0x10, ...littleEndian(t.length, 4), ...t); break; }
            case 9:
            case 10: {
                const t = textBytes(r).slice(0, 200);
                const id = r.pick([0, 1, 7, 255, r.int(256)]);
                out.push(0x14, id, t.length, ...t);
                declared.push(id);
                break;
            }
            case 11: {
                const t = textBytes(r);
                const id = r.pick([0, 256, 300, 70000, 2 ** 32 - 1, r.int(2 ** 20)]);
                out.push(0x15, ...littleEndian(id, 4), ...littleEndian(t.length, 4), ...t);
                declared.push(id);
                break;
            }
            case 12:
            case 13: {
                // A reference: usually to a declared ID, sometimes to one that was never declared.
                const id = declared.length > 0 && !chance(r, 0.03) ? r.pick(declared) : r.int(1000);
                const width = id < 256 ? r.pick([1, 2, 4]) : id < 65536 ? r.pick([2, 4]) : 4;
                out.push(width === 1 ? 0x11 : width === 2 ? 0x12 : 0x13, ...littleEndian(id, width));
                break;
            }
            case 14: out.push(0x20); break;
            case 15: { const n = r.pick([0, 1, 5, 255]); out.push(0x21, n, ...bytesOf(r, n)); break; }
            case 16: { const n = r.pick([0, 3, 256, 300]); out.push(0x22, ...littleEndian(n, 2), ...bytesOf(r, n)); break; }
            case 17: { const n = r.pick([0, 2, 70000]); out.push(0x23, ...littleEndian(n, 4), ...bytesOf(r, n)); break; }
            case 18: { const n = r.pick([0, 4]); out.push(0x24, ...littleEndian(n, 8), ...bytesOf(r, n)); break; }
            case 19: out.push(r.pick([0x0b, 0x01])); break;
            default: {
                out.push(r.pick([0x31, 0x33]));
                open++;
                const count = r.int(6);
                for (let i = 0; i < count; i++) emit(depth + 1);
                // Start and end markers need not match (the reader does not check).
                out.push(r.pick([0x32, 0x34]));
                open--;
            }
        }
    }

    const top = 1 + r.int(5);
    for (let i = 0; i < top; i++) emit(0);
    if (open !== 0) throw new Error('unbalanced generator');
    return Uint8Array.from(out);
}
