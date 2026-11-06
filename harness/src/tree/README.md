# T1 — native SharedTree change family

T1 implements the requested change-family lane in native Swift. No git writes
were performed; Opus owns review and commits. Build with `--scratch-path .build/t1`.
Other lanes' source files are not part of this handoff. The only T1 addition to
the shared package manifest is the `FluidTreePeer` executable target.

## Verification

Final post-mutation runs:

- `npm run fuzz:tree-changes -- --self --seeds=1000`: passes.
- `npm run fuzz:tree-changes -- --seeds=1000`: passes against native Swift,
  with **both original comparison contracts**, including the added axioms.
- `scenario-check.ts`: every generated branch applies to its declared parent;
  original seed-75 misplaced revive, fresh-insert ordering, moved-away empty
  cells and overlapping moves have explicit regressions.
- `wire-check.ts`: 1,000 seeds, **73,644 individual edits**, all four writer gates.
- Strict TypeScript check scoped to `src/tree/*.ts`: passes.
- `FluidTreeTests`: **82 tests in 6 suites pass** in the current shared checkout
  (this includes the concurrently added T2 forest/schema suites).

Logs: `/tmp/t1-final-native.log`, `/tmp/t1-final-self.log`,
`/tmp/t1-final-swift-build.log`, `/tmp/t1-final-swift-tests.log`.

The native tie-break comparator was changed from `>` to `<`. A successful native
release build then failed the **full transport** at seed 0, row 438, with different
wire bytes and structural data. The source was restored byte-for-byte, then both
1,000-seed gates passed again. Durable evidence:
[`fixtures/planted-native-tiebreak.txt`](fixtures/planted-native-tiebreak.txt) and
[`fixtures/planted-native-tiebreak.json`](fixtures/planted-native-tiebreak.json).
The earlier field-only mutation evidence is retained separately.

## Contracts — unchanged

1. **Algebra:** compose, undo, rollback, rebase and chains use modular format 5
   with no implicit revision. Exact bytes and the tagged structural projection
   are compared. Maps, sets, explicit undefined, property order, metadata and
   exposed B-tree/COW internals are not sorted away or discarded.
2. **Individual edits:** the edit revision supplies the context. Real Message
   codec gates 2.0/2.43/2.80/2.117 select modular 3/4/5/5, sequence 2/3/3/3 and
   optional 2. Native and TS bytes must match at every gate.

The peer computes changes and algebra in Swift; it receives only scenario input,
not TS answers. Native codec results also byte-roundtrip through native decoding.
The TS oracle retains its semantic and byte-roundtrip assertions. Failure traces
include the scenario and first divergent row; `*-records.json` retains all rows.
`structure-diff.py` explains those traces without changing the comparison.
`native-wire-check.ts`/`--wire-only` remain explicitly diagnostic, never the final
certification path. There is no TS substitute or skipped seed in native mode.

## Valid histories and axioms

`DocumentState` follows upstream FieldStateTree/DetachedNodeTracker conventions:
three siblings share an input state, and the first advances the trunk. It tracks
live node identity, nested children, optional occupancy, detached roots and
**empty-cell identity separately from root ownership**. Move sources remain
empty cells after their nodes move elsewhere. New attaches precede older empty
cells at a gap; an overlapping move follows the editor's split source ordering.
Prerequisite edits are actual inserts/removes, and revives reference real detach
revision/local-ID ranges. No roots are invented at arbitrary positions.

The additional sandwich checks exposed the second generator defect at seed 18:
moved-away cells had been forgotten. Its regression and the insert-order
regression are in `scenario-check.ts`; the earlier red evidence is
`/tmp/t1-history-state-red.log`. The repaired histories pass all 1,000 axiom seeds.

`axioms.ts` covers singleton/empty compose identities, rebase over empty, empty
rebase, inverse cancellation, do/undo and undo/redo rebase, left distributivity,
compose associativity (including rollback sandwiches), and composed versus
individual sandwich rebase. It follows the enabled upstream suites in
`test/rebaserAxiomaticTests.ts`; upstream-skipped right distributivity is not
claimed. Axiom equality uses observable deltas: it coalesces offsets, expands
contiguous runs per cell, removes invisible child maps, and compares the explicitly
unordered global/rename collections by identity. **Every raw result is also
recorded under the strict differential contracts above.** This semantic axiom
comparison does not normalize the native-vs-TS structural comparison.

