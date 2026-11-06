import { writeFileSync } from 'node:fs';
import { makeV2Codec } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/sequenceFieldCodecV2.js';
import { makeV3Codec } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/sequenceFieldCodecV3.js';
import { RevisionTagCodec } from '../../node_modules/@fluidframework/tree/lib/core/rebase/revisionTagCodec.js';
import type { Mark, MarkEffect } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/types.js';
import type { ChangeAtomId } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import { brand } from '../../node_modules/@fluidframework/tree/lib/util/index.js';
import { Oracle } from './oracle.js';
import { Random } from '../random.js';
const oracle = new Oracle();
const revision = oracle.mint();
const codecRevision = new RevisionTagCodec(oracle.compressor);
const codecs = [makeV2Codec(codecRevision), makeV3Codec(codecRevision)];
const baseContext = { revision, originatorId: oracle.compressor.localSessionId, idCompressor: oracle.compressor, isSummary: false };
const context = { baseContext, encodeNode: (_id: ChangeAtomId) => ({}) };
const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const random = new Random(seed);
    const atom: ChangeAtomId = { localId: brand(random.int(100)), revision: 'root' };
    const id = atom.localId;
    const effects: MarkEffect[] = [
        {},
        { type: 'Insert', id, revision },
        { type: 'Remove', id, revision, idOverride: atom },
        { type: 'MoveIn', id, revision, finalEndpoint: atom },
        { type: 'MoveOut', id, revision, finalEndpoint: atom, idOverride: atom },
        { type: 'Rename', idOverride: atom },
        { type: 'AttachAndDetach', attach: { type: 'MoveIn', id, revision }, detach: { type: 'Remove', id, revision, idOverride: atom } },
    ];
    const marks: Mark[] = effects.map(effect => ({ count: 1 + random.int(5), ...effect, cellId: atom }));
    return codecs.map((codec, i) => ({ version: i + 2, wire: JSON.stringify(codec.encode(marks, context)) }));
});
writeFileSync('../Tests/FluidTreeTests/Fixtures/sequence-codecs.json', JSON.stringify(fixtures));
