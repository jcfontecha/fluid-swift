import assert from 'node:assert/strict';
import { inspect } from 'node:util';
import { makeMessageCodecBuilder } from '../../node_modules/@fluidframework/tree/lib/shared-tree-core/messageCodecs.js';
import { createIdCompressor } from '@fluidframework/id-compressor/internal';
import type { SessionId } from '@fluidframework/id-compressor';
import { ModularChangeFamily } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/modularChangeFamily.js';
import { makeModularChangeCodecFamily } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/modularChangeCodecs.js';
import { fieldKinds, fieldKindConfigurations } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/default-schema/defaultFieldKinds.js';
import { fieldBatchCodecBuilder } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/chunked-forest/index.js';
import { RevisionTagCodec } from '../../node_modules/@fluidframework/tree/lib/core/rebase/revisionTagCodec.js';
import { revisionMetadataSourceFromInfo } from '../../node_modules/@fluidframework/tree/lib/core/rebase/utils.js';
import { sequenceFieldEditor } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/sequenceFieldEditor.js';
import { optionalFieldEditor } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/optional-field/optionalField.js';
import { areEquivalent } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/modularChangeUtils.js';
import { FluidClientVersion, FormatValidatorNoOp } from '../../node_modules/@fluidframework/tree/lib/codec/index.js';
import { brand } from '../../node_modules/@fluidframework/tree/lib/util/index.js';
import type { ChangeAtomId, RevisionInfo, RevisionTag, FieldUpPath, TaggedChange } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import type { ModularChangeset, FieldChangeset } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/modularChangeTypes.js';

export interface Edit {
    kind: 'insert' | 'remove' | 'move' | 'revive' | 'set' | 'clear' | 'crossMove' | 'nested';
    index: number;
    count: number;
    destination: number;
    field: 'a' | 'b';
}
export interface Scenario {
    seed: number;
    edits: Edit[];
}
export class Oracle {
    readonly compressor = createIdCompressor('00000001-0000-4000-8000-000000000000' as SessionId, 2);
    readonly options = { jsonValidator: FormatValidatorNoOp, minVersionForCollab: FluidClientVersion.v2_0 };
    readonly codecs = makeModularChangeCodecFamily(fieldKindConfigurations, new RevisionTagCodec(this.compressor), fieldBatchCodecBuilder.build(this.options), this.options);
    readonly family = new ModularChangeFamily(fieldKinds, this.codecs, this.options);
    mint(): RevisionTag {
        const revision = this.compressor.generateCompressedId() as RevisionTag;
        return revision;
    }
    tag(change: ModularChangeset, revision?: RevisionTag): TaggedChange<ModularChangeset> {
        return { change, revision };
    }
    build(edit: Edit): TaggedChange<ModularChangeset> {
        const revision = this.mint();
        const atom: ChangeAtomId = { localId: brand(0), revision };
        const attach: ChangeAtomId = { localId: brand(8), revision };
        const field: FieldUpPath = { parent: undefined, field: brand(edit.field) };
        const other: FieldUpPath = { parent: undefined, field: brand(edit.field === 'a' ? 'b' : 'a') };
        const builder = this.family.buildEditor(() => revision, () => {});
        const description = (path: FieldUpPath, change: unknown, kind = 'Sequence') => ({
            type: 'field' as const,
            field: path,
            fieldKind: brand<import('../../node_modules/@fluidframework/tree/lib/core/index.js').FieldKindIdentifier>(kind),
            change: change as FieldChangeset,
            revision,
        });
        builder.generateId(64);
        const seq = sequenceFieldEditor;
        let changes;
        switch (edit.kind) {
            case 'insert':
                changes = [description(field, seq.insert(edit.index, edit.count, atom, revision))];
                break;
            case 'remove':
                changes = [description(field, seq.remove(edit.index, edit.count, atom.localId, revision))];
                break;
            case 'move':
                changes = [description(field, seq.move(edit.index, edit.count, edit.destination, atom.localId, attach, revision))];
                break;
            case 'revive':
                changes = [description(field, seq.revive(edit.index, edit.count, { localId: brand(32), revision: 'root' }, revision))];
                break;
            case 'crossMove':
                changes = [description(field, seq.moveOut(edit.index, edit.count, atom.localId, revision)), description(other, seq.moveIn(edit.destination, edit.count, atom.localId, attach, revision))];
                break;
            case 'set':
                changes = [description({ ...field, field: brand('optional') }, optionalFieldEditor.set(false, { fill: attach, detach: atom }), 'Optional')];
                break;
            case 'clear':
                changes = [description({ ...field, field: brand('optional') }, optionalFieldEditor.clear(false, atom), 'Optional')];
                break;
            case 'nested':
                changes = [description({ parent: { parent: undefined, parentField: field.field, parentIndex: edit.index }, field: brand('children') }, seq.insert(0, edit.count, atom, revision))];
                break;
        }
        return this.tag(builder.buildChanges(changes), revision);
    }
    bytes(change: ModularChangeset, versions: readonly number[] = [5], revision?: RevisionTag): string[] {
        const context = { originatorId: this.compressor.localSessionId, revision, idCompressor: this.compressor, isSummary: false };
        return versions.map(version => {
            const codec = this.codecs.resolve(version);
            let encoded;
            try {
                encoded = codec.encode(change, context);
            } catch (error) {
                throw new Error(`modular ${version} encode failed: ${inspect({ fields: change.fieldChanges, revisions: change.revisions }, {depth: 12})}`, {cause: error});
            }
            let decoded;
            try {
                decoded = codec.decode(encoded, context);
            } catch (error) {
                throw new Error(`modular ${version} decode failed for ${JSON.stringify(encoded)}`, { cause: error });
            }
            assert(areEquivalent(change, decoded, fieldKinds), `codec ${version} semantic roundtrip`);
            const bytes = JSON.stringify(encoded);
            assert.equal(JSON.stringify(codec.encode(decoded, context)), bytes, `codec ${version} byte roundtrip`);
            return bytes;
        });
    }
    rebase(change: TaggedChange<ModularChangeset>, over: TaggedChange<ModularChangeset>, history: RevisionInfo[] = []): TaggedChange<ModularChangeset> {
        const infos = new Map<RevisionTag, RevisionInfo>();
        for (const info of [...history, ...(over.change.revisions ?? []), ...(change.change.revisions ?? [])]) {
            infos.set(info.revision, info);
        }
        return this.tag(this.family.rebase(change, over, revisionMetadataSourceFromInfo([...infos.values()])), change.revision);
    }
}
// A direct lossless projection supplements codecs (which omit derived metadata).
// Tagged tuples preserve Maps and undefined instead of silently erasing them.
export function structure(value: unknown): unknown {
    if (value === undefined) return ['undefined'];
    if (value === null || typeof value !== 'object') return value;
    if (value instanceof Map) return ['map', [...value].map(([key, item]: [unknown, unknown]) => [structure(key), structure(item)])];
    if (value instanceof Set) return ['set', [...value].map(structure)];
    if (Array.isArray(value)) return ['array', value.map(structure)];
    return ['object', Object.entries(value).map(([key, item]) => [key, structure(item)])];
}

