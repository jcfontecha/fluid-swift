import assert from 'node:assert/strict';
import { Random } from '../random.js';
import type { Edit, Scenario } from './oracle.js';

interface NodeState {
    id: string;
    children: string[];
}
interface Cell {
    node?: NodeState;
    cellId?: { edit: number; localId: number };
    detached?: { edit: number; localId: number; node: NodeState };
}

// Mirrors sequenceChangeRebaser.test.ts's FieldStateTree: siblings share an
// input state; only a chosen child advances the trunk. Empty cells retain their
// actual detach identity and position, as in utils.ts's DetachedNodeTracker.
export class DocumentState {
    readonly fields: Record<'a' | 'b', Cell[]> = { a: [], b: [] };
    optional: NodeState | undefined;
    readonly optionalDetached = new Map<number, NodeState>();

    constructor() {
        for (const field of ['a', 'b'] as const) {
            this.fields[field] = Array.from({ length: 12 }, (_, i) => ({ node: { id: `${field}:${i}`, children: [] } }));
        }
        this.optional = { id: 'optional', children: [] };
    }

    clone(): DocumentState {
        const copy = new DocumentState();
        copy.fields.a = structuredClone(this.fields.a);
        copy.fields.b = structuredClone(this.fields.b);
        copy.optional = structuredClone(this.optional);
        for (const [revision, node] of this.optionalDetached) copy.optionalDetached.set(revision, structuredClone(node));
        return copy;
    }

    length(field: 'a' | 'b'): number {
        return this.fields[field].filter(cell => cell.node !== undefined).length;
    }

    detached(): { field: 'a' | 'b'; index: number; edit: number; localId: number; count: number }[] {
        const result: { field: 'a' | 'b'; index: number; edit: number; localId: number; count: number }[] = [];
        for (const field of ['a', 'b'] as const) {
            let index = 0;
            for (const cell of this.fields[field]) {
                if (cell.node !== undefined) {
                    index++;
                } else if (cell.detached !== undefined) {
                    const previous = result.at(-1);
                    const { edit, localId } = cell.detached;
                    if (previous?.field === field && previous.index === index && previous.edit === edit && previous.localId + previous.count === localId) {
                        previous.count++;
                    } else {
                        result.push({ field, index, edit, localId, count: 1 });
                    }
                }
            }
        }
        return result;
    }

    apply(edit: Edit, ordinal: number): void {
        assert(Number.isSafeInteger(edit.index) && edit.index >= 0);
        assert(Number.isSafeInteger(edit.count) && edit.count > 0);
        const cells = this.fields[edit.field];
        const live = cells.filter(cell => cell.node !== undefined);
        const create = (offset: number): NodeState => ({ id: `${ordinal}:${offset}`, children: [] });
        const insert = (field: 'a' | 'b', index: number, nodes: NodeState[]) => {
            assert(index >= 0 && index <= this.length(field));
            const target = this.fields[field];
            // New attaches tie-break left of every existing empty cell in the gap.
            const previous = index === 0 ? undefined : target.filter(cell => cell.node !== undefined)[index - 1];
            const position = previous === undefined ? 0 : target.indexOf(previous) + 1;
            target.splice(position, 0, ...nodes.map(node => ({ node })));
        };
        switch (edit.kind) {
            case 'insert':
                assert(edit.index <= live.length);
                insert(edit.field, edit.index, Array.from({ length: edit.count }, (_, i) => create(i)));
                break;
            case 'remove':
            case 'move':
            case 'crossMove': {
                const inputLive = new Set(live);
                const selected = live.slice(edit.index, edit.index + edit.count);
                assert.equal(selected.length, edit.count);
                const nodes = selected.map((cell, localId) => {
                    const node = cell.node;
                    assert(node !== undefined);
                    cell.cellId = { edit: ordinal, localId };
                    cell.detached = { edit: ordinal, localId, node };
                    delete cell.node;
                    return node;
                });
                if (edit.kind !== 'remove') {
                    // Moved-away cells are tombstones, but no longer own detached roots.
                    for (const cell of selected) delete cell.detached;
                    if (edit.kind === 'crossMove') {
                        insert(edit.field === 'a' ? 'b' : 'a', edit.destination, nodes);
                    } else {
                        // Follow sequenceFieldEditor.move's input-context ordering,
                        // including attach points inside a split source range.
                        assert(edit.destination <= live.length);
                        const output: Cell[] = [];
                        let inputIndex = 0;
                        let attached = false;
                        const attach = () => {
                            if (!attached && inputIndex === edit.destination) {
                                output.push(...nodes.map(node => ({ node })));
                                attached = true;
                            }
                        };
                        for (const cell of cells) {
                            attach();
                            output.push(cell);
                            if (inputLive.has(cell)) inputIndex++;
                        }
                        attach();
                        assert(attached);
                        this.fields[edit.field] = output;
                    }
                }
                break;
            }
            case 'revive': {
                assert(edit.detach !== undefined);
                let index = 0;
                let restored = 0;
                for (const cell of cells) {
                    const detached = cell.detached;
                    if (detached !== undefined && detached.edit === edit.detach.edit && detached.localId >= edit.detach.localId && detached.localId < edit.detach.localId + edit.count) {
                        assert.equal(index, edit.index + restored);
                        cell.node = detached.node;
                        delete cell.detached;
                        delete cell.cellId;
                        restored++;
                    }
                    if (cell.node !== undefined) index++;
                }
                assert.equal(restored, edit.count);
                break;
            }
            case 'nested': {
                const node = live[edit.index]?.node;
                assert(node !== undefined);
                node.children.unshift(...Array.from({ length: edit.count }, (_, i) => create(i).id));
                break;
            }
            case 'set':
            case 'clear':
                assert.equal(edit.wasEmpty, this.optional === undefined);
                if (this.optional !== undefined) this.optionalDetached.set(ordinal, this.optional);
                this.optional = edit.kind === 'set' ? create(8) : undefined;
                break;
        }
    }
}

