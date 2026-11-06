import assert from 'node:assert/strict';
import { Oracle, structure, wireVersions } from './oracle.js';
import { generate } from './scenario.js';
assert.deepEqual(wireVersions(), [3, 4, 5, 5]);
assert.notDeepEqual(structure(new Map([['a', undefined]])), structure(new Map()));
assert.notDeepEqual(structure({ a: undefined }), structure({}));
for (let seed = 0; seed < 1000; seed++) {
    const left = new Oracle();
    const right = new Oracle();
    for (const edit of generate(seed).edits) {
        const a = left.build(edit);
        const b = right.build(edit);
        assert.deepEqual(left.bytes(a.change, wireVersions(), a.revision), right.bytes(b.change, wireVersions(), b.revision));
    }
}
console.log('TS wire-only self-check: 1000 seeds, 24000 individual edits, all four writer gates. Not Swift differential proof.');