## Native implementation map

- Identity: RevisionTagCodec, ChangeAtomIdCodec, DefaultAtomIdAliasAllocator and
  DefaultRevisionReplacer.
- Sequence: SequenceFieldEditor, mark effects/factory/queues, compose/invert/rebase,
  V2/V3 codecs, pruning, revision replacement, edit filtering, nested metadata,
  cross-field keys, removed roots and delta conversion.
- Optional: RegisterMap, editor, register-move algebra, V2 codec, filtering,
  revision replacement, removed roots and delta conversion. Required fields use
  the same register representation; generic and no-change fields are dispatched.
- Modular: ModularChangeFamily, EditBuilder/ModularEditBuilder, node/field maps,
  aliases and parents, ranged cross-field queries, invalidation/amendment,
  constraints, pruning, revision replacement, refreshers, validation, delta,
  build/destroy cancellation and codecs 3/4/5.
- Collections: BTree/BNode/BNodeInternal and exact union cursor/frontier logic
  mirror `@tylerbu/sorted-btree-es6` **2.1.1**. RangeMap and its union mirror the
  tree package. Structure fixtures caught and fixed deferred-size accounting.
- Provenance: compact typed property orders preserve JS object construction and
  spread behavior without changing semantic identity/equality. Detached IDs and
  editor IDs can have different enumeration order. Explicit undefined rollback
  metadata, legacy codec normalization and inverted-node property order are tested.
- Transport: `Sources/FluidTreePeer/main.swift`, native NDJSON over stdin/stdout.

Each implementation names its TS source. No Foundation JSON, `Any`, decoded-data
force unwraps or swallowed `try?` errors are used on the T1 wire/persistence path.
All algebra below the peer I/O boundary is synchronous.

## Additional differential evidence

Swift fixtures include 1,000 scenarios each for identity, sequence editors,
sequence codecs, inversion, sequence compose/rebase, optional algebra, handlers,
B-tree operations, B-tree union, range operations and range union. Modular codec
fixtures cover 32,000 gated plus 8,000 context-free roundtrips; modular family
fixtures cover 16,000 undo/rollback, 8,000 rebase and 8,000 compose results. These
are supplementary to the full native farm, not replacements for it.

`ModularForestCodec` now connects the modular codec to the real native T2
`FieldBatchCodec`, using its public BasicChunk/UniformChunk/SequenceChunk APIs.
T1 did not modify those provider files. Another 1,000 fixtures check **4,000**
writer-gated build/refresher encodings and decoded content against the TS codecs,
including FieldBatch's 2.73 format boundary. Native tests also cover summary/op
identifier contexts and build/rollback cancellation.

Coverage is the change-family lane and the eight enabled farm edit kinds:
insert, remove, move, revive, set, clear, crossMove and nested. Outer Message,
container/network behavior and on-device performance are outside this lane.
Chunk payload wire integration is tested separately; the change-algebra farm
does not compare private forest-storage layouts or enable build-chunk edits as
another algebra kind. `modularStructure` rejects such unsupported chunk snapshots
rather than silently omitting them.

## Reproduction

From `harness`:

```
npx tsc --noEmit --target ES2022 --module NodeNext --moduleResolution NodeNext --strict --noUncheckedIndexedAccess --skipLibCheck src/tree/*.ts
npx tsx src/tree/scenario-check.ts
npx tsx src/tree/wire-check.ts
npm run fuzz:tree-changes -- --self --seeds=1000
npm run fuzz:tree-changes -- --seeds=1000
```

From the repository root:

```
swift build --scratch-path .build/t1 --target FluidTreeTests
xcrun xctest .build/t1/out/Products/Debug/FluidTreeTests.xctest
```

This target-only route avoids compiling unrelated in-progress lanes. Run xctest
only after a successful build, and read Swift Testing's final count, not XCTest's
legacy zero-test line. The native farm itself builds the release peer in `.build/t1`.

Fixture generators are the `*-fixtures.ts` files here. No npm install is needed.
`codec-precondition.ts` and `history-precondition.ts` retain the original upstream
assertion reproductions; they are documentation, not exceptions in the farm.
