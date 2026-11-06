import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { optionalChangeRebaser as rebaser, optionalFieldEditor as editor } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/optional-field/optionalField.js';
import { makeOptionalFieldCodec } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/optional-field/optionalFieldCodecV2.js';
import type { OptionalChangeset, RegisterId } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/optional-field/optionalFieldChangeTypes.js';
import { makeChangeAtomIdCodec } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/changeAtomIdCodec.js';
import { RevisionTagCodec } from '../../node_modules/@fluidframework/tree/lib/core/rebase/revisionTagCodec.js';
import { DefaultAtomIdAliasAllocator, DefaultRevisionReplacer, NodeAttachState, rebaseRevisionMetadataFromInfo } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/index.js';
import { brand } from '../../node_modules/@fluidframework/tree/lib/util/index.js';
import type { ChangeAtomId, RevisionTag } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import type { FieldChangeEncodingContext } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/index.js';
import { SequenceTestTable } from './sequence-test-table.js';
import { Oracle } from './oracle.js';
import { Random } from '../random.js';
const oracle = new Oracle();
const revision = oracle.mint();
const updatedRevision = oracle.mint();
const revisions = new RevisionTagCodec(oracle.compressor);
const atoms = makeChangeAtomIdCodec(revisions);
const codec = makeOptionalFieldCodec(revisions);
const baseContext = { revision, originatorId: oracle.compressor.localSessionId, idCompressor: oracle.compressor, isSummary: false };
const context: FieldChangeEncodingContext = { baseContext, encodeNode: (id: ChangeAtomId) => ({ fieldChanges: [{ fieldKey: brand('test'), fieldKind: brand('test'), change: atoms.encode(id, baseContext) }] }) };
const metadata = rebaseRevisionMetadataFromInfo([{ revision: 'root' }, { revision }], revision, ['root']);
const manager = new SequenceTestTable<never>();
const ids = () => {
    const allocator = new DefaultAtomIdAliasAllocator();
    allocator.allocate(64);
    return allocator;
};
const composeChild = (first: ChangeAtomId | undefined, second: ChangeAtomId | undefined): ChangeAtomId => {
    const result = second ?? first;
    assert(result !== undefined);
    return result;
};
const wire = (change: OptionalChangeset) => JSON.stringify(codec.encode(change, context));
const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const random = new Random(seed);
    const empty = random.int(2) === 0;
    const offset = 100 + random.int(1000);
    const atom = (localId: number, revision: RevisionTag = 'root'): ChangeAtomId => ({ localId: brand(localId), revision });
    const detached = atom(offset);
    const changes = (tag: RevisionTag): OptionalChangeset[] => {
        const fill = atom(8, tag);
        const detach = atom(0, tag);
        const primitives: OptionalChangeset[] = [
            editor.set(empty, { fill, detach }),
            editor.clear(empty, detach),
            { moves: [], childChanges: [], valueReplace: { isEmpty: empty, src: 'self', dst: detach } },
            { moves: [], childChanges: [] },
        ];
        return primitives.map((change, index) => {
            const register: RegisterId = !empty && index % 2 === 0 ? 'self' : detached;
            return {
                ...change,
                moves: index % 2 === 0 ? [[detached, atom(offset + 100, tag)]] : [],
                childChanges: [[register, atom(32 + index, tag)], [atom(offset + 1), atom(40 + index, tag)]],
            };
        });
    };
    const bases = changes('root');
    const news = changes(revision);
    return bases.flatMap(base => news.map(change => {
        const states: string[] = [];
        const rebased = rebaser.rebase(change, base, (change, over, state) => {
            states.push(state === NodeAttachState.Attached ? 'attached' : 'detached');
            return change ?? over;
        }, ids(), manager, metadata);
        const composed = rebaser.compose(base, rebased, composeChild, ids(), manager, metadata);
        return {
            base: wire(base), change: wire(change), rebased: wire(rebased), composed: wire(composed), states,
            replaced: wire(rebaser.replaceRevisions(composed, new DefaultRevisionReplacer(updatedRevision, new Set(['root', revision])))),
            pruned: wire(rebaser.prune(composed, child => child.localId % 2 === 0 ? undefined : child)),
            inverses: [false, true].map(rollback => wire(rebaser.invert(change, rollback, ids(), revision, manager, metadata))),
        };
    }));
});
writeFileSync('../Tests/FluidTreeTests/Fixtures/optional-fields.json', JSON.stringify(fixtures));
