import assert from 'node:assert/strict';
import { createIdCompressor } from '@fluidframework/id-compressor/internal';
import type { SessionId } from '@fluidframework/id-compressor';
import { fieldBatchCodecBuilder, FieldBatchDecodingContext } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/chunked-forest/index.js';
import { schemaCodecBuilder } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/schema-index/codec.js';
import { forestCodecBuilder } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/forest-summary/codec.js';
import { cursorForMapTreeField, mapTreeFieldFromCursor } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/mapTreeCursor.js';
import { defaultSchemaPolicy } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/default-schema/defaultFieldKinds.js';
import { FluidClientVersion, FormatValidatorNoOp } from '../../node_modules/@fluidframework/tree/lib/codec/index.js';
import { brand } from '../../node_modules/@fluidframework/tree/lib/util/index.js';
import type { MapTree, FieldKey, TreeValue, TreeNodeSchemaIdentifier } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import { FieldBatchFormatVersion, type EncodedFieldBatchAnyVersion } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/chunked-forest/codec/format/index.js';
export interface Node {
    type: string;
    value?: TreeValue;
    fields: [string, Node[]][];
}
export interface Scenario { seed: number; schema: { version: 1; nodes: Record<string, {leaf: number} | {object: Record<string, {kind: string; types: string[]}>} | {map: {kind: string; types: string[]}}> ; root: {kind: string; types: string[]} }; fields: Node[][] }
const options = { jsonValidator: FormatValidatorNoOp, minVersionForCollab: FluidClientVersion.v2_74 };
export const compressor = () => {
    const c = createIdCompressor('00000001-0000-4000-8000-000000000000' as SessionId, 2);
    for (let i = 0; i < 8; i++) c.generateCompressedId();
    c.finalizeCreationRange(c.takeNextCreationRange());
    return c;
};
function tree(n: Node): MapTree {
    return { type: brand<TreeNodeSchemaIdentifier>(n.type), value: n.value, fields: new Map(n.fields.map(([key, nodes]) => [brand<FieldKey>(key), nodes.map(tree)])) };
}
function node(n: MapTree): Node {
    return {type: n.type, ...(n.value === undefined ? {} : {value: n.value}), fields: [...n.fields].map(([key, nodes]) => [key, nodes.map(node)])};
}
export function run(s: Scenario) {
    const idCompressor = compressor();
    const schemaCodec = schemaCodecBuilder.build(options);
    const schema = schemaCodec.decode(s.schema);
    const rows: string[] = [];
    const read = FieldBatchDecodingContext.forSummary({idCompressor, originatorId: idCompressor.localSessionId});
    for (const version of [1, 2, 'text'] as const) {
        const codec = fieldBatchCodecBuilder.build({...options, writeVersionOverrides: new Map([['FieldBatch', version]]), allowPossiblyIncompatibleWriteVersionOverrides: true});
        for (const compressed of [false, true]) {
            const context = { encodeType: compressed ? 0 : 1, schema: {schema, policy: defaultSchemaPolicy}, idCompressor, isSummary: true };
            const encoded = codec.encode(s.fields.map(f => cursorForMapTreeField(f.map(tree))), context);
            let decoded: string;
            try { decoded = JSON.stringify(codec.decode(encoded, read).map(c => mapTreeFieldFromCursor(c).map(node))); }
            catch (error) {
                if (!(error instanceof Error) || error.message !== "Array index is out of bounds") throw error;
                decoded = "decode-error:null-token";
            }
            rows.push(JSON.stringify(encoded), decoded);
            for (const fv of [1, 2] as const) {
                const forest = forestCodecBuilder.build({...options, writeVersionOverrides: new Map([['FieldBatch', version], ['Forest', fv]]), allowPossiblyIncompatibleWriteVersionOverrides: true});
                const fields = new Map(s.fields.map((f, i) => [brand<FieldKey>(`root${i}`), cursorForMapTreeField(f.map(tree))]));
                const summary = forest.encode(fields, context);
                rows.push(JSON.stringify(summary));

            }
        }
    }
    for (const version of [1, 2] as const) rows.push(JSON.stringify(schemaCodecBuilder.build({...options, writeVersionOverrides: new Map([['Schema', version]])}).encode(schema)));
    return rows;
}
export function decodeBatch(encoded: EncodedFieldBatchAnyVersion): string {
    const codec = fieldBatchCodecBuilder.build(options);
    try { return JSON.stringify(codec.decode(encoded, FieldBatchDecodingContext.forSummary({idCompressor: compressor(), healing: undefined})).map(c => mapTreeFieldFromCursor(c).map(node))); }
    catch (error) {
        if (!(error instanceof Error) || error.message !== "Array index is out of bounds") throw error;
        return "decode-error:null-token";
    }
}

