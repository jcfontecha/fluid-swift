# merge-tree: operations and concurrent ordering

## 1. Role

`Client` interprets range ops; `MergeTree` applies them against a perspective, updates provenance/lengths and emits synchronous deltas. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:556`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1488`.

## 2. Surface used by other packages

Delta types, op builders, Client local edit methods/applyMsg/applyStashedOp/localTransaction and segment/property abstractions are consumed by sequence and matrix. Marker-relative annotations and adjustable numeric properties share the annotation path. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/opBuilder.ts:32`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:255`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:1601`.

## 3. Wire and persisted formats

Operations are JSON objects inside runtime sequenced envelopes (clientId, sequenceNumber, referenceSequenceNumber, minimumSequenceNumber; local metadata is **not wire data**). The type discriminator is numeric, never the enum's name. Fields below are in **builder insertion order**, relevant to stringify, though receivers resolve by key:

| Type | Builder output |
|---|---|
| INSERT=0 | `{pos1,seg,type:0}` |
| REMOVE=1 | `{pos1,pos2,type:1}` |
| ANNOTATE=2 | `{pos1,pos2,props,type:2}` or `{pos1,pos2,adjust,type:2}` |
| GROUP=3 | `{ops:[delta...],type:3}`; empty list is a valid regenerated noop |
| OBLITERATE=4 | `{pos1,pos2,type:4}` |
| OBLITERATE_SIDED=5 | `{type:5,pos1:{pos,before},pos2:{pos,before}}` |

`reference/fluidframework-3.11.0/packages/dds/merge-tree/src/ops.ts:61`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/opBuilder.ts:58`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/opBuilder.ts:101`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/opBuilder.ts:138`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/opBuilder.ts:174`.

Insert/remove/ordinary annotate may instead supply `relativePos1`/`relativePos2` as `{id?,before?,offset?}`; a numeric position takes precedence if defined. Marker annotation builder emits `{props,relativePos1:{id,before:true},relativePos2:{id},type:2}`. Relative ID resolves marker position; before subtracts offset (default 0), after adds marker length then offset. Unknown ID returns detached -1. Numeric remove/annotate ranges are [start,end); type 4 is translated to (start,Before),(end-1,After). Type 5's `before` is boolean; Side enum elsewhere is Before=0, After=1. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/ops.ts:92`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:747`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1466`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:672`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/sequencePlace.ts:50`.

`seg` is DDS-specific. Text is a raw string when properties absent, else `{text,props}` (an existing empty bag is initially meaningful). Marker is `{marker:{refType},props?}`, length 1. Text decoder tries raw string then object containing text; marker decoder checks marker. Matrix uses `[length,startHandle]`, see matrix spec. Adjustment bag maps keys to `{delta,min?,max?}` and excludes props. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/textSegment.ts:45`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/textSegment.ts:63`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:506`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/ops.ts:194`, `reference/fluidframework-3.11.0/packages/dds/matrix/src/permutationvector.ts:85`.

### Literal op examples and field types

The numeric fields `pos1`/`pos2` and relative `offset` are JS numbers; `id` is a marker ID string and `before` a boolean. `props` is an arbitrary string-keyed property bag; `adjust` is a string-keyed bag of objects whose required `delta` and optional `min`/`max` are numbers. `ops` is an ordered array of **delta** ops, not recursively nested groups in the declared wire type. Builders shallow-spread props/adjust, preserving key insertion order (integer-index keys still enumerate first). Examples produced by the respective builders:

```json
{"pos1":0,"seg":"A😀B","type":0}
{"pos1":1,"pos2":3,"type":1}
{"pos1":0,"pos2":1,"props":{"bold":true,"old":null},"type":2}
{"pos1":0,"pos2":1,"adjust":{"score":{"delta":2,"min":0,"max":10}},"type":2}
{"ops":[{"pos1":0,"seg":"x","type":0},{"pos1":1,"seg":"y","type":0}],"type":3}
{"pos1":1,"pos2":3,"type":4}
{"type":5,"pos1":{"pos":1,"before":true},"pos2":{"pos":2,"before":false}}
{"props":{"color":"red"},"relativePos1":{"id":"p","before":true},"relativePos2":{"id":"p"},"type":2}
```

