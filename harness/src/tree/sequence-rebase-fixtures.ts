import { writeFileSync } from 'node:fs';
import { sequenceFieldEditor as editor } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/sequenceFieldEditor.js';
import { compose } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/compose.js';
import { rebase } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/rebase.js';
import { makeV3Codec } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/sequenceFieldCodecV3.js';
import { RevisionTagCodec } from '../../node_modules/@fluidframework/tree/lib/core/rebase/revisionTagCodec.js';
import { rebaseRevisionMetadataFromInfo } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/index.js';
import { brand, idAllocatorFromMaxId } from '../../node_modules/@fluidframework/tree/lib/util/index.js';
import type { RevisionTag, ChangeAtomId } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import type { MoveEffect } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/moveEffectTable.js';
import { SequenceTestTable } from './sequence-test-table.js';
import { Oracle } from './oracle.js';
import { Random } from '../random.js';
const oracle = new Oracle();
const revision = oracle.mint();
const codec = makeV3Codec(new RevisionTagCodec(oracle.compressor));
const context = { baseContext: { revision, originatorId: oracle.compressor.localSessionId, idCompressor: oracle.compressor, isSummary: false }, encodeNode: (_id: ChangeAtomId) => ({}) };
const metadata = rebaseRevisionMetadataFromInfo([{ revision: 'root' }, { revision }], revision, ['root']);
const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const random = new Random(seed);
    const changes = (tag: RevisionTag) => {
        const index = random.int(8);
        const count = 1 + random.int(3);
        const destination = random.int(12);
        const atom: ChangeAtomId = { localId: brand(8), revision: tag };
        return [editor.insert(index, count, atom, tag), editor.remove(index, count, brand(0), tag), editor.move(index, count, destination, brand(0), atom, tag)];
    };
    const bases = changes('root');
    const news = changes(revision);
    return bases.flatMap(base => news.map(change => {
        const manager = new SequenceTestTable<MoveEffect>();
        const ids = idAllocatorFromMaxId(63);
        let result = rebase(change, base, child => child, ids, manager, metadata);
        const invalidated = manager.invalidated;
        if (invalidated) {
            manager.reset();
            result = rebase(change, base, child => child, ids, manager, metadata);
        }
        const composeManager = new SequenceTestTable<MoveEffect>();
        let composed = compose(base, result, (first, second) => second ?? first ?? { localId: brand(0) }, ids, composeManager, metadata);
        const composeInvalidated = composeManager.invalidated;
        if (composeInvalidated) {
            composeManager.reset();
            composed = compose(base, result, (first, second) => second ?? first ?? { localId: brand(0) }, ids, composeManager, metadata);
        }
        return { composed: JSON.stringify(codec.encode(composed, context)), composeInvalidated, base: JSON.stringify(codec.encode(base, context)), change: JSON.stringify(codec.encode(change, context)), result: JSON.stringify(codec.encode(result, context)), invalidated };
    }));
});
writeFileSync('../Tests/FluidTreeTests/Fixtures/sequence-rebase.json', JSON.stringify(fixtures));
