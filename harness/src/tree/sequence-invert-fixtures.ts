import { writeFileSync } from 'node:fs';
import { sequenceFieldEditor as editor } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/sequenceFieldEditor.js';
import { invert } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/invert.js';
import { makeV3Codec } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/sequenceFieldCodecV3.js';
import { RevisionTagCodec } from '../../node_modules/@fluidframework/tree/lib/core/rebase/revisionTagCodec.js';
import { DefaultAtomIdAliasAllocator } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/defaultAtomIdAliasAllocator.js';
import type { CrossFieldManager } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/crossFieldQueries.js';
import type { ChangeAtomId } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import type { Changeset } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/types.js';
import { brand } from '../../node_modules/@fluidframework/tree/lib/util/index.js';
import { Oracle } from './oracle.js';
import { Random } from '../random.js';
const oracle = new Oracle();
const revision = oracle.mint();
const codec = makeV3Codec(new RevisionTagCodec(oracle.compressor));
const context = { baseContext: { revision, originatorId: oracle.compressor.localSessionId, idCompressor: oracle.compressor, isSummary: false }, encodeNode: (_id: ChangeAtomId) => ({}) };
const manager: CrossFieldManager<ChangeAtomId> = {
    get: (_target, _revision, _id, count) => ({ length: count, value: undefined }),
    set: () => { throw new Error('Unexpected child change in fixture'); },
    onMoveIn: () => {},
    moveKey: () => {},
};
const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const random = new Random(seed);
    const index = random.int(12);
    const count = 1 + random.int(5);
    const destination = random.int(15);
    const atom: ChangeAtomId = { localId: brand(8), revision: 'root' };
    const marks: Changeset[] = [
        editor.insert(index, count, atom, 'root'),
        editor.remove(index, count, brand(0), 'root'),
        editor.move(index, count, destination, brand(0), atom, 'root'),
        editor.return(index, count, destination, { localId: brand(32), revision: 'root' }, atom, 'root'),
        [{ count, type: 'Rename', cellId: atom, idOverride: { localId: brand(32), revision: 'root' } }],
        [{ count, cellId: atom, type: 'AttachAndDetach', attach: { type: 'MoveIn', id: brand(0), revision: 'root' }, detach: { type: 'Remove', id: brand(16), revision: 'root' } }],
    ];
    return marks.map(change => ({
        input: JSON.stringify(codec.encode(change, context)),
        inverses: [false, true].map(rollback => {
            const ids = new DefaultAtomIdAliasAllocator();
            ids.reserve('root', brand(63));
            return JSON.stringify(codec.encode(invert(change, rollback, ids, revision, manager), context));
        }),
    }));
});
writeFileSync('../Tests/FluidTreeTests/Fixtures/sequence-invert.json', JSON.stringify(fixtures));
