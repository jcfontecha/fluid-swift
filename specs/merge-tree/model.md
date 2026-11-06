# merge-tree: model, perspectives, partial lengths, zamboni

## 1. Role

Defines the ordered retained segment graph and the length of every subtree from a participant's historical view. It is shared by all merge-tree DDSes, independent of segment payload. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:130`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:341`.

## 2. Surface used by other packages

`ISegment` exposes type, cachedLength, properties, trackingCollection, attribution, clone/split/append/JSON conversion. `ISegmentInternal` adds localRefs and imaginary endpoint identity. The tree-private leaf adds parent/index/ordinal, insertion stamp, optional ordered removals, property manager and segment groups. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:55`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:137`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/segmentInfos.ts:13`.

## 3. Wire and persisted formats

Tree blocks and partial-length tables are not serialized. Persist segments and their merge metadata using [snapshots](snapshots.md). Internal stamps are `{seq, clientId, localSeq?}` plus type `insert`, `setRemove` or `sliceRemove`; IDs here are short per-client integers, whereas snapshots use long client strings. Constants: universal seq 0, unassigned seq -1, maintenance seq -2; local client -1, non-collaborating -2, squash client -3. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/stamps.ts:29`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/constants.ts:14`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotV1.ts:290`.

## 4. Behavior

### Segments and blocks

A stable block has at most **7 children**. `MaxNodesInBlock=8` includes the temporary overflow slot; insertion splits 8 children into 4 and 4, propagating a sibling upward and creating a two-child root if necessary. Reload groups consecutive nodes into blocks of at most 7, recursively. Store childCount separately from array capacity; repair parent, index and ordinal whenever assigning/moving a child. Cached length is the local visible aggregate; partial lengths answer other perspectives. Tile caches contain leftmost/rightmost visible marker for each label. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:248`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:755`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1948`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1978`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:2823`.

Ordinals are hierarchical **UTF-16 strings used by JS lexicographic comparison**, not numeric positions. For a block, width=`1 << (8-childCount)`; first child suffix is width-1; next suffix is the previous last code unit + width. Prefix is parent ordinal. Temporary split suffix is NUL. Tree reorder must update tracking sets whose ordering depends on ordinals. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/ordinal.ts:9`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:400`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:2671`.

Split: reject pos<=0; payload-specific split produces right half; copy parent/index temporary ordinal, insertion stamp, removal array, obliterate context, tracking membership and split attribution. Tree split then copies pending segment groups and property manager and transfers refs at offsets >=pos to the right with offsets reduced by pos, before SPLIT maintenance callback. Append transfers refs **before increasing cachedLength**, appends attribution, then adds lengths. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:389`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1772`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/localReference.ts:471`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:439`.

The concrete block fields are `children` (capacity 8), `childCount`, optional `needsScour`, optional `parent`, index (initial 0), ordinal (initial empty string), cachedLength (number or undefined, initially 0), rightmostTiles/leftmostTiles maps, and optional partialLengths (defined outside transient structural updates). Root has no parent. Segment insertion/removal stamps are immutable records replaced at ack, not mutated shared stamps; removes is an ordered list containing both setRemove and sliceRemove, not independent booleans. Segment groups hold ordered membership plus original localSeq/refSeq/previousProps/obliterateInfo. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:234-304`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/stamps.ts:12-83`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/segmentInfos.ts:208-249`.

### Exact perspective predicates

Define `ackedLE(s,R) = s.seq != -1 && s.seq <= R`. Presence is `(no insert || occurred(insert)) && !removes.some(occurred)`. This predicate considers **every removal**, not just the first. Distinguish these implementations:

| Perspective | occurred(stamp) |
|---|---|
| Prior(R,C), remote operation | ackedLE(stamp,R) OR stamp.clientId==C |
| LocalReconnecting(R,C,L) | ackedLE(stamp,R) OR (localSeq defined AND localSeq<=L) |
| LocalDefault(C), application | true |
| LocalSquash(R,C,L) | same occurred as reconnect; additionally hide any pending-inserted (insert.seq==-1) segment with any removal |
| RemoteObliterate(C) | true except a local `setRemove`/`sliceRemove` stamp |

`reference/fluidframework-3.11.0/packages/dds/merge-tree/src/perspective.ts:53`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/perspective.ts:80`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/perspective.ts:104`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/perspective.ts:132`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/perspective.ts:178`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/perspective.ts:200`.

