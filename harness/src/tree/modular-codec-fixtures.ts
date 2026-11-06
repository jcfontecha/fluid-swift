import { writeFileSync } from 'node:fs';
import { Oracle, wireVersions } from './oracle.js';
import { generate } from './scenario.js';
const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const oracle = new Oracle();
    const scenario = generate(seed);
    const changes = scenario.edits.map(edit => oracle.build(edit));
    const seen = new Set<string>();
    const selected = changes.flatMap((change, index) => {
        const edit = scenario.edits[index];
        if (edit === undefined || seen.has(edit.kind)) return [];
        seen.add(edit.kind);
        return [{
            kind: edit.kind,
            revision: change.revision,
            wires: wireVersions().map(version => ({ version, bytes: oracle.bytes(change.change, [version], change.revision)[0] })),
            algebra: oracle.bytes(change.change, [5])[0],
        }];
    });
    return { seed, revisionCount: changes.length, changes: selected };
});
writeFileSync('../Tests/FluidTreeTests/Fixtures/modular-codecs.json', JSON.stringify(fixtures));