export function wireVersions(): number[] {
    const builder = makeMessageCodecBuilder();
    const gates = [FluidClientVersion.v2_0, FluidClientVersion.v2_43, FluidClientVersion.v2_80, FluidClientVersion.v2_117];
    // shared-tree/sharedTree.ts dependenciesForMessageFormat.
    const dependencies = new Map([[3, 3], [4, 4], [6, 5], [7, 5]]);
    return gates.map(gate => {
        const message = builder.getCodecTree(gate).version;
        assert(typeof message === 'number');
        const modular = dependencies.get(message);
        assert(modular !== undefined);
        return modular;
    });
}

export function run(scenario: Scenario): string[][] {
    const oracle = new Oracle();
    const output: string[][] = [];
    const record = (change: ModularChangeset) => output.push([...oracle.bytes(change), JSON.stringify(structure(change))]);
    const edits = scenario.edits.map(edit => oracle.build(edit));
    for (const change of edits) {
        output.push(oracle.bytes(change.change, wireVersions(), change.revision));
        record(change.change);
        record(oracle.family.invert(change, false, oracle.mint()));
        record(oracle.family.invert(change, true, oracle.mint()));
        const identity = oracle.family.compose([change]);
        assert(areEquivalent(identity, change.change, fieldKinds, false, true), 'compose singleton');
        record(identity);
        const overEmpty = oracle.rebase(change, oracle.tag(ModularChangeFamily.emptyChange));
        assert(areEquivalent(overEmpty.change, change.change, fieldKinds, false, true), 'rebase over empty');
        record(overEmpty.change);
    }
    for (let i = 1; i < edits.length; i++) {
        const a = edits[i - 1];
        const b = edits[i];
        assert(a && b);
        const rebased = oracle.rebase(b, a);
        record(rebased.change);
        const composed = oracle.family.compose([a, rebased]);
        record(composed);
        const inverseRevision = oracle.mint();
        const inverse = { change: oracle.family.invert(a, true, inverseRevision), revision: inverseRevision, rollbackOf: a.revision };
        record(oracle.rebase(rebased, inverse, [...(a.change.revisions ?? [])]).change);
        const c = edits[i + 1];
        if (c) {
            const sequential = oracle.rebase(oracle.rebase(c, a), rebased);
            const combined = oracle.rebase(c, oracle.tag(composed));
            assert(areEquivalent(sequential.change, combined.change, fieldKinds, false, true), 'rebase over composition');
            record(sequential.change);
            record(combined.change);
        }
    }
    return output;
}
