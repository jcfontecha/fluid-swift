# merge-tree: snapshots and attribution

## 1. Role

Both legacy and V1 snapshots are supported readers and writers in 3.11.0. Legacy snapshots represent minSeq plus catchup operations; V1 retains sequenced merge metadata through currentSeq. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:1546`.

## 2. Surface used by other packages

Client.summarize/load take Fluid serializer and channel storage. The caller owns enclosing paths (sequence `content`, matrix `rows/segments` and `cols/segments`) and replays returned catchup messages. Attribution requires a supplied policy/serializer when present in loaded data. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:1546`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:318`.

## 3. Wire and persisted formats

### Read compatibility

Accept chunk.version **absent/undefined** or literal string **"1"**, not number 1; other versions throw `Unsupported chunk path: <path> version: <version>`. Legacy chunks normalize to V1 in memory. Always start from blob `header`. Legacy optional `body`; V1 `body_0`, `body_1`, ... follow headerMetadata. A single extra blob beyond listed chunks is parsed as catchup operations, regardless of its name; any other blob count throws. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotChunks.ts:157`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:82`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotV1.ts:154`.

Legacy JSON fields (writer insertion order; `?` omitted when undefined):

```
chunkStartSegmentIndex, chunkSegmentCount, chunkLengthChars,
totalLengthChars, totalSegmentCount, chunkSequenceNumber,
segmentTexts, attribution?, headerMetadata?
```

The type also accepts `chunkMinSequenceNumber?`; writer's chunk object omits it. `version:undefined` is assigned before these but stringify drops it. `headerMetadata` is appended by minimum-version serializer only for `header`. Existing legacy metadata wins; otherwise derive `{orderedChunkMetadata:[{id:"header"}, {id:"body"}?],minSequenceNumber:chunkMinSequenceNumber?,sequenceNumber:chunkSequenceNumber,totalLength:totalLengthChars,totalSegmentCount}` in that order. Include body ID iff chunkLengthChars<totalLengthChars. Legacy body retains total fields as produced by its builder; do not erase them just because redundant. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotlegacy.ts:75`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotChunks.ts:24`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotChunks.ts:108`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotChunks.ts:186`.

V1 JSON writer order:

```
{version:"1", segmentCount, length, segments, startIndex,
 headerMetadata?, attribution?}
```

Header metadata writer order is `{minSequenceNumber,sequenceNumber,orderedChunkMetadata,totalLength,totalSegmentCount}`. Only first chunk has it. orderedChunkMetadata lists header then bodies in numeric generation order. Chunk length sums **retained payload lengths**, including retained tombstones, not visible text length and not JSON bytes. Chunk target is mergeTreeSnapshotChunkSize or 10000: add whole segments until accumulated length reaches/exceeds target, never split segment to meet chunk boundary; emit at least a header even for empty content. Legacy emits at most header + one remainder body; V1 emits as many bodies as needed. Summary entry insertion order is header then bodies then optional legacy catchup blob. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotV1.ts:65`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotV1.ts:83`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotV1.ts:135`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotlegacy.ts:127`.

A segment is either raw DDS JSON or wrapped merge info. Detect wrapper only when truthy object contains `json`. Wrapper insertion order:

```
{json, seq?, client?, removedSeq?, removedClient?, removedClientIds?,
 movedSeq?, movedSeqs?, movedClientIds?}
```

seq/client included for insertion above minSeq; ordinary removal emits first setRemove seq, legacy singular removedClient, and all setRemove client IDs. **Only first ordinary removal timestamp is preserved**; reader gives every listed client that same removedSeq, including old singular-only snapshots (`removedClientIds ??= [removedClient]`). Obliterate used legacy term "move": requires movedSeq plus equally sized movedSeqs/movedClientIds arrays; reconstruct sliceRemove stamps using the individual seqs, not movedSeq for all entries. Merge all reconstructed removals using stable stamp comparator. Missing seq defaults universal 0, missing client NonCollabClient; raw segments get both defaults. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotChunks.ts:66`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotChunks.ts:80`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotV1.ts:286`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:109`.

Catchup blob is serialized array of complete sequenced document messages; writer strips obsolete `term` from each message and uses configured catchUpBlobName or `catchupOps`. V1 rejects nonempty catchup list. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotlegacy.ts:180`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/client.ts:1570`.

