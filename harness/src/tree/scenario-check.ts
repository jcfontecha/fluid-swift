import assert from 'node:assert/strict';
import { DocumentState, generate } from './scenario.js';
for (let seed = 0; seed < 1000; seed++) {
    const scenario = generate(seed);
    assert.deepEqual(scenario, generate(seed));
    const states = new Map([[-1, new DocumentState()]]);
    for (const [ordinal, edit] of scenario.edits.entries()) {
        assert(edit.base !== undefined && edit.base < ordinal);
        const parent = states.get(edit.base);
        assert(parent !== undefined);
        const state = parent.clone();
        state.apply(edit, ordinal);
        states.set(ordinal, state);
    }
}
const state = new DocumentState();
state.apply({ kind: 'remove', field: 'b', index: 2, count: 3, destination: 0 }, 0);
assert.throws(() => state.clone().apply({ kind: 'revive', field: 'b', index: 3, count: 1, destination: 0, detach: { edit: 0, localId: 0 } }, 1));
state.apply({ kind: 'revive', field: 'b', index: 2, count: 3, destination: 0, detach: { edit: 0, localId: 0 } }, 1);
assert.equal(state.length('b'), 12);
assert.equal(state.detached().length, 0);
console.log('1000 histories: every branch applies to its declared parent; seed-75 misplaced revive rejected.');

// A fresh attach tie-breaks left of older empty cells at the same live gap.
const insertState = new DocumentState();
insertState.apply({ kind: 'remove', field: 'b', index: 6, count: 3, destination: 0 }, 0);
insertState.apply({ kind: 'insert', field: 'b', index: 6, count: 1, destination: 0 }, 1);
assert.equal(insertState.detached()[0]?.index, 7, 'new attach must precede old empty cells');

// Move sources remain empty cells even though their roots are live elsewhere.
const moved = new DocumentState();
moved.apply({ kind: 'remove', field: 'b', index: 6, count: 3, destination: 0 }, 0);
moved.apply({ kind: 'move', field: 'b', index: 6, count: 1, destination: 5 }, 1);
assert.deepEqual(moved.fields.b.filter(cell => cell.node === undefined).map(cell => cell.cellId), [
    { edit: 0, localId: 0 }, { edit: 0, localId: 1 }, { edit: 0, localId: 2 }, { edit: 1, localId: 0 },
]);
assert.equal(moved.detached().length, 1);
const overlapping = new DocumentState();
overlapping.apply({ kind: 'move', field: 'b', index: 2, count: 3, destination: 3 }, 0);
assert.deepEqual(overlapping.fields.b.slice(2, 8).map(cell => cell.node?.id ?? `empty:${cell.cellId?.localId}`), ['empty:0', 'b:2', 'b:3', 'b:4', 'empty:1', 'empty:2']);

const optionalRoots = new DocumentState();
optionalRoots.apply({ kind: 'set', field: 'a', index: 0, count: 1, destination: 0, wasEmpty: false }, 0);
optionalRoots.apply({ kind: 'clear', field: 'a', index: 0, count: 1, destination: 0, wasEmpty: false }, 1);
assert.equal(optionalRoots.optionalDetached.get(0)?.id, 'optional');
assert.equal(optionalRoots.optionalDetached.get(1)?.id, '0:8');
assert.deepEqual(optionalRoots.clone().optionalDetached, optionalRoots.optionalDetached);
