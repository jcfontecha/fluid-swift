# merge-tree — client 3.11.0

## 1. Role

Merge-tree is the synchronous ordered-segment engine beneath SharedString/SharedSegmentSequence and SharedMatrix's row and column vectors. `Client` translates DDS operations and runtime envelopes into tree perspectives/stamps and handles acknowledgement, snapshot loading and pending-op regeneration. Sources: `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:169`, `reference/fluidframework-3.11.0/packages/dds/sequence/src/sequence.ts:542`, `reference/fluidframework-3.11.0/packages/dds/matrix/src/permutationvector.ts:129`.

This is the package index. Its normative sections are split by implementation boundary; read **all four area specs**, not just this index:

- [Model, perspectives, partial lengths and reclamation](merge-tree/model.md).
- [Operations, concurrent ordering and properties](merge-tree/operations.md).
- [Local references and reconnect](merge-tree/references-reconnect.md).
- [Snapshots and attribution](merge-tree/snapshots.md).

## 2. Surface used by other packages

Port `Client` (local mutation, remote apply, pending metadata, reconnect positions, collaboration, serialization), `BaseSegment`/`ISegment` and `Marker`/`TextSegment`, delta/maintenance callback types, local references and reference flags, property manager, op builders, sequence places, tracking groups and revertible support. These are the actual dependencies used by sequence and matrix; see `reference/fluidframework-3.11.0/packages/dds/sequence/src/sequence.ts:29`, `reference/fluidframework-3.11.0/packages/dds/sequence/src/intervals/sequenceInterval.ts:13`, `reference/fluidframework-3.11.0/packages/dds/matrix/src/permutationvector.ts:13`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/index.ts:6`.

## 3. Wire and persisted formats

[Operations §3](merge-tree/operations.md#3-wire-and-persisted-formats) specifies types 0–5 and group operations. [Snapshots §3](merge-tree/snapshots.md#3-wire-and-persisted-formats) specifies both version-absent legacy chunks and version `"1"`, including older removal metadata, literal chunk examples, and live obliterate state that V1 does not persist. Segment payload is supplied by each DDS, not hardwired to text: `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:193`.

## 4. Behavior

Use the area algorithms in this order: construct model → choose perspective/stamp → resolve/split range → mutate and event → acknowledge → advance collaboration window/reclaim → regenerate pending operations on reconnect. Mutation events happen before `currentSeq` advancement, so observers must see the just-applied edit even inside callbacks. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:1356`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1120`.

## 5. Invariants and asserts

The area specs identify the important assert codes. Preserve the distinction between a retained invisible segment (length zero), a reclamation-eligible segment (length undefined) and a detached reference (position -1); they do not participate identically in insertion walks. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:724`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1866`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/referencePositions.ts:104`.

## 6. JS-semantics hazards

**All text positions are UTF-16 code units, including offsets between surrogate halves.** Never convert them to Swift Character or Unicode-scalar indices. Exact segment boundaries, optional fields, JS key order and synchronous event timing also affect summary bytes. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/textSegment.ts:55`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/textSegment.ts:95`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotV1.ts:118`.

## 7. Test assets to reuse

The test directories cited in the area specs are executable algorithm oracles, not alternative specifications. Pair them with sequence snapshot goldens and matrix reconnect/rollback tests because those consumers exercise merge-tree's metadata lifetimes. `reference/fluidframework-3.11.0/packages/dds/sequence/src/test/snapshotFormat.spec.ts:1`, `reference/fluidframework-3.11.0/packages/dds/matrix/src/test/matrix.reconnect.spec.ts:1`.

## 8. Open questions

No intended semantics are inferred beyond the checked-in 3.11.0 implementation. Its known limitations are retained explicitly in the area specs, particularly collapsed ordinary-remove timestamps in V1 snapshots and feature-gated obliterate reconnect. These are compatibility constraints, not invitations to repair the TS algorithm in Swift. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:126`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:981`.