Attribution blob member is `{seqs,posBreakpoints,length,channels?}`. seqs entries are numeric op sequence, non-op AttributionKey object, or null (no key). Parallel posBreakpoints are chunk-relative offsets; channels object maps names to `{posBreakpoints,seqs}` (note reversed field order versus root). Serialize across segments, coalescing adjacent equal keys; missing segment/channel contributes null range. Local keys must never enter summary. Deserialization expands numeric key to `{type:"op",seq}`, preserves object/null, clips/rebases offsets across segment boundaries. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/attributionCollection.ts:19`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/attributionCollection.ts:389`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/attributionCollection.ts:465`.

### Types and literal compatibility examples

All counts, indices, lengths and sequence values above are JSON numbers; segment arrays contain DDS payloads or wrapper objects; orderedChunkMetadata is an array of `{id:string}`. Legacy totalLengthChars/totalSegmentCount/chunkSequenceNumber/chunkMinSequenceNumber are optional in the interface (body chunks need not repeat them), but header loading needs effective metadata with totals and sequence. V1 startIndex/segmentCount/length/segments/version are required; headerMetadata is omitted from bodies. Wrapper `json` is required; `seq`, `removedSeq`, `movedSeq`, and each movedSeqs entry are numbers; client/removedClient and client-ID array members are strings. Attribution length and posBreakpoints entries are numbers; channels is optional string-keyed object. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotChunks.ts:18-75`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/attributionCollection.ts:19-43`.

A detached, unattributed `"abc"` V1 header is, in actual writer order:

```json
{"version":"1","segmentCount":1,"length":3,"segments":["abc"],"startIndex":0,"headerMetadata":{"minSequenceNumber":0,"sequenceNumber":0,"orderedChunkMetadata":[{"id":"header"}],"totalLength":3,"totalSegmentCount":1}}
```

The legacy writer for the same content emits:

```json
{"chunkStartSegmentIndex":0,"chunkSegmentCount":1,"chunkLengthChars":3,"totalLengthChars":3,"totalSegmentCount":1,"chunkSequenceNumber":0,"segmentTexts":["abc"],"headerMetadata":{"orderedChunkMetadata":[{"id":"header"}],"sequenceNumber":0,"totalLength":3,"totalSegmentCount":1}}
```

Here minSequenceNumber is **omitted**, not zero/null: legacy writer does not assign chunkMinSequenceNumber and synthetic metadata copies undefined. An older unversioned header with identical fields but no headerMetadata is also read; the loader synthesizes the same metadata. If an old header includes `chunkMinSequenceNumber:0`, it becomes metadata minSequenceNumber=0. The serializer's alternate V1→minimum-version conversion has a **different** field insertion order: chunkStartSegmentIndex,chunkLengthChars,chunkSegmentCount,segmentTexts,totalLengthChars,totalSegmentCount,chunkSequenceNumber,chunkMinSequenceNumber,headerMetadata (undefined fields omitted). It must not be confused with SnapshotLegacy's direct output. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotV1.ts:118-128`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotV1.ts:135-189`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotlegacy.ts:107-120`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotChunks.ts:119-134`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotChunks.ts:186-207`.

A V1 body containing one retained removed unit (minSeq=10, insert seq=11, remove seq=12) may be:

```json
{"version":"1","segmentCount":1,"length":1,"segments":[{"json":"x","seq":11,"client":"alice","removedSeq":12,"removedClient":"bob","removedClientIds":["bob"]}],"startIndex":1}
```

With an overlapping obliterate at seq 13 by carol, append wrapper fields `"movedSeq":13,"movedSeqs":[13],"movedClientIds":["carol"]`. Singular-only old removal input `{"json":"x","removedSeq":12,"removedClient":"bob"}` is accepted and obtains universal insertion provenance. Modern output includes both singular and plural removal IDs; **do not invent removedSeqs**. This body contributes length 1 to chunk totals even though x is invisible. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotV1.ts:286-345`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:109-184`.

Example attribution for length 3, seq 11 on first two UTF-16 units and no attribution on last unit, with a channel attributing all units to seq 12:

```json
{"seqs":[11,null],"posBreakpoints":[0,2],"length":3,"channels":{"color":{"posBreakpoints":[0],"seqs":[12]}}}
```

Non-op detached key is an object `{"type":"detached","id":0}` rather than a sequence number; local key objects are forbidden by assertion. Root/channel runs coalesce by attribution key equality, not just object identity. `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/attribution.ts:37-49`. Empty legacy catchups produce **no catchup blob**, not `[]`; with messages, blob content is their ordered JSON array after deletion of term, preserving other envelope fields. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/attributionCollection.ts:465-535`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotlegacy.ts:180-194`.

V1 persists neither retained ObliterateInfo ranges nor `obliteratePrecedingInsertion`/`insertionRefSeqStamp`, although live tie-breaking uses these. Their absence is a source-noted format limitation, not optional fields a Swift writer should add. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/segmentInfos.ts:58-83`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotV1.ts:286-345`.

