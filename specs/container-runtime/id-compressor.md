# container-runtime / ID compressor integration

## 1. Role

Integrates the id-compressor package into document load, logical op order, detached summaries and offline state. Compressor algorithms/codecs are supplied by that package; this spec defines when calls occur and which state must survive. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:1240-1282` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:2292-2309`

## 2. Surface used by other packages

Public runtime `idCompressor` returns compressor only for session mode `on` and asserts loaded; `generateDocumentUniqueId` uses the internal compressor if loaded, otherwise UUID. Delayed mode may therefore have internal compressor state without exposing it as the public compressor. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:1486-1498`

Core calls: create/deserialize, `takeNextCreationRange`, `finalizeCreationRange`, `resetUnfinalizedCreationRange`, `serialize(false)` for summary, `serialize(true)` for pending state. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:1244-1282` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:2292-2309` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:2932-2935` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3045-3052` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:5812-5818`

## 3. Wire and persisted formats

Logical allocation is ordered `{type:"idAllocation",contents:<IdCreationRange>}`; the range object is passed through unchanged from compressor and obeys its package's format. No op is emitted when `range.ids` is undefined. Summary `.idCompressor` is `JSON.stringify(compressor.serialize(false))`, **without ongoing local session**; pending state's `pendingIdCompressorState` uses `serialize(true)` including local session. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:2292-2309` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:2932-2935` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:5812-5819`

Serialization version selected from oldest-supported floor: >=3.4.0 → `SerializationVersion.V3`, otherwise V2. Session-inclusive pending state wins over summary state; absent both create fresh compressor, summary-only deserialize with `createSessionId()` (new session), pending deserialize preserves session. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:1240-1282`

Modes in schema are missing/off, `delayed`, `on`. Existing document mode is sticky; exception: off→delayed permitted when explicit schema control is enabled. New documents use requested mode. Persisted `idCompressorMode` wins in schema intersection. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:1205-1238` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/summary/documentSchema.ts:265-269`

### Exact allocation shape and string wrapping

`IdCreationRange` is `{sessionId:string,ids?:{firstGenCount:number,count:number,requestedClusterSize:number,localIdRanges:[number,number][]}}`. Each tuple is `[generationCount,count]`, not `[start,end]`; generation counts are positive, unlike negative local compressed IDs. The writer inserts those fields in precisely the order above. For a session's first two locally allocated IDs with requested cluster size 512, the envelope is:

```json
{"type":"idAllocation","contents":{"sessionId":"00000000-0000-4000-8000-000000000001","ids":{"firstGenCount":1,"count":2,"requestedClusterSize":512,"localIdRanges":[[1,2]]}}}
```

No-allocation result is `{"sessionId":"00000000-0000-4000-8000-000000000001"}`, but runtime does **not** submit that as an op. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/types/persisted-types/0.0.1.ts:38-62` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:541-559` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:2292-2309`

The serialized compressor is a branded **string**, base64 of binary Float64-backed serialization, not `{version,...}` JSON. `.idCompressor` blob content is the JSON string literal enclosing that base64 string, including quotes. Pending capture puts that same kind of string directly at `pendingIdCompressorState`; do not stringify it a second time there. A valid empty V2 no-session example is `"AAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="` (four Float64 values: version=2, hasLocalState=0, sessionCount=0, clusterCount=0). Runtime passes codec through without parsing/reordering bytes. V2/V3 codec state is owned by ID compressor; the integration must preserve it exactly and choose requested write version as specified above. `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/types/persisted-types/0.0.1.ts:8-30` `reference/fluidframework-3.11.0/packages/runtime/id-compressor/src/idCompressor.ts:874-988` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:2932-2935` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:5812-5819`



## 4. Behavior

1. Load compressor immediately for `on`; delayed mode loads when connected (and also when summarizing); buffered remote allocation ranges finalize in their original order once loaded. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:2481-2491` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3124-3140` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:4381-4383`
2. On a sending, nonstaged outbox flush, after any rebase, call `takeNextCreationRange`; if IDs exist, prepend allocation before user ops and only then mark batch boundaries. The allocation reference sequence is current delta last sequence; allocation is never staged. No urgency to flush allocations without messages referencing them. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:2292-2309` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/opLifecycle/outbox.ts:339-348` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/opLifecycle/outbox.ts:442-460`
3. On processing allocations, skip saved ranges only when `skipSavedCompressorOps && savedOp===true`. Otherwise if compressor missing, require mode enabled and enqueue; if loaded require pending queue empty and finalize each in order. The skip prevents double-finalization after restoring tip compressor state; delayed mode without serialized tip must still process saved allocations. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3775-3801`
4. Reconnect resets unfinalized cursor before pending replay, ensuring the next newly generated range includes all unfinalized prior IDs. Drop old allocation ops during per-op resubmit/rebase. Replaying `[alloc1,data1,alloc2,data2]` literally could place newly generated IDs before alloc2 and corrupt allocation order. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3045-3052` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:5559-5567`
5. Applying stashed allocation ops does nothing except assert mode is enabled: restored **tip** compressor state already covers them and prevents newly generated IDs during stash apply/resubmit from colliding. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3084-3098`
6. Detached `createSummary` takes/finalizes locally, as this is the only client; if IDs exist firstGenCount must be 1. Then build datastore attach summary and serialize compressor. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:4335-4354`

## 5. Invariants and asserts

`0x8ea` `on` compressor loaded; `0x8f1` stashed allocation requires enabled mode; `0x93c` received allocation requires enabled mode; `0x979` no buffered ranges once loaded; `0x93e` detached first range starts generation 1. Normal submit rejects explicit IdAllocation (`0x9a5`), since outbox generates it. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:1486-1493` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3094-3097` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3787-3798` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:4335-4342` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:5329-5330`

## 6. JS-semantics hazards

Keep missing `ids` distinct from an empty object, and missing mode distinct from a string `off` (not a supported literal). Preserve finalization op order within grouped batches. Session-inclusive vs no-session serialization is a correctness distinction, not an optimization; use pending state even when loading a different base summary. Never reset compressor allocations by reconstructing solely from that base summary. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:2296-2299` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/summary/documentSchema.ts:35` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:1261-1280` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3084-3098`

## 7. Test assets to reuse

Runtime tests cover allocation ops, reconnect, detached summary and delayed mode; pending manager tests cover saved/stashed replay ordering. Pair these with the id-compressor package's serialization/range vectors. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/test/containerRuntime.spec.ts:1` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/test/pendingStateManager.spec.ts:1`

## 8. Open questions

None in runtime integration; range binary/JSON representation and ID numerical semantics must be implemented from the id-compressor package spec, not duplicated here. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/messageTypes.ts:124-127`
