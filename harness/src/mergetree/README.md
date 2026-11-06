# F1 merge-tree handoff

**Incomplete lane; coherent reference-core milestone. No git writes.**

## Resume result (fourth F1 pass, current uncommitted work)

- Red first: full mixed seed 0 reproduced `unsupported reference`; the first
  reference Swift tests failed to compile against the missing API. A second red
  differential exposed ignored backward preference (TS position 1, Swift 2).
- Replaced value `Segment` with identity-bearing `BaseSegment` in its own file.
  Split preserves the left identity, clones metadata for the right, and transfers
  registered references with adjusted offsets. Snapshot serialization uses explicit
  independent clones; existing live V1 property-normalization tests still pass.
- Added `LocalReference` and `LocalReferenceCollection`, plus client reference
  creation/removal/resolution, forward/backward physical sliding after ack, grouped
  tombstone order, synchronous before/after callbacks, simple detachment, stay refs,
  and transient exclusion from collections/split relocation. Pending insertions
  are excluded from physical slide targets. Local refs use weak segment links to
  avoid ARC cycles; the tree currently retains every tombstone.
- The peer supports reference edits/state. Optional `slidingPreference` is 0
  (backward) or 1 (forward, default); refType 0 joins 64/128/256 in the protocol.
  Production farm generation is unchanged. The focused core check additionally
  generates all four reference types and both preferences.
- Green: `npm run check`; 18 merge-tree tests (16 Swift Testing + 2 XCTest);
  500 production TS/TS seeds; 1,000 focused TS/Swift seeds including references,
  insert/remove/annotation, optimistic states, historical lengths, and byte-exact
  pending legacy and V1 snapshots. The original reference-free core check also
  passed 1,000 seeds before expansion.
- Full production TS/Swift remains RED at seed 0, now on physical coalescing after
  minimum advancement: TS emits `\udfff\ud83da\ude00` as one segment where Swift
  retains four separate segments. Text and length match at that failure. No
  assertion weakening or seed skips. Reproduce with the full-farm command below.
- Mutation proof: temporarily registered transient references in collections;
  expanded core differential caught changed reference positions. Restored the
  source and rebuilt the peer. Evidence: `fixtures/planted-reference-divergence.txt`.

### Exact remaining boundary

This is **not completion of item 1 or full acceptance**. Collection storage is an
ordered array, not TS's linked offset buckets; properties on local references,
endpoint sliding, tracking-group linkage/retention, perspective-parameterized public
resolution, and reference walk/compare APIs remain. No physical reclamation occurs,
so lifetime constraints under reclamation are not certified. Do not use this as a
finished SharedString/Matrix reference engine.

Next finish those reference semantics, then follow the requested order: 7-child
MergeBlock + incremental PartialSequenceLengths (including reconnect/removed-on-
insert accounting), physical zamboni and tracked/pending lifetimes, snapshot readers
and reload checkpoints, pending regeneration/rollback/normalization and reconnect.
The large-document/many-client apply-rate benchmark is still owed with the block
index. `MergeTreeClient` still combines Client/MergeTree, BaseSegment still combines
text/marker payloads, and snapshot loader/writer class separation remains.

No other lane files or package manifests were edited. Opus owns review/commit.

## Prior committed baseline (d139330)

## Resume result (third F1 pass)

- Production farm disables obliterate in generation AND oracle construction. The
  exact-prefix seed-175 exclusion was deleted. No production seed skips.
- `npm run check` passes. Production `--peers ts,ts --seeds 0..499` passes all 500
  seeds with strict cross-client convergence and byte-exact snapshot comparisons.
- Seed 197 contains obliterate. Archived original replay passes schedule
  audit and reproduces its TS divergence. The saved minimized fixture FAILS the
  service-minimum audit; do not treat that reduced trace as legal-schedule evidence. Repro/minimizer explicitly opt into
  obliterate; old fixtures and the six-op reproducer remain intact.
- `--obliterate --peers ts,ts --seeds 0..0` passes the full upstream field-farm
  matrix: both range variants, lengths 1–512 doubling, three clients bootstrapped
  from snapshots, 8 rounds, ops/round 1–128 doubling. Uses upstream generators,
  runner, TestClient, and RNG; sided obliterate and annotate-adjust enabled.
  This mode is upstream three-client convergence, not shadow Swift differential.
  Swift mode is rejected explicitly. Only seed 0 was run (upstream default count).
