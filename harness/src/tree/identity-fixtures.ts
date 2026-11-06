import { writeFileSync } from 'node:fs';
import { Random } from '../random.js';
import { Oracle } from './oracle.js';
import { RevisionTagCodec } from '../../node_modules/@fluidframework/tree/lib/core/rebase/revisionTagCodec.js';
import { makeChangeAtomIdCodec } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/changeAtomIdCodec.js';
import { brand } from '../../node_modules/@fluidframework/tree/lib/util/index.js';
import type { ChangeAtomId } from '../../node_modules/@fluidframework/tree/lib/core/index.js';

const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const random = new Random(seed);
    const oracle = new Oracle();
    const ids = Array.from({ length: 1 + random.int(20) }, () => oracle.mint());
    const revision = ids.at(-1);
    const revisionCodec = new RevisionTagCodec(oracle.compressor);
    const atomCodec = makeChangeAtomIdCodec(revisionCodec);
    const localId = random.int(100_000);
    const atoms: ChangeAtomId[] = [
        { localId: brand(localId) },
        { localId: brand(localId), revision },
        { localId: brand(localId), revision: ids[0] },
        { localId: brand(localId), revision: 'root' },
    ];
    const context = { revision, originatorId: oracle.compressor.localSessionId, idCompressor: oracle.compressor, isSummary: false };
    const before = atoms.map(atom => atomCodec.encode(atom, context));
    oracle.compressor.finalizeCreationRange(oracle.compressor.takeNextCreationRange());
    const after = atoms.map(atom => atomCodec.encode(atom, context));
    return { count: ids.length, localId, before, after, revisions: ids.map(id => revisionCodec.encode(id)) };
});
writeFileSync(new URL('../../../Tests/FluidTreeTests/Fixtures/identities.json', import.meta.url), JSON.stringify(fixtures));
console.log('Wrote 1000 real-TS revision/atom codec fixtures.');
