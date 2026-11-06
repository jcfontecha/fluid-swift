# cell — SharedCell (3.11.0)

## Role

A single optimistic last-sequenced-writer register, including handles and optional attribution. Runtime channels instantiate `SharedCell`; application code reads and mutates synchronously. `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:68-108`.

## Surface used by other packages

`SharedCell<T>` exposes `get`, `set`, `delete`, `empty`, `getAttribution`; events are `valueChanged(value)` and `delete()`. `ICellOptions.attribution.track` controls new attribution. `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:110-171`, `reference/fluidframework-3.11.0/packages/dds/cell/src/interfaces.ts:15-151`. Factory type `https://graph.microsoft.com/types/cell`, summary version `0.1`. `reference/fluidframework-3.11.0/packages/dds/cell/src/cellFactory.ts:32-40`.

## Wire and persisted formats

DDS op contents, in construction order:

```json
{"type":"setCell","value":{"value":7}}
{"type":"setCell","value":{}}
{"type":"deleteCell"}
```

`type` is required literal string. Set's outer `value` is required object; inner `value` is arbitrary serializable data, omitted by JSON when undefined. The second example is `set(undefined)`, not delete. Although the internal wrapper permits optional `attribution`, local set ops never emit that member. Handles anywhere in values encode as `{"type":"__fluid_handle__","url":"/store/channel"}` through the shared serializer. `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:39-59`, `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:114-148`, `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/serializer.ts:120-162`.

Exactly one UTF-8 blob `header`, no splitting; serializer-stringified object constructed `value`, then `attribution`. Examples: `{}` for empty/unattributed; `{"value":7}`; `{"value":7,"attribution":{"type":"op","seq":42}}`; `{"value":7,"attribution":{"type":"detached","id":0}}`. Local attribution is deliberately omitted, not persisted as `{"type":"local"}`. Value may itself be omitted while attribution remains. Loader decodes `content.value` and copies `content.attribution`, with no format gate or events. `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:178-201`.

Handle encoding additionally permits required-type/url plus optional final `payloadPending:true`: `{"type":"__fluid_handle__","url":"/store/blob","payloadPending":true}`. It is emitted only when the internal handle has payloadPending===true; otherwise the field is absent, never false. Decoder recognizes any value whose type property equals the marker (not a structural url validator), resolves relative URLs against serializer context, and constructs a remote handle with pending flag iff payloadPending===true. User objects with this marker therefore decode as handles rather than ordinary data. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/handles.ts:31-56`, `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/handles.ts:95-105`, `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/serializer.ts:149-162`.

## Behavior

1. Initially data undefined, `messageId = messageIdObserved = -1`, empty pending-ID array. Set saves old data, assigns new data, emits `valueChanged(value)` **before** updating attribution. Delete saves old data, assigns undefined, emits `delete()` even if already empty, then updates attribution. If tracking: attached local → `{type:"local"}`, detached → `{type:"detached",id:0}`. Detached calls return without submitting. Attached calls increment messageId, append it, submit op with local-only `{pendingMessageId,previousValue}`. `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:76-94`, `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:114-171`, `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:274-299`, `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:351-354`.
2. Process batch members in order. **Before checking envelope type**, if latest created ID differs from observed ID, ignore all incoming content. For local messages validate ID ≤ latest and FIFO head equality, shift head, set observed ID, set op attribution using envelope sequence; return without changing data/events. This includes earlier local ACKs while a later write is pending. `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:229-263`.
3. With no outstanding ID gap, only remote `op` envelopes apply: update attribution first to `{type:"op",seq:sequenceNumber}`, then dispatch setCore/deleteCore and emit the corresponding event. Thus local event observers see old attribution, remote event observers see new attribution. Unknown applied operation throws `Unknown operation`. Final sequence order wins; earlier remote edits are hidden while a newer local edit awaits ACK. `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:213-285`.
4. Disconnect is no-op. ReSubmit inherits exact content/metadata forwarding, without new IDs or reapplying data. `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:206`, `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:474-476`.
5. Stash dispatches normal `delete()` or `set(op.value.value)` after shared-base handle decoding, recreating optimistic events and IDs. `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:301-315`, `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:541-542`.
6. Rollback of either valid type first restores previousValue via deleteCore if undefined, otherwise setCore (with events), then pops pending ID and throws if mismatched. It **does not decrement messageId, update messageIdObserved, or restore attribution**. Preserve this quirk: the ID-gap suppression can remain after rollback. Unknown rollback type throws. `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:326-343`.

## Invariants and asserts

`0x00c`: ACK ID defined and ≤ latest; `0x471`: ACK ID is FIFO head. Rollback mismatch is ordinary `Rollback op does not match last pending`; unsupported rollback throws `Unsupported op for rollback`. `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:244-260`, `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:326-343`.

## JS-semantics hazards

Undefined is both empty data and legal set input: `empty()` checks strict undefined, but set(undefined) emits valueChanged, not delete. Null is nonempty. Preserve numeric Double and JSON semantics, handle decoding and synchronous/reentrant event order. Rollback restores data, not attribution or counters. `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:151-169`, `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:274-285`, `reference/fluidframework-3.11.0/packages/dds/cell/src/cell.ts:326-343`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/dds/cell/src/test/cell.spec.ts:1-20` is the package's behavioral test entry, including local/connected operations, rollback, reconnect and attribution tests. Port the full file's cases alongside mixed-client op/summary fixtures; it imports the mock runtime at the cited entry.

## Open questions

None.
