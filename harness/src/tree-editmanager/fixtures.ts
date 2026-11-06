import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { EditManager } from '../../node_modules/@fluidframework/tree/lib/shared-tree-core/editManager.js';
import type { ModularEditBuilder } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/modularChangeFamily.js';
import type { ModularChangeset } from '../../node_modules/@fluidframework/tree/lib/feature-libraries/modular-schema/modularChangeTypes.js';
import { CommitKind, tagChange, type GraphCommit, type RevisionTag } from '../../node_modules/@fluidframework/tree/lib/core/index.js';
import { brand } from '../../node_modules/@fluidframework/tree/lib/util/index.js';
import type { SeqNumber } from '../../node_modules/@fluidframework/tree/lib/shared-tree-core/editManagerFormatCommons.js';
import { World, metadataTree, sessionId, type EditSpec, type SummaryFormat } from './world.js';

// Writes Tests/FluidTreeTests/Fixtures/edit-manager.json: a fixed three-session history driven
// through the real TS EditManager API. EditManagerTests.swift replays the same calls.
const world = new World(0);
type Manager = EditManager<ModularEditBuilder, ModularChangeset>;
const observer: Manager = new EditManager(world.family, sessionId(0), () => world.mint());
const local: Manager = new EditManager(world.family, sessionId(1), () => world.mint());
const remote = sessionId(2);
const spec = (kind: EditSpec['kind'], field: EditSpec['field'], index: number, count: number): EditSpec => ({ kind, field, index, count, destination: 0, metadata: 0 });
const commit = (revision: RevisionTag, edit: EditSpec, metadata = 0): GraphCommit<ModularChangeset> => ({ revision, change: world.build(edit, revision), customMetadata: metadataTree(metadata) });
const seq = (n: number) => brand<SeqNumber>(n);

const r1 = world.mint();
const c1 = commit(r1, spec('insert', 'a', 0, 2), 1);
local.getLocalBranch('main').apply(tagChange(c1.change, r1), CommitKind.Default, c1.customMetadata);
const r2 = world.mint();
const c2 = commit(r2, spec('insert', 'a', 0, 1));
const r3 = world.mint();
const c3 = commit(r3, spec('remove', 'a', 0, 1), 2);
const r4 = world.mint();
const c4 = commit(r4, spec('insert', 'b', 0, 1));
const r5 = world.mint();
const c5 = commit(r5, spec('nested', 'a', 1, 2));
local.getLocalBranch('main').apply(tagChange(c5.change, r5), CommitKind.Default, undefined);

for (const manager of [observer, local]) {
    manager.addSequencedChanges([c1], sessionId(1), seq(1), seq(0), 'main');
    manager.addSequencedChanges([c2], remote, seq(2), seq(0), 'main');
}
// A two-commit batch, delivered to the observer in two bunches.
observer.addSequencedChanges([c3], remote, seq(3), seq(2), 'main');
observer.addSequencedChanges([c4], remote, seq(3), seq(2), 'main');
local.addSequencedChanges([c3, c4], remote, seq(3), seq(2), 'main');
for (const manager of [observer, local]) {
    manager.advanceMinimumSequenceNumber(seq(1));
}

const summaries = (manager: Manager): string[] => {
    const data = manager.getSummaryData();
    return ([3, 4, 6, 7, 'shared'] satisfies SummaryFormat[]).map(format => JSON.stringify((world.summaryCodecs.get(format) ?? assert.fail()).encode(data, world.encodingContext)));
};
const commitRows = (commits: readonly GraphCommit<ModularChangeset>[]): string[] => commits.flatMap(c => [world.encodeRevision(c.revision), world.changeBytes(c.change, c.revision)]);

const fixture = {
    observerSummaries: summaries(observer),
    localTrunk: commitRows(local.getTrunkCommits('main')),
    localCommits: commitRows(local.getLocalCommits('main')),
    longestBranch: [observer.getLongestBranchLength(), local.getLongestBranchLength()],
    reloaded: '',
    trimmedSummary: '',
};
const loaded: Manager = new EditManager(world.family, sessionId(3), () => world.mint());
const v7 = world.summaryCodecs.get(7) ?? assert.fail();
loaded.loadSummaryData(v7.decode(JSON.parse(fixture.observerSummaries[3] ?? assert.fail()), { idCompressor: world.compressor, isSummary: true }));
fixture.reloaded = summaries(loaded)[4] ?? assert.fail();
observer.advanceMinimumSequenceNumber(seq(3));
fixture.trimmedSummary = summaries(observer)[3] ?? assert.fail();

const out = resolve(import.meta.dirname, '../../../Tests/FluidTreeTests/Fixtures/edit-manager.json');
writeFileSync(out, JSON.stringify(fixture, null, 1) + '\n');
console.log(`wrote ${out}`);
