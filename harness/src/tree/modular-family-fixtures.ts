import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { Oracle } from './oracle.js';
import { generate } from './scenario.js';
const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const oracle = new Oracle();
    const scenario = generate(seed);
    const codec = oracle.codecs.resolve(5);
    const context = (revision: ReturnType<Oracle['mint']> | undefined) => ({ revision, originatorId: oracle.compressor.localSessionId, idCompressor: oracle.compressor, isSummary: false });
    const originals = scenario.edits.map(edit => oracle.build(edit));
    const inputs = originals.map(tagged => {
        const wire = oracle.bytes(tagged.change, [5], tagged.revision)[0];
        assert(wire !== undefined);
        return { wire, revision: tagged.revision, tagged: { revision: tagged.revision, change: codec.decode(JSON.parse(wire), context(tagged.revision)) } };
    });
    const kinds = new Set<string>();
    const inversions = inputs.flatMap((input, index) => {
        const kind = scenario.edits[index]?.kind;
        assert(kind !== undefined);
        if (kinds.has(kind)) return [];
        kinds.add(kind);
        return [{ wire: input.wire, revision: input.revision, results: [false, true].map(rollback => {
            const revision = oracle.mint();
            const result = oracle.family.invert(input.tagged, rollback, revision);
            return { revision, wire: oracle.bytes(result, [5])[0] };
        }) }];
    });
    const groups = new Map<number | undefined, number[]>();
    for (const [index, edit] of scenario.edits.entries()) {
        const group = groups.get(edit.base) ?? [];
        group.push(index);
        groups.set(edit.base, group);
    }
    const selected = new Set<string>();
    const rebases = [...groups.values()].flatMap(group => {
        const a = group[0];
        const b = group[1];
        if (a === undefined || b === undefined) return [];
        const kind = scenario.edits[a]?.kind;
        assert(kind !== undefined);
        if (selected.has(kind)) return [];
        selected.add(kind);
        const base = inputs[a];
        const change = inputs[b];
        assert(base !== undefined && change !== undefined);
        const result = oracle.rebase(change.tagged, base.tagged);
        const composed = oracle.family.compose([base.tagged, result]);
        return [{ base: base.wire, baseRevision: base.revision, change: change.wire, revision: change.revision, result: oracle.bytes(result.change, [5])[0], composed: oracle.bytes(composed, [5])[0] }];
    });
    return { seed, revisionCount: originals.length + inversions.length * 2, inversions, rebases };
});
writeFileSync('../Tests/FluidTreeTests/Fixtures/modular-family.json', JSON.stringify(fixtures));