## 4. Behavior

Legacy extraction: view at minSeq/NonCollabClient; walk visible segments; reconstruct properties at minSeq via property manager; combine compatible adjacent clones; normalize empty properties to absent. Compute totals from collected segments and correct mismatched initially computed length. Catchup replay restores operations above minSeq (the enclosing sequence layer transforms them to refSeq=seq-1 as necessary). `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotlegacy.ts:198`, `reference/fluidframework-3.11.0/packages/dds/sequence/src/sequence.ts:965`.

V1 extraction: skip pending insertions and segments whose first removal<=minSeq. If insert<=minSeq and no removal or only pending first removal, combine raw payload with compatible previous candidate. Otherwise flush candidate and emit wrapper with above-minSeq metadata. Empty property bags become undefined before JSON conversion. Coalescing uses payload canAppend + matching properties, not tree block boundaries/tracking-group restrictions used by live zamboni. Snapshot clones before appending, but empty-property normalization can act on original candidate. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotV1.ts:194`.

Load header: parse using Fluid serializer, remember original version before normalization, deserialize segment specs+attribution, reload tree from header, require metadata. If attached, start collaboration using runtime clientId or `snapshot`; minSeq defaults to metadata.sequenceNumber when absent. Then load body chunks in listed order, check totals, deserialize, append preserving insertion provenance. Await body before returning catchup operations; the surrounding DDS must not initialize intervals from partial header content. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:62`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:187`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:227`.

**Literal loader quirk:** body loader accumulates baseline universal segments in a `batch`; `flushBatch` calls append but does not clear that array. If porting this path line-for-line, do not silently "fix" it without a differential case involving universal/non-universal transitions in body chunks. Header reload is a separate path and does not use this helper. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:283`.

Loaded attribution determines policy attachment: chunk with attribution requires policy, attaches if needed, then populates; without attribution detaches active policy. All or none of chunks must contain attribution. Attribution split/append preserve root and each channel; append synthesizes null channel runs when one side lacks it. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:270`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:318`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/attributionCollection.ts:304`.

## 5. Invariants and asserts

0x060 extra catchup count; 0x061/0x062 header lengths/count bounded by totals; 0x063/0x064 final totals exact; 0xaac removal IDs required; 0xaa5 move ID/seq arrays required and 0xb5f equal lengths. 0x065/0x873 preserved removal/move must be acked above minSeq; 0x066 wrapper must preserve actual merge metadata. 0x4bf all/no segment attribution (legacy), 0x4c0 all/no chunk attribution, 0x559/0x55a serializer required; 0x445 parallel attribution arrays; 0x5c1 excludes local attribution keys. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:94`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:126`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:227`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotV1.ts:297`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotlegacy.ts:97`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/attributionCollection.ts:394`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/attributionCollection.ts:499`.

## 6. JS-semantics hazards

All text chunk lengths, segment lengths and attribution breakpoints count **UTF-16 code units**. UTF-8 is only blob transport encoding. Preserve JS stringify omission of undefined object members (not null), null within arrays, ordered property spreads and empty-property normalization; otherwise summaries differ byte-for-byte even with identical visible text. Original version must remain remembered separately from normalized V1 representation, or legacy documents change output format on reload. Do not structurally sort client/removal arrays: order is provenance/stable stamp order. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/textSegment.ts:60`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotChunks.ts:108`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:187`, `reference/fluidframework-3.11.0/packages/dds/sequence/src/sequence.ts:836`.

## 7. Test assets to reuse

`reference/fluidframework-3.11.0/packages/dds/merge-tree/src/test/snapshot.spec.ts:1`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/test/snapshotlegacy.spec.ts:1`; sequence goldens in `legacy`, `legacyWithCatchUp`, `v1`, `v1Intervals`, and `emptyPropsAtEnd.json`, exercised by `reference/fluidframework-3.11.0/packages/dds/sequence/src/test/snapshotFormat.spec.ts:1` and `reference/fluidframework-3.11.0/packages/dds/sequence/src/test/snapshotEmptyProps.spec.ts:1`.

## 8. Open questions

The body batch behavior above is directly observable in source, but no runtime exercise was performed for this research task; its reachability/consequences need a differential fixture before changing it. V1's loss of later ordinary-remove sequence numbers is intentional reader compatibility in this version, not an unresolved field mapping. `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:137`, `reference/fluidframework-3.11.0/packages/dds/merge-tree/src/snapshotLoader.ts:295`.