Leaf length first returns **undefined** if the first removal has occurred by the minSeq/non-collaborating perspective; otherwise returns cachedLength if present, zero if not. Undefined means absent for conflict-resolution purposes even if still physically retained. Insertion walk skips undefined leaves except on the far-right path, where it treats them as zero to reach the end. Block length uses cachedLength for the local full view (including event callbacks before currentSeq advances); historical local queries compute local partials lazily; other views query partials. **RemoteObliterate is not a valid general-purpose partial-length perspective**: its range walk uses special visibility handling. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:724`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1120`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1866`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/perspective.ts:191`.

`wasRemovedOnInsert` is true exactly when a first removal exists and is acked, and insertion is pending OR insertion.seq>firstRemoval.seq. First removal missing/pending makes it false. This predicate is not equivalent to the segment having any sliceRemove: the relative ordering matters. Detached stamp minting still sets localSeq (initially 0) although seq=0; collaborating mint increments localSeq then emits seq=-1. Readers should not infer pending solely from localSeq being present. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/segmentInfos.ts:284-295`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:685-694`.

### Partial-length accounting

A partial set is sorted by sequence. Each entry is `{seq,len,seglen,clientId?}`: seglen is delta at that sequence; len is cumulative delta, **not total including minLength**. Inserting nonzero delta sets len from predecessor+delta and adds delta to every later entry; equal sequence coalesces (client must match). Keep baseline `minLength`, global sequenced partial set `G`, sparse per-client sets `A[C]`, and optional local data `U` plus a 2D adjustment map keyed first by reference sequence, then local sequence. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:25`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:114`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:133`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:312`.

Let prefix(S,x)=last cumulative len with seq<=x, or 0. Query:

```
base = minLength + prefix(G,R)
remote(R,C) = base + prefix(A[C],infinity) - prefix(A[C],R)
local(R,L)  = base + prefix(U,L)
                  + sum(prefix(adjustments[r],L) for r<=R)
```

Remote tail is only added when latest client entry's sequence exceeds R. Local query requires computed local records (0x39f). Cache the aggregated adjustment set for a given R; invalidate/rebuild when source data changes. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:991`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:1034`.

Build each leaf's contribution (n=cachedLength):

1. Ordinary insertion <=minSeq adds n to baseline; acked insertion >minSeq adds +n at insertion seq to G and A[inserter]; pending insertion adds +n at localSeq to U only when local partials requested.
2. First removal <=minSeq subtracts n from baseline. A local-only first removal adds -n to U if insertion is baseline or by local client; otherwise add -n at (insertion.seq, removal.localSeq) to the 2D adjustments, so a view cannot remove an unseen insertion.
3. Acked first removal above minSeq adds -n at its seq to G. For each **distinct** nonlocal removing/obliterating client add -n to its A at the **winning first-removal seq**, not its own later removal seq. If insertion >minSeq and by another client, also add +n at insertion seq to that remover's A.
4. If the local client also removed the segment pending an ack, add its -n local contribution (gated by insertion.seq if needed) and add +n at (winning removal.seq, local removal.localSeq) to cancel double removal.

`reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:600`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:648`.

**Removed-on-insert is a separate branch.** If winning obliterate <=minSeq, no contribution. For pending insertion, U gets +n at insertion.localSeq, 2D gets -n at (firstRemove.seq, insertion.localSeq); if it also has a final local remove, U gets -n there and 2D gets +n there at firstRemove.seq. For acked insertion already obliterated, no global insertion/removal delta: add +n only to inserter's A at firstRemove.seq unless inserter is also among removing clients. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:507`.

