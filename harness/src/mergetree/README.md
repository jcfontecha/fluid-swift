# F1 merge-tree handoff

Uncommitted implementation; Opus owns review and commits. No git writes performed.
All changes stay in F1's targets/harness and this protocol's merge-tree section.
Obliterate remains excluded from the production farm.

## Current implementation

- `Client` owns wire operations, collaboration counters, pending message identity,
  acknowledgement, regeneration and rollback. `MergeTree` owns the physical tree,
  insertion/range mutation, normalization and reclamation.
- `MergeBlock` splits eight children into four/four (seven stable children), and
  packs underflowing parents like TS. Zamboni processes two heap entries per call,
  preserves TS equal-priority heap ordering, and respects pending/tracking groups.
- `PartialSequenceLengths` maintains historical/client contributions up affected
  paths, collapses history at minimum advancement, and supplies indexed lengths.
  Boundary/insertion/range searches descend blocks. Current-ref reconnect
  queries use incremental local-sequence deltas too. Two-dimensional queries
  against older reference sequences explicitly evaluate retained segments.
  Minimum advancement prunes the root immediately and cold blocks lazily.
- `BaseSegment`, `TextSegment`, `Marker`, `SegmentGroup`, `TrackingGroup` and
  `TrackingGroupCollection` preserve identities. Split halves append to pending
  groups (not document order); this matters for later scour scheduling.
- `LocalReference`/`LocalReferenceCollection` preserve registered refs across
  split/append and retain detached segment identity without ARC cycles. Endpoint
  sliding is opt-in at both client and reference level. Transients do not join
  collections. Simple, slide, stay and transient refs in both directions are tested.
- `SnapshotLegacy`, `SnapshotV1`, shared chunk emission, and `SnapshotLoader` cover
  legacy/V1 chunks, old singular removal client IDs, catchup replay, retained
  ordinary-removal metadata and empty-property normalization. Mixed universal/
  sequenced body chunks have a direct TS differential fixture.
- Pending regeneration preserves submitted message grouping across repeated
  reconnects, drops already-remotely-removed edits, and normalizes physical order.
  Group ack advances current sequence only after all child operations. Rollback
  handles insertion/removal/raw properties, including removed-segment properties.
  Normalization callbacks run once per current/local sequence pair.

## Validation and evidence

- `npm run check` green.
- 32 Swift tests green: 30 Swift Testing plus 2 XCTest.
- 500 TS/TS seeds green with production edits, rollback, repeated reconnect,
  legacy/V1 reloads, including V1 reload before minimum advancement.
- Mixed 1,000-seed farms passed through each expansion: zamboni; indexed tree;
  snapshot reload; reconnect/rollback/reload. The final expanded farm also passed
  all 1,000 seeds with retained-metadata reload, repeated reconnect, lazy minimum
  pruning and incremental current-ref reconnect lengths.
- `reference-check.ts`: 32 endpoint/reference combinations pass across removal,
  reclamation and insertion into the emptied document.
- `snapshot-check.ts`: legacy catchup replay, multichunk V1 and mixed universal /
  sequenced body segments match TS.
- Mutation proof: disabled `TextSegment.canAppend`; full seed 0 caught byte-exact
  snapshot divergence. Restored the source and rebuilt. Evidence is
  `fixtures/planted-zamboni-divergence.txt`. No mutation switch remains.
- Earlier reference and tie-break mutation fixtures remain intact.

Important bugs found by the differential: seed 0 physical coalescing; seed 46
pending-group split order; seed 285 pending overlapping-remover IDs in V1; seed
533 grouped-ack sequence advancement suppressing scour scheduling. No seed skips
or weakened comparisons were introduced.

## Benchmark

Run `npx tsx src/mergetree/benchmark.ts` after building the peer. Debug build,
4,000 sequenced 256-unit inserts from 32 writers, 1,024,000 UTF-16 units, minimum
held at zero during timing. JSON-RPC transport included; final content verification
and minimum advancement excluded from timing.

| Implementation | Seconds | Ops/sec |
| --- | ---: | ---: |
| Physical tree, before indexed lengths/search | 10.195124 | 392.34 |
| Final indexed implementation | 0.967756 | 4,133.27 |

10.5x on this Mac. Not a release-build or on-device claim. Reconnect and snapshot
loading are not part of this benchmark.

## Commands

From repo root (never share another lane's scratch path):

```sh
swift build --scratch-path .build/f1 --product FluidMergeTreePeer
swift build --scratch-path .build/f1 --target FluidMergeTreeTests
xcrun xctest .build/f1/out/Products/Debug/FluidMergeTreeTests.xctest
```

The target-specific test build avoids unrelated concurrent targets. `xctest`
executes both XCTest and Swift Testing on this Xcode installation.

From `harness` (no npm install required):

```sh
npm run check
npm run fuzz:mergetree -- --peers ts,ts --seeds 0..499
npm run fuzz:mergetree -- --peers ts,swift --seeds 0..999
npx tsx src/mergetree/reference-check.ts
npx tsx src/mergetree/snapshot-check.ts
npx tsx src/mergetree/benchmark.ts
npx tsx src/mergetree/core-check.ts
```

## Deliberate boundaries

The production edit set is text/marker insertion, ordinary removal and raw
annotation. Obliterate, numeric annotation adjustment, and attribution-policy
integration are not implemented. Attributed snapshots fail explicitly when no
policy is available, rather than silently discarding attribution. There is no
SharedString/SharedMatrix integration claim, nor a complete public revertible /
interval event API. Tracking groups retain both segments and reference objects;
reference retention across split and physical reclamation has a Swift regression.

## Experimental oracle evidence retained

`--obliterate --peers ts,ts --seeds 0..0` runs the pinned upstream field farm,
not the production shadow protocol. Swift is rejected explicitly. Seed 0 passed
all lengths 1–512, ops/round 1–128, eight rounds, three snapshot-bootstrapped clients,
sided obliterate and annotate-adjust. The production oracle never loads these
private test dependencies. Do not run npm install.

Seed 197's original archived replay is a legal-schedule TS divergence; its saved
minimized trace fails the service-minimum audit. The upstream merge-tree farm has
no seed skips. SharedString's unrelated 51/71/68 exclusions are not applied here.