**UTF-16 example:** `A😀B` has length 4. The remove `[1,3)` removes both surrogate units; `[1,2)` removes only the high surrogate, leaving a lone low surrogate. An insertion at 2 splits the pair. The group above applies y at position 1 **after** x has been inserted. For marker/text payload examples, `{ "text":"x","props":{} }` differs from raw `"x"` until snapshot empty-props normalization; `{ "marker":{"refType":1},"props":{"markerId":"p","referenceTileLabels":["paragraph"]} }` is a one-unit marker. The marker ID property is literally `markerId`. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/ops.ts:80-245`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/opBuilder.ts:32-194`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/textSegment.ts:55-70`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:514-546`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/referencePositions.ts:10-56`.

## 4. Behavior

### Common dispatch and range validation

Local edit uses application perspective and mints the next local stamp (or universal in detached mode); remote uses Prior(refSeq,sender), stamped with envelope seq/sender. `applyMsg` acknowledges when envelope sender matches longClientId **or runtime local is true**, otherwise applies remote op; then advances currentSeq and minSeq, clamping minSeq to oldest in-flight reference when provided. Equal currentSeq is permitted for grouped batches. Unknown remote delta types take the default no-op branch; do not make up a rejection. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:579`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:1356`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:1289`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:671`.

For local numeric ranges: start required, 0<=start<=length (only insert accepts start==length). Non-insert requires end>start; insert with an explicit end also requires end>start. **Only type 4 OBLITERATE checks end<=length in this validator**; ordinary remove/annotate do not impose that upper-bound check here. Invalid local range throws LoggingError("RangeOutOfBounds") with usageError=true and telemetry fields end,invalidPositions,length,opPos1,opPos1Relative,opPos2,opPos2Relative,opType,start. Checks are comparisons, not an integer/finite-number validator. Remote ranges bypass this branch unless perspective.clientId equals local short ID. Sided validation accepts equal position/same side, but rejects inverted sides/positions and positions outside [0,length); missing endpoints assert. Resolve/split using the **operation perspective**, not local text offsets. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:747`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:672`.

Groups apply member deltas **in array order**, each sharing envelope seq/refSeq/client and retaining parent group in callback args. Local transaction applies each member synchronously in order. Pending metadata can be one group or array; acknowledgement consumes member groups in order. This is not atomic deferred visibility: callbacks occur during individual mutations. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:1311`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:1601`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:1507`.

### Insert tie-breaking

1. Ensure insertion boundary, splitting containing visible segment if necessary. Filter payload segments with cachedLength<=0. Overwrite each new segment's insert stamp and register truthy marker IDs.
2. Walk blocks subtracting perspective lengths. Descend when pos<len, or when pos==len and breakTie returns true. For an internal block tie always descends. For leaf tie only pos==0 can win: descend/insert **before** leaf if incoming stamp>leaf.insert, OR leaf has acked first removal with firstRemoval>incoming stamp. Otherwise continue past it. Stamps compare all acked before unacked; acked by seq, unacked by localSeq. There is **no lexical client-ID tie-breaker** here.
3. Insert candidate before the selected leaf, or append at far end; split full blocks and refresh paths. Failure to bind an inserted segment throws DataProcessingError for sequenced input or UsageError for local input.
4. For multiple segments advance insertion position by payload cachedLength after each. Queue unacked local segments into one pending segment group, or enqueue acked recent segments for scour.
5. Apply overlapping obliterate logic below. Emit INSERT only for resulting segments not removed, then zamboni for acked collaborative inserts.

`reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1488`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1559`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1815`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1850`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/stamps.ts:87`.

### Remove versus obliterate

Ordinary remove first splits start/end, walks only the sender-visible set in [start,end), and adds a `setRemove` stamp. Newly removed leaves get `[stamp]` and join delta list; already removed leaves receive sorted additional stamp, trigger full length rebuild rather than incremental update, and may need reference sliding if this is first acked removal. Thus concurrent insertions that sender had not seen survive ordinary remove. Pending groups and scour entries are updated before callbacks. Slide already-locally-removed overlap refs before delta; emit REMOVE only for newly removed segments; slide refs on newly removed remote/detached segments **after delta**. Local collaborative removals wait for acknowledgement before physical sliding. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:2296`.

Obliterate requires `mergeTreeEnableObliterate===true`; sided input additionally requires sided option. Convert sides to split offsets (Before→pos, After→pos+1), split, then create StayOnRemove endpoint refs with original sides and retain an ObliterateInfo interval containing refSeq/stamp. Always create a pending group for local collaborative obliterate, even if empty. Remote range walk uses sender perspective for **positions** but RemoteObliteratePerspective for **visibility**: visits concurrent inserted leaves, including locally removed leaves, but not previously acked-removed content. Exclusive start/end anchor characters are visited for adjacency but not themselves removed. Record `sliceRemove` stamps and rebuild overlaps. Emit OBLITERATE callback (even empty delta list when endpoints differ), then slide newly removed refs after callback and scour. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:2087`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:2228`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:2266`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:2965`.

### Concurrent inserts into retained obliterate intervals

After binding an insertion, inspect overlapping obliterates whose stamps are newer than the insertion's reference-seq stamp. Track oldest obliterate from another client, newest overall (including same client), newest acked, oldest unacked, and all acked other-client obliterates. Save newest as `obliteratePrecedingInsertion`. **Last-to-obliterate gets to insert**: if newest belongs to inserting client, do not obliterate new segment. Otherwise, if any other-client candidate exists, mark it removed with sorted acked candidates (only when newestAcked===newest OR newestAcked.clientId!=insertingClient) plus oldest pending local obliterate, linking that pending group. Rebuild lengths (insertion was already counted; a second incremental insert update would double-count). Newest pending obliterate also tracks segment and insertionRefSeqStamp for later rebase normalization. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1651`.

