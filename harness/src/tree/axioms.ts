// Enabled laws from tree/src/test/rebaserAxiomaticTests.ts. Equality here is
// observable delta equality (as in upstream optional-field tests); every raw
// result is separately recorded under the unchanged differential contracts.
import assert from 'node:assert/strict';
import { intoDelta, ModularChangeFamily } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/modularChangeFamily.js';
import { fieldKinds } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/default-schema/defaultFieldKinds.js';
import type { DeltaRoot, DeltaFieldMap, DeltaMark, TaggedChange, RevisionInfo, RevisionTag } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import type { ModularChangeset } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/modularChangeTypes.js';
import { comparePartialRevisions } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import type { Mutable } from '../../node_modules/@fluidframework/tree/lib/util/index.js';
import type { Oracle, Scenario } from './oracle.js';
type Tagged = TaggedChange<ModularChangeset>;
// Upstream sequence axioms remove tombstones through MarkListFactory and prune
// empty children. On deltas this coalesces adjacent offsets and removes invisible
// child maps. It never changes attach/detach identities or visible operations.
function canonicalFields(fields: DeltaFieldMap | undefined): DeltaFieldMap {
    const result: Map<import('../../node_modules/@fluidframework/tree/lib/core/index.js').FieldKey, { marks: DeltaMark[] }> = new Map();
    for (const [key, field] of fields ?? []) {
        const marks: DeltaMark[] = [];
        let offset = 0;
        for (const mark of field.marks) {
            const nested = canonicalFields(mark.fields);
            if (mark.attach === undefined && mark.detach === undefined && nested.size === 0) {
                offset += mark.count;
            } else {
                if (offset > 0) marks.push({ count: offset });
                offset = 0;
                assert(nested.size === 0 || mark.count === 1, 'nested delta must affect one node');
                for (let index = 0; index < mark.count; index++) {
                    marks.push({ count: 1, ...(nested.size > 0 ? { fields: nested } : {}), ...(mark.detach === undefined ? {} : { detach: { ...mark.detach, minor: mark.detach.minor + index } }), ...(mark.attach === undefined ? {} : { attach: { ...mark.attach, minor: mark.attach.minor + index } }) });
                }
            }
        }
        if (marks.length > 0) result.set(key, { marks });
    }
    return result;
}
function delta(change: ModularChangeset): DeltaRoot {
    const value = intoDelta({ change, revision: undefined }, fieldKinds);
    const result: Mutable<DeltaRoot> = { ...value };
    const fields = canonicalFields(value.fields);
    if (fields.size > 0) result.fields = fields;
    else delete result.fields;
    const global = (value.global ?? []).map(change => ({ id: change.id, fields: canonicalFields(change.fields) })).filter(change => change.fields.size > 0);
    // core/tree/delta.ts explicitly makes global edits and renames unordered.
    const compareIds = (a: { major?: RevisionTag; minor: number }, b: { major?: RevisionTag; minor: number }) => comparePartialRevisions(a.major, b.major) || a.minor - b.minor;
    global.sort((a, b) => compareIds(a.id, b.id));
    if (global.length > 0) result.global = global;
    else delete result.global;
    const rename = (value.rename ?? []).filter(rename => rename.oldId.major !== rename.newId.major || rename.oldId.minor !== rename.newId.minor).flatMap(rename => Array.from({ length: rename.count }, (_, index) => ({ count: 1, oldId: { ...rename.oldId, minor: rename.oldId.minor + index }, newId: { ...rename.newId, minor: rename.newId.minor + index } })));
    rename.sort((a, b) => compareIds(a.oldId, b.oldId) || compareIds(a.newId, b.newId));
    if (rename.length > 0) result.rename = rename;
    else delete result.rename;
    return result;
}
function equivalent(a: ModularChangeset, b: ModularChangeset, name: string): void {
    assert.deepEqual(delta(a), delta(b), name);
}
function visibleFields(fields: DeltaFieldMap | undefined): boolean {
    return fields !== undefined && [...fields.values()].some(field => field.marks.some(mark => mark.attach !== undefined || mark.detach !== undefined || visibleFields(mark.fields)));
}
function invisible(change: ModularChangeset, name: string): void {
    const value: DeltaRoot = delta(change);
    assert(!visibleFields(value.fields), `${name}: live fields`);
    assert(!(value.global ?? []).some(change => visibleFields(change.fields)), `${name}: detached children`);
    assert((value.rename ?? []).every(rename => rename.oldId.major === rename.newId.major && rename.oldId.minor === rename.newId.minor), `${name}: detached renames`);
    assert((value.build?.length ?? 0) === 0 && (value.destroy?.length ?? 0) === 0, `${name}: build/destroy`);
}
export function runAxioms(oracle: Oracle, scenario: Scenario, edits: Tagged[], record: (change: ModularChangeset) => void): void {
    const empty: Tagged = { change: ModularChangeFamily.emptyChange, revision: undefined };
    const tagged = (change: ModularChangeset): Tagged => ({ change, revision: undefined });
    const rollback = (change: Tagged): Tagged => {
        const revision = oracle.mint();
        return { change: oracle.family.invert(change, true, revision), revision, rollbackOf: change.revision };
    };
    const history = (changes: Tagged[]): RevisionInfo[] => {
        const infos = new Map<RevisionTag, RevisionInfo>();
        for (const change of changes) for (const info of change.change.revisions ?? []) infos.set(info.revision, info);
        return [...infos.values()];
    };
    for (const edit of edits) {
        const right = oracle.family.compose([edit, empty]);
        record(right);
        equivalent(right, edit.change, 'compose right identity');
        const left = oracle.family.compose([empty, edit]);
        record(left);
        equivalent(left, edit.change, 'compose left identity');
        const emptyRebased = oracle.rebase(empty, edit);
        record(emptyRebased.change);
        invisible(emptyRebased.change, 'rebase empty');
        const inverse = rollback(edit);
        record(inverse.change);
        const cancelled = oracle.family.compose([edit, inverse]);
        record(cancelled);
        invisible(cancelled, 'compose inverse cancellation');
    }
    const groups = new Map<number | undefined, number[]>();
    for (const [index, edit] of scenario.edits.entries()) {
        const group = groups.get(edit.base) ?? [];
        group.push(index);
        groups.set(edit.base, group);
    }
    for (const indices of groups.values()) {
        for (let i = 1; i < indices.length; i++) {
            const ai = indices[i - 1];
            const bi = indices[i];
            assert(ai !== undefined && bi !== undefined);
            const a = edits[ai];
            const b = edits[bi];
            assert(a !== undefined && b !== undefined);
            const rebased = oracle.rebase(b, a);
            record(rebased.change);
            const inverse = rollback(a);
            record(inverse.change);
            const restored = oracle.rebase(rebased, inverse, [...(a.change.revisions ?? [])]);
            record(restored.change);
            equivalent(restored.change, b.change, 'rebase over do/undo');
            const redone = oracle.rebase(restored, a);
            record(redone.change);
            equivalent(redone.change, rebased.change, 'rebase over undo/redo');
            const ci = indices[i + 1];
            if (ci !== undefined) {
                const c = edits[ci];
                assert(c !== undefined);
                const third = oracle.rebase(oracle.rebase(c, a), rebased);
                const ab = tagged(oracle.family.compose([a, rebased]));
                const bc = tagged(oracle.family.compose([rebased, third]));
                const left = oracle.family.compose([ab, third]);
                const right = oracle.family.compose([a, bc]);
                const balanced = oracle.family.compose([a, rebased, third]);
                record(left);
                record(right);
                record(balanced);
                equivalent(left, right, 'compose associativity');
                equivalent(right, balanced, 'balanced compose associativity');
            }
            // The child was authored AFTER a; b was authored alongside a.
            const childIndex = scenario.edits.findIndex(edit => edit.base === ai);
            if (childIndex >= 0) {
                const child = edits[childIndex];
                assert(child !== undefined);
                const aPrime = oracle.rebase(a, b);
                record(aPrime.change);
                const scope = history([inverse, b, aPrime, child]);
                const first = oracle.rebase(child, inverse, scope);
                record(first.change);
                const second = oracle.rebase(first, b, scope);
                record(second.change);
                const sequential = oracle.rebase(second, aPrime, scope);
                record(sequential.change);
                const sandwich = oracle.family.compose([inverse, b, aPrime]);
                record(sandwich);
                const leftSandwich = oracle.family.compose([tagged(oracle.family.compose([inverse, b])), aPrime]);
                record(leftSandwich);
                equivalent(leftSandwich, sandwich, 'rollback compose associativity');
                const composed = oracle.rebase(child, tagged(leftSandwich), scope);
                record(composed.change);
                equivalent(sequential.change, composed.change, 'composed sandwich rebase');
            }
        }
    }
}
