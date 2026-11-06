import { writeFileSync } from 'node:fs';
import { sequenceFieldChangeHandler as seq } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/sequenceFieldChangeHandler.js';
import { optionalChangeHandler as optional } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/optional-field/optionalField.js';
import { DefaultRevisionReplacer, type FieldChangeEncodingContext } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/index.js';
import type { ChangeAtomId, DeltaFieldMap } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import type { Mark } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/sequence-field/types.js';
import type { OptionalChangeset } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/optional-field/optionalFieldChangeTypes.js';
import { RevisionTagCodec } from '../../node_modules/@fluidframework/tree/lib/core/rebase/revisionTagCodec.js';
import { makeChangeAtomIdCodec } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/changeAtomIdCodec.js';
import { brand } from '../../node_modules/@fluidframework/tree/lib/util/index.js';
import { Oracle } from './oracle.js';
import { Random } from '../random.js';
const oracle = new Oracle();
const revision = oracle.mint();
const revisions = new RevisionTagCodec(oracle.compressor);
const atoms = makeChangeAtomIdCodec(revisions);
const context: FieldChangeEncodingContext = {
    baseContext: { revision, originatorId: oracle.compressor.localSessionId, idCompressor: oracle.compressor, isSummary: false },
    encodeNode: id => ({ fieldChanges: [{ fieldKey: brand('test'), fieldKind: brand('test'), change: atoms.encode(id, context.baseContext) }] }),
};
const node = (id: ChangeAtomId) => ({ major: id.revision, minor: id.localId });
const fromChild = (id: ChangeAtomId): DeltaFieldMap => new Map([[brand('child'), { marks: [{ count: 1, detach: node(id) }] }]]);
const rootsFromChild = (id: ChangeAtomId) => [node(id)];
const json = (value: unknown) => JSON.stringify(value, (_key: string, value: unknown) => value instanceof Map ? [...value] : value);
const atom = (id: number): ChangeAtomId => ({ localId: brand(id), revision: 'root' });
const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const random = new Random(seed);
    const count = 1 + random.int(3);
    const index = random.int(5);
    const child = atom(50);
    const marks: Mark[] = [
        ...seq.editor.move(index, count, random.int(12), brand(0), atom(8), 'root'),
        { count: 1, changes: child },
        { count: 1, cellId: atom(30), changes: atom(51) },
        { count, cellId: atom(40), type: 'Rename', idOverride: atom(44) },
        { count, cellId: atom(60), type: 'Remove', id: brand(64), revision: 'root' },
        { count, cellId: atom(70), type: 'AttachAndDetach', attach: { type: 'MoveIn', id: brand(74), revision: 'root' }, detach: { type: 'Remove', id: brand(78), revision: 'root' } },
    ];
    const opt: OptionalChangeset = {
        moves: [[atom(20), atom(21)]],
        childChanges: [['self', child], [atom(20), atom(51)]],
        valueReplace: { isEmpty: random.int(2) === 0, src: random.int(2) === 0 ? 'self' : atom(8), dst: atom(0) },
    };
    const filterAction = seed % 3;
    const filter = {
        preserveOtherEdits: seed % 2 === 0,
        filterDetach: (_id: ChangeAtomId, length: number) => ({ length: Math.min(1, length), value: { action: filterAction, shouldRemoveChild: true } }),
        filterAttach: (_id: ChangeAtomId, length: number) => ({ length: Math.min(1, length), value: { action: filterAction, nodeId: child, newAttachId: atom(90) } }),
    };
    const sw = (change: Mark[]) => JSON.stringify(seq.codecsFactory(revisions).resolve(3).encode(change, context));
    const ow = (change: OptionalChangeset) => JSON.stringify(optional.codecsFactory(revisions).resolve(2).encode(change, context));
    return {
        sequence: sw(marks), optional: ow(opt),
        sequenceDelta: json(seq.intoDelta(marks, fromChild)), optionalDelta: json(optional.intoDelta(opt, fromChild)),
        sequenceRoots: json([...seq.relevantRemovedRoots(marks, rootsFromChild)]), optionalRoots: json([...optional.relevantRemovedRoots(opt, rootsFromChild)]),
        sequenceNested: json(seq.getNestedChanges(marks)), optionalNested: json(optional.getNestedChanges(opt)),
        sequenceKeys: json(seq.getCrossFieldKeys(marks)),
        sequencePruned: sw(seq.rebaser.prune(marks, () => undefined)),
        sequenceReplaced: sw(seq.rebaser.replaceRevisions(marks, new DefaultRevisionReplacer(revision, new Set(['root'])))),
        sequenceFiltered: sw(seq.rebaser.filterEdits(marks, filter)), optionalFiltered: ow(optional.rebaser.filterEdits(opt, filter)),
        preserveOtherEdits: filter.preserveOtherEdits, filterAction,
    };
});
writeFileSync('../Tests/FluidTreeTests/Fixtures/field-handlers.json', JSON.stringify(fixtures));