export function generate(seed: number): Scenario {
    const random = new Random(seed);
    const kinds: Edit['kind'][] = ['insert', 'remove', 'move', 'revive', 'set', 'clear', 'crossMove', 'nested'];
    const state = new DocumentState();
    const edits: Edit[] = [];
    let base = -1;
    const append = (edit: Edit) => {
        edit.base = base;
        edits.push(edit);
        return edits.length - 1;
    };
    const make = (kind: Edit['kind']): Edit => {
        let field = random.pick(['a', 'b'] as const);
        if (['remove', 'move', 'crossMove', 'nested'].includes(kind) && state.length(field) === 0) {
            field = field === 'a' ? 'b' : 'a';
        }
        const length = state.length(field);
        const edit: Edit = { kind, field, index: 0, count: 1 + random.int(3), destination: 0 };
        if (kind === 'revive') {
            const root = random.pick(state.detached());
            edit.field = root.field;
            edit.index = root.index;
            edit.count = Math.min(edit.count, root.count);
            edit.detach = { edit: root.edit, localId: root.localId };
            edit.cells = state.fields[root.field].map(cell => {
                if (cell.node !== undefined) return { live: true as const };
                assert(cell.cellId !== undefined, 'every empty cell needs its detach identity');
                return { live: false as const, edit: cell.cellId.edit, localId: cell.cellId.localId };
            });
        } else {
            edit.index = random.int(kind === 'insert' ? length + 1 : Math.max(1, length));
            if (['remove', 'move', 'crossMove'].includes(kind)) edit.count = Math.min(edit.count, length - edit.index);
            edit.destination = random.int((kind === 'crossMove' ? state.length(field === 'a' ? 'b' : 'a') : length) + 1);
            if (kind === 'set' || kind === 'clear') edit.wasEmpty = state.optional === undefined;
        }
        return edit;
    };
    const schedule = [...kinds, ...Array.from({ length: 16 }, () => random.pick(kinds))];
    for (const kind of schedule) {
        // Materialize prerequisites, rather than invent roots or discard a seed.
        if (state.length('a') + state.length('b') < 3) {
            const insert: Edit = { kind: 'insert', field: 'a', index: 0, count: 3, destination: 0 };
            base = append(insert);
            state.apply(insert, base);
        }
        if (state.detached().length === 0) {
            const remove = make('remove');
            base = append(remove);
            state.apply(remove, base);
        }
        const siblings = [make(kind), make(random.pick(kinds)), make(random.pick(kinds))];
        const ordinals = siblings.map(append);
        const first = siblings[0];
        const ordinal = ordinals[0];
        assert(first !== undefined && ordinal !== undefined);
        state.apply(first, ordinal);
        base = ordinal;
    }
    return { seed, edits };
}