import { BasicChunk } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/chunked-forest/basicChunk.js';
import { SequenceChunk } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/chunked-forest/sequenceChunk.js';
import { UniformChunk, TreeShape } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/chunked-forest/uniformChunk.js';
import type { TreeChunk, ITreeCursorSynchronous } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import type { IncrementalEncoder, IncrementalDecoder } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/chunked-forest/codec/codecs.js';
function chunk(n: MapTree): BasicChunk {
    return new BasicChunk(n.type, new Map([...n.fields].map(([key, nodes]) => [key, nodes.map(chunk)])), n.value);
}
export function extra(s: Scenario): string[] {
    const idCompressor = compressor();
    const schema = schemaCodecBuilder.build(options).decode(s.schema);
    const rows: string[] = [];
    const numberType = Object.keys(s.schema.nodes).find(k => k.startsWith('N'));
    assert(numberType !== undefined);
    for (const version of [1, 2, 'text'] as const) {
        const codec = fieldBatchCodecBuilder.build({...options, writeVersionOverrides: new Map([['FieldBatch', version]]), allowPossiblyIncompatibleWriteVersionOverrides: true});
        const uniform = new UniformChunk(new TreeShape(brand(numberType), true, []).withTopLevelLength(5), Array.from({length: 5}, (_, i) => s.seed + i));
        const context = {encodeType: 0, schema: {schema, policy: defaultSchemaPolicy}, idCompressor, isSummary: true};
        const encoded = codec.encode([uniform.cursor()], context);
        rows.push(JSON.stringify(encoded), decodeBatch(encoded as EncodedFieldBatchAnyVersion));
        if (version !== 1) {
            const chunks = new Map<number, EncodedFieldBatchAnyVersion>();
            let next = 0;
            const incremental: IncrementalEncoder & IncrementalDecoder = {
                shouldEncodeIncrementally: (_type, key) => key === 'children' || key === '',
                encodeIncrementalField(cursor: ITreeCursorSynchronous, encode) {
                    const nodes = mapTreeFieldFromCursor(cursor);
                    if (!nodes.length) return [];
                    const reference = brand<import('../../node_modules/@fluidframework/tree/lib/feature-libraries/chunked-forest/codec/codecs.js').ChunkReferenceId>(next++);
                    const children: TreeChunk[] = nodes.map(chunk);
                    const content = children.length === 1 ? children[0] : new SequenceChunk(children);
                    assert(content !== undefined);
                    chunks.set(reference, encode(content));
                    return [reference];
                },
                decodeIncrementalChunk(reference, decode) {
                    const encoded = chunks.get(reference);
                    assert(encoded !== undefined);
                    return decode(encoded);
                },
            };
            const encoded = codec.encode(s.fields.map(f => cursorForMapTreeField(f.map(tree))), {...context, encodeType: 2, incrementalEncoder: incremental});
            const read = FieldBatchDecodingContext.forSummary({idCompressor, healing: undefined}).withIncrementalDecoder(incremental);
            rows.push(JSON.stringify(encoded), JSON.stringify([...chunks]), JSON.stringify(codec.decode(encoded, read).map(c => mapTreeFieldFromCursor(c).map(node))));
        }
    }
    const unfinal = createIdCompressor('00000001-0000-4000-8000-000000000000' as SessionId, 2);
    const stable = unfinal.decompress(unfinal.generateCompressedId());
    const idSchema = schemaCodecBuilder.build(options).decode({version: 1, nodes: {O: {object: {id: {kind: 'Identifier', types: ['S']}}}, S: {leaf: 1}}, root: {kind: 'Value', types: ['O']}});
    const idTree: Node = {type: 'O', fields: [['id', [{type: 'S', value: stable, fields: []}]]]};
    for (const version of [1, 2, 'text'] as const) {
        const codec = fieldBatchCodecBuilder.build({...options, writeVersionOverrides: new Map([['FieldBatch', version]]), allowPossiblyIncompatibleWriteVersionOverrides: true});
        for (const isSummary of [true, false]) {
            const encoded = codec.encode([cursorForMapTreeField([tree(idTree)])], {encodeType: 0, schema: {schema: idSchema, policy: defaultSchemaPolicy}, idCompressor: unfinal, isSummary});
            const read = FieldBatchDecodingContext.forOp({idCompressor: unfinal, originatorId: unfinal.localSessionId});
            rows.push(JSON.stringify(encoded), JSON.stringify(codec.decode(encoded, read).map(c => mapTreeFieldFromCursor(c).map(node))));
        }
    }
    return rows;
}
export function decodeJobs(rows: string[]): {encoded: EncodedFieldBatchAnyVersion; chunks: [number, EncodedFieldBatchAnyVersion][]; originator?: boolean}[] {
    const jobs: {encoded: EncodedFieldBatchAnyVersion; chunks: [number, EncodedFieldBatchAnyVersion][]; originator?: boolean}[] = [];
    for (const i of [0, 4, 8, 12, 16, 20, 26, 28, 33, 38, 42, 46]) {
        jobs.push({encoded: JSON.parse(rows[i] ?? 'null') as EncodedFieldBatchAnyVersion, chunks: []});
    }
    for (const i of [30, 35]) {
        jobs.push({encoded: JSON.parse(rows[i] ?? 'null') as EncodedFieldBatchAnyVersion, chunks: JSON.parse(rows[i + 1] ?? 'null') as [number, EncodedFieldBatchAnyVersion][]});
    }
    for (const i of [40, 44, 48]) {
        jobs.push({encoded: JSON.parse(rows[i] ?? 'null') as EncodedFieldBatchAnyVersion, chunks: [], originator: true});
    }
    return jobs;
}
export function decodeJob(job: ReturnType<typeof decodeJobs>[number]): string {
    const codec = fieldBatchCodecBuilder.build(options);
    const chunks = new Map(job.chunks);
    const idCompressor = compressor();
    const base = job.originator ? FieldBatchDecodingContext.forOp({idCompressor, originatorId: idCompressor.localSessionId}) : FieldBatchDecodingContext.forSummary({idCompressor, healing: undefined});
    const incremental = {
        decodeIncrementalChunk(reference: import('../../node_modules/@fluidframework/tree/lib/feature-libraries/chunked-forest/codec/codecs.js').ChunkReferenceId, decode: (encoded: EncodedFieldBatchAnyVersion) => TreeChunk) {
            const chunk = chunks.get(reference);
            assert(chunk !== undefined);
            return decode(chunk);
        },
    };
    const read = job.originator ? base : base.withIncrementalDecoder(incremental);
    try { return JSON.stringify(codec.decode(job.encoded, read).map(c => mapTreeFieldFromCursor(c).map(node))); }
    catch (error) {
        if (!(error instanceof Error) || error.message !== 'Array index is out of bounds') throw error;
        return 'decode-error:null-token';
    }
}
export function specializations(seed: number): EncodedFieldBatchAnyVersion[] {
    return [
        {version: FieldBatchFormatVersion.vTextExperimental, identifiers: ['O', 'x', 'y'], shapes: [
            {c: {type: 0, value: false, fields: [[1, 1]]}},
            {c: {type: 'N', value: [seed]}},
            {f: {base: 0, fields: [[1, 3], [2, 1]], value: [true]}},
            {c: {type: 'N', value: [seed + 1]}},
            {f: {base: 2, value: null}},
        ], data: [[2], [4, false]]},
        {version: FieldBatchFormatVersion.vTextExperimental, identifiers: [], shapes: [
            {c: {type: 'Z', value: [null]}}, {a: 0},
            {c: {type: 'O', value: false, extraFields: 1}},
            {f: {base: 2, extraFields: null}},
        ], data: [[2, ['items', 3]], [3]]},
    ];
}
export function forestJobs(rows: string[]): string[] {
    return [2, 3, 6, 7, 10, 11, 14, 15, 18, 19, 22, 23].map(i => rows[i] ?? 'null');
}
export function decodeForest(text: string): string {
    const codec = forestCodecBuilder.build(options);
    try {
        const fields = codec.decode(JSON.parse(text), FieldBatchDecodingContext.forSummary({idCompressor: compressor(), healing: undefined}));
        return JSON.stringify([...fields].map(([key, cursor]) => [key, mapTreeFieldFromCursor(cursor).map(node)]));
    } catch (error) {
        if (!(error instanceof Error) || error.message !== 'Array index is out of bounds') throw error;
        return 'decode-error:null-token';
    }
}
export function decodeSchema(text: string, version: 1 | 2): string {
    const codec = schemaCodecBuilder.build({...options, writeVersionOverrides: new Map([['Schema', version]])});
    return JSON.stringify(codec.encode(codec.decode(JSON.parse(text))));
}
