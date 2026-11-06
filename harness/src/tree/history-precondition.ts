// Seed 75: the conceptual base places the same detached cells at two positions.
// utils.ts compareCellPositionsUsingTombstones requires one consistent base.
import assert from 'node:assert/strict';
import { Oracle } from './oracle.js';
const oracle = new Oracle();
const a = oracle.build({ kind: 'remove', index: 2, count: 3, destination: 4, field: 'b' });
const b = oracle.build({ kind: 'revive', index: 3, count: 1, destination: 8, field: 'b' });
const c = oracle.build({ kind: 'revive', index: 2, count: 3, destination: 3, field: 'b' });
const rebased = oracle.rebase(b, a);
assert.throws(() => oracle.rebase(oracle.rebase(c, a), rebased), /0x8a0/);
console.log('Confirmed original seed-75 invalid-history precondition (0x8a0); state-backed generator is checked separately.');
