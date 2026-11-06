// Minimal real-TS counterexample: a cross-field move followed by a rebased move
// creates a Rename. V3 modular encoding delegates it to sequence codec V2.
import assert from 'node:assert/strict';
import { Oracle } from './oracle.js';
const oracle = new Oracle();
const a = oracle.build({ kind: 'crossMove', field: 'b', index: 2, count: 3, destination: 9 });
const b = oracle.build({ kind: 'move', field: 'b', index: 2, count: 1, destination: 7 });
const composed = oracle.family.compose([a, oracle.rebase(b, a)]);
const context = { revision: undefined, originatorId: oracle.compressor.localSessionId, idCompressor: oracle.compressor, isSummary: false };
assert.throws(() => oracle.codecs.resolve(3).encode(composed, context), /0x996/);
// Supplying a context revision cannot repair a raw multi-revision result:
// encodeRevisionInfos requires exactly one matching, non-rollback revision.
assert.throws(() => oracle.codecs.resolve(3).encode(composed, { ...context, revision: a.revision }), /0x964/);
for (const version of [4, 5]) {
    const codec = oracle.codecs.resolve(version);
    const encoded = codec.encode(composed, context);
    assert.equal(JSON.stringify(codec.encode(codec.decode(encoded, context), context)), JSON.stringify(encoded));
}
console.log('Confirmed: modular 3 rejects a composed Rename (0x996); modular 4/5 roundtrip.');