- Added `PropertiesManager` matching the production raw-property subset of
  `segmentPropertiesManager.ts`: local overlays, raw remote consensus, FIFO ack,
  split-independent value histories and legacy snapshot property reconstruction.
  Adjust is off by default and NOT implemented, as are rollback/event deltas.
- First new Swift test failed with unsupported type 2, then passed. All 13
  merge-tree tests pass (11 Swift Testing plus two XCTest). Expanded core-check
  passes 1,000 TS/Swift seeds with insert/remove/annotation, optimistic states,
  pending legacy snapshots, historical lengths and V1/legacy blobs.
- Differential testing caught the V1 writer's live empty-property normalization.
  Swift now preserves this side effect, including not mutating coalesced clones.
- Full production `--peers ts,swift --seeds 0..999` still fails seed 0 on
  unsupported `reference`. This is NOT the 1,000-seed full acceptance result.
- Temporarily reversed `leaf.insertion < stamp`. The FULL farm caught seed 0:
  TS text units `[55357,56832,55296]`, Swift `[55296,55357,56832]`.
  `fixtures/planted-tie-break.jsonl` preserves the trace. Mutation reverted and
  peer rebuilt. No mutation switch or weakened assertion remains.

## Commands

From repo root:

```sh
swift build --scratch-path .build/f1 --product FluidMergeTreePeer
swift test --scratch-path .build/f1 --filter FluidMergeTreeTests
```

Concurrent E1/H2 changes temporarily broke unrelated targets during global test
builds. To build and run only this lane on this Xcode SwiftPM installation:

```sh
swift build --scratch-path .build/f1 --target FluidMergeTreeTests
xcrun xctest .build/f1/out/Products/Debug/FluidMergeTreeTests.xctest
```

That invocation executes BOTH XCTest and Swift Testing tests; exit 0, 13 pass.
No other lane's files were changed to make the build pass.

From `harness`:

```sh
npm run check
npx tsx src/mergetree/core-check.ts
npm run fuzz:mergetree -- --peers ts,ts --seeds 0..499
npm run fuzz:mergetree -- --peers ts,swift --seeds 0..999
npm run fuzz:mergetree -- --obliterate --peers ts,ts --seeds 0..0
npx tsx src/mergetree/obliterate-repro.ts
npx tsx src/mergetree/reproduce.ts ./fixtures/seed-197.json # intentionally red
```

The experimental mode prepares the unpublished stochastic-test-utils RNG subset
from read-only pinned reference sources into ignored `harness/node_modules`.
TypeScript transpiles it without algorithm changes; `best-random@1.0.0` is the
only added dev dependency (and lock entry). npm's merge-tree package already
ships all field operations and runner helpers. The production oracle never loads
these test dependencies.

**Seed skips:** upstream client.obliterateFarm has NO seed skips. SharedString's
separate fuzz suite skips 51 (AB#7220), 71 (AB#35446), 68 (AB#45138). These are
recorded in obliterate-farm.ts but not misapplied to this different workload.
Upstream excludes removeWithField (field-model limitation) and grouped field
replacement (AB#31001); we use exactly its operation set and paired messages.

## Architecture and remaining work, in order

`BaseSegment` now has stable class identity and UTF-16 text/marker payload, insertion
and ordered removal stamps; property histories copy on split. `MergeTreeClient`
still owns a linear segment array. `PartialLengths` remains standalone, not a block index.
The §4 class split is still owed beyond the new PropertiesManager type.

1. Finish reference APIs and tracking/retention constraints listed above. Stable
   identity, split transfer and core sliding now have differential coverage.
2. Split Client/MergeTree/BaseSegment/TextSegment/Marker responsibilities; integrate
   PartialSequenceLengths into 7-child MergeBlocks with incremental updates and
   reconnect adjustments. No linear hot-path performance claim is made.
3. Physical zamboni respecting pending groups/tracking/reference lifetimes.
4. SnapshotLoader plus legacy/V1 readers, catchup operations, attribution and
   reload checkpoints; split existing writer into SnapshotLegacy/SnapshotV1.
5. Pending regeneration, rollback and reconnect, including property rollback and
   event deltas. Numeric annotate-adjust belongs to the experimental option set
   and is not implemented by this production-only raw-property milestone.
6. Full 1,000-seed mixed acceptance with references and reconnect enabled; rerun
   all gates and mutation proof after remaining implementation changes.

Obliterate Swift implementation is explicitly outside this lane. Do not wire the
incomplete client into SharedString/intervals or SharedMatrix yet.