Combine adds baselines/counts, merges equal-sequence global/local sets, adds per-client and per-refSeq adjustment deltas, and collapses below minSeq. Incremental update is only for latest acked sequence without structure change/overlapping removes: subtract any prior same-sequence delta first (grouped batches/mid-op can call repeatedly), recompute contributions from children, discard local records. If an update creates entries at earlier sequences, mark lastIncrementalInvalidationSeq and force full combine in ancestors. Reconnect local partials are recursively rebuilt and may temporarily use an older baseline refSeq to preserve in-flight history. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:341`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:841`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1101`.

### Worked historical-view accounting

For a baseline unit inserted at/below minSeq and first removed by A at seq 20, then also removed by B at seq 25, global G has -1 at 20; A and B each get -1 at **20**. At R=15, ordinary observer length=1, A length=0, B length=0, because each sender's own removals are in its view. At R=22 everybody sees length=0. Do not put B's adjustment at 25: its removal has already affected B's sender perspective before that global timestamp. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:719-810`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:991-1022`.

For a remote insertion at seq 12 of length 3, then local removal at localSeq 7, with minSeq<12: G contributes +3 at 12 and 2D contributes -3 at (12,7). `(R=11,L=7)` sees 0, `(12,6)` sees 3, `(12,7)` sees 0. If that same range also receives remote removal at seq 15, the local -3 is cancelled by +3 at (15,7); without cancellation `(15,7)` would incorrectly produce -3. On minSeq collapse, global removal moves into minLength independently of references/tracking that keep the tombstone physically bound. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:693-810`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:1090-1098`.

### minSeq and zamboni

`setMinSeq` asserts monotonicity and <=currentSeq, updates window, expires obliterate ranges, then scours. Partial collapse removes entries <=new minSeq: add their cumulative length to baseline, subtract it from remaining cumulative entries; collapse each client's entries too. This is independent of physically unlinking leaves. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1151`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:541`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:89`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:1090`.

Scour is collaborating-only, normally at most **two queue entries per call**. Update queued segment's properties MSN; stop if queue empty or maxSeq>minSeq. Scour a live parent unless needsScour===false. Never combine/unlink a leaf with pending segment groups. An unremoved insertion <=minSeq may append to preceding eligible positive-length leaf only if payload canAppend, properties match, and tracking memberships match. On append transfer content/refs, emit APPEND, unlink old tracking memberships, unbind old leaf. A removed leaf may UNLINK only when first removal<=minSeq and trackingCollection empty; emit UNLINK **before** unbinding, remove marker ID. Otherwise retain it. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/zamboni.ts:25`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/zamboni.ts:141`.

If scour leaves a block with <4 children and a parent, pack all sibling blocks: scour each, detach old blocks, divide retained nodes into min(7,floor(total/4)) blocks (at least one), distribute remainder to earlier blocks, repair assignments/lengths; recurse upward for parent underflow. If all retained nodes are gone, set parent.children=[] and childCount=0. Otherwise refresh ordinals and path lengths. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/zamboni.ts:64`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/zamboni.ts:83`.

## 5. Invariants and asserts

0xaab requires a bound inserted leaf; 0x4bc prohibits negative walk lengths; 0xab6 requires same client for equal-seq partial entries; 0xab7/0xab8 enforce removed-on-insert provenance; 0x39f requires local records; 0x04e/0x04f prohibit invalid MSN movement; 0x3f0 bounds ordinal branching and 0x9ad requires previous ordinal code unit. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:117`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1881`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:55`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:514`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:1008`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1151`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/ordinal.ts:15`.

## 6. JS-semantics hazards

Do not sort stamps numerically by seq: -1 is **later than all acked ops**, ordered by localSeq. `compare` returns zero for equal seq/localSeq regardless of client, while `equal` also compares clientId; preserve stable sort for equal comparisons. Sparse per-client arrays skip holes in forEach; do not invent entries for missing clients. Distinguish undefined length from zero. Ordinal comparison is JS UTF-16 code-unit lexicographic order, never localized Swift String comparison. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/stamps.ts:87`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/stamps.ts:121`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/stamps.ts:164`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:856`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/ordinal.ts:20`.

**Endpoint UTF-16 strings:** imaginary start ordinal is `String.fromCharCode(0x00)`; imaginary end ordinal is `String.fromCodePoint(0xffff).repeat(depth)`, with depth computed down the last branch beginning at 1 and incrementing per visited node. These are synthetic ordering sentinels, not inserted text or Unicode-normalized Strings. Temporary split suffix is also `String.fromCharCode(0)`. Ordinal generation uses `charCodeAt(previousOrdinal.length-1)` plus width and `fromCharCode`, not Unicode scalar indexing. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/endOfTreeSegment.ts:140-196`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/ordinal.ts:20-34`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:409`.

## 7. Test assets to reuse

Reuse the partial-length and merge-tree tests, including reconnect and obliterate families. The implementations' test-only verifier hooks provide leaf-sum crosschecks; concrete executable cases are `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/test/partialLength.spec.ts:1`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/test/obliterate.partialLength.spec.ts:1`, and `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/test/client.reconnectFarm.spec.ts:1`. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/partialLengths.ts:167`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1096`.

## 8. Open questions

None for the algorithms above. Arbitrary remote views that exclude some of the remote client's own ops are not supported by PriorPerspective; do not generalize its contract. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/perspective.ts:89`.
