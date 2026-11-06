import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { BasicChunk } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/chunked-forest/basicChunk.js';
import { SequenceChunk } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/chunked-forest/sequenceChunk.js';
import { fieldBatchCodecBuilder } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/chunked-forest/index.js';
import { makeModularChangeCodecFamily } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/modularChangeCodecs.js';
import { makeModularChangeset } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/modularChangeUtils.js';
import { newChangeAtomIdBTree } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/changeAtomIdBTree.js';
import { fieldKindConfigurations } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/default-schema/defaultFieldKinds.js';
import { RevisionTagCodec } from '../../node_modules/@fluidframework/tree/lib/core/rebase/revisionTagCodec.js';
import { FluidClientVersion, FormatValidatorNoOp } from '../../node_modules/@fluidframework/tree/lib/codec/index.js';
import type { RevisionTag, TreeChunk, TreeValue } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import { brand } from '../../node_modules/@fluidframework/tree/lib/util/index.js';
import { Oracle } from './oracle.js';
import { Random } from '../random.js';
interface Node { type: string; value?: TreeValue; fields: [string, Node[]][] }
function chunk(node: Node): BasicChunk {
    return new BasicChunk(brand(node.type), new Map(node.fields.map(([key, nodes]) => [brand(key), nodes.map(chunk)])), node.value);
}
const gates = [FluidClientVersion.v2_0, FluidClientVersion.v2_43, FluidClientVersion.v2_80, FluidClientVersion.v2_117];
const versions = [3, 4, 5, 5];
const fixtures = Array.from({ length: 1000 }, (_, seed) => {
    const random = new Random(seed);
    const oracle = new Oracle();
    const revision = oracle.mint();
    const older = oracle.mint();
    const makeNodes = (): Node[] => Array.from({ length: 1 + random.int(3) }, (_, index) => ({
        type: 'N', value: random.int(2) === 0 ? seed + index : `value${seed}\ud800`,
        fields: random.int(2) === 0 ? [] : [['children', [{ type: 'Leaf', value: random.int(2) === 0, fields: [] }]]],
    }));
    const entries = [
        { revision: 'root' as RevisionTag, localId: 11, nodes: makeNodes() },
        { revision, localId: 5, nodes: makeNodes() },
        { revision, localId: 20, nodes: makeNodes() },
        { revision: older, localId: 7, nodes: makeNodes() },
    ];
    const builds = newChangeAtomIdBTree<TreeChunk>();
    for (const entry of entries) builds.set([entry.revision, brand(entry.localId)], new SequenceChunk(entry.nodes.map(chunk)));
    const refreshers = newChangeAtomIdBTree<TreeChunk>();
    const refresher = { revision: older, localId: 40, nodes: makeNodes() };
    refreshers.set([refresher.revision, brand(refresher.localId)], new SequenceChunk(refresher.nodes.map(chunk)));
    const change = makeModularChangeset({ maxId: 50, revisions: [{ revision }], builds, refreshers });
    const isSummary = seed % 2 === 0;
    const context = { revision, originatorId: oracle.compressor.localSessionId, idCompressor: oracle.compressor, isSummary };
    const rows = gates.map((gate, index) => {
        const options = { minVersionForCollab: gate, jsonValidator: FormatValidatorNoOp };
        const codecFamily = makeModularChangeCodecFamily(fieldKindConfigurations, new RevisionTagCodec(oracle.compressor), fieldBatchCodecBuilder.build(options), options);
        const version = versions[index];
        assert(version !== undefined);
        const codec = codecFamily.resolve(version);
        const encoded = codec.encode(change, context);
        const wire = JSON.stringify(encoded);
        assert.equal(JSON.stringify(codec.encode(codec.decode(encoded, context), context)), wire);
        return { version, wire };
    });
    return { entries, refresher, revision, isSummary, rows };
});
writeFileSync('../Tests/FluidTreeTests/Fixtures/modular-chunks.json', JSON.stringify(fixtures));