When processing a remote acked obliterate against a pending local insertion protected by a newer unacked local obliterate, skip marking it removed: the pending local obliterate is still the newest winner. This exception and the insert-time handling must agree. Expire retained obliterate interval endpoints when seq<=minSeq. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:2163`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:541`.

### Annotation and property history

Split boundaries, walk sender-visible range, and call PropertiesManager for each segment. Ordinary raw values use last-writer behavior with pending local overlays; null deletes property, undefined is omitted from changes. Delta bag reports **old values**, using null for missing. Per key retain msnConsensus, sequenced remote changes, and pending local changes; evaluate consensus then remotes then locals. Raw remote changes can fold directly into consensus only while no pending remote adjustment history exists. Adjust uses numeric current value or zero, adds delta, checks max first, then min; this ordering matters when min>max. Adjust is feature-gated. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:2013`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/segmentPropertiesManager.ts:54`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/segmentPropertiesManager.ts:87`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/segmentPropertiesManager.ts:188`.

Ack shifts one local property change per affected defined key, folds/pushes acked value into remote history, then advances MSN; MSN folds remote prefix <=MSN and drops empty managers' entries. Legacy snapshots query getAtSeq to reconstruct consensus+remote prefix without local overlays. Splits copy independent linked lists of pending property changes; they must not share mutable queues. Rollback pops local property history and recomputes value. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/segmentPropertiesManager.ts:140`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/segmentPropertiesManager.ts:248`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/segmentPropertiesManager.ts:300`.

## 5. Invariants and asserts

Range dispatch asserts types 0x02d/0x02e/0x02f/0x866. Disabled sided obliterate asserts 0xa43; missing sided endpoints 0xa44. Disabled experimental operations throw `"<option> is not enabled."` (must be literal true). Inserted obliterate tracking requires 0xb73/0x86c. Current sequence monotonicity 0x038 and min<=seq 0x039. Property ack must have matching queued change 0xa71. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:556`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:672`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:303`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:1703`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:1379`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/segmentPropertiesManager.ts:248`.

## 6. JS-semantics hazards

**UTF-16:** TextSegment constructor uses `text.length`; clone and split use `slice`, including cuts inside surrogate pairs. Preserve lone surrogates. Clone uses JS slice(start,end): omitted end means length, negative indices count from end, indices clamp to bounds, and end<start yields empty; split uses slice with Math.max(0,pos) for both halves. canAppend calls JS `endsWith("\n")` and refuses left text ending LF and otherwise accepts if either length<=256; no Unicode normalization. `MergeTreeTextHelper` slices by code units and marker placeholders repeat per segment length; placeholder `"*"` means newline+segment string, not literal stars. All op offsets and split positions are consequently UTF-16 for text, while markers consume one. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/textSegment.ts:55`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/textSegment.ts:69`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/textSegment.ts:95`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/MergeTreeTextHelper.ts:61`.

Properties clone shallowly; nested objects remain JS identity-bearing values, not structural equality. Preserve JS Object.entries ordering, null deletion, undefined filtering, number Double semantics (NaN comparisons do not clamp), and the difference between an absent property bag and empty bag. Event callbacks are synchronous/reentrant where consumer layer permits; moving them to Tasks changes pending queue and observable sequence timing. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTreeNodes.ts:343`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/segmentPropertiesManager.ts:54`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/segmentPropertiesManager.ts:87`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/mergeTree.ts:2363`.

## 7. Test assets to reuse

Use `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/test/obliterate.concurrent.spec.ts:1`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/test/obliterate.rangeExpansion.spec.ts:1`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/test/obliterate.deltaCallback.spec.ts:1`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/test/obliterate.partialLength.spec.ts:1`, and `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/test/partialLength.spec.ts:1`. Add mixed peers with same-position inserts, concurrent set-remove versus slice-remove and surrogate-half edits.

## 8. Open questions

None. Experimental features are supported only under the exact option gates above; the port must not silently enable obliterate reconnect because basic obliterate is enabled. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:985`.
