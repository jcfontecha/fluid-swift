# shared-summary-block (3.11.0)

## Role

Local state whose distribution is exclusively by summaries, not a collaborative op stream. Intended for deterministic state maintained elsewhere. `reference/fluidframework-3.11.0/packages/dds/shared-summary-block/src/sharedSummaryBlock.ts:41-74`.

## Surface used by other packages

`SharedSummaryBlock` factory/kind, implementation `SharedSummaryBlockClass`, and `ISharedSummaryBlock` with `get<T>(key)` and `set<T>(key,Jsonable<T>)`. Factory type `https://graph.microsoft.com/types/shared-summary-block`, summary version `0.1`. `reference/fluidframework-3.11.0/packages/dds/shared-summary-block/src/interfaces.ts:15-33`, `reference/fluidframework-3.11.0/packages/dds/shared-summary-block/src/sharedSummaryBlockFactory.ts:28-36`.

## Wire and persisted formats

**No ops.** One UTF-8 `header` blob, no splitting: an object from string keys to JSON values, e.g. `{"count":2,"ready":true}`. Walk internal Map insertion order, assign each property into `{}`, then plain `JSON.stringify`, not Fluid serializer. Array-index property names sort numerically under JS object ordering. Empty header is `{}`. For insertion order b,10,2,a, the output order is `{"2":2,"10":10,"b":1,"a":3}`. Undefined-valued properties disappear; no handle serializer is applied. Loader parses header, walks Object.entries in JS property order and populates Map; no format alternatives or events. `reference/fluidframework-3.11.0/packages/dds/shared-summary-block/src/sharedSummaryBlock.ts:45-84`.

## Behavior

1. Get returns Map lookup (undefined if absent). Set changes Map synchronously then calls `dirty()` even when value is unchanged; no DDS-specific event or submission. `reference/fluidframework-3.11.0/packages/dds/shared-summary-block/src/sharedSummaryBlock.ts:59-67`.
2. No pending locals, conflict resolution, rollback records, or distributed winner: two clients can maintain different local state until a later summary is loaded. `reference/fluidframework-3.11.0/packages/dds/shared-summary-block/src/sharedSummaryBlock.ts:45-90`.
3. Disconnect no-op. Every invocation of processMessagesCore throws `shared summary block should not generate any ops.` Stash throws `not implemented`. Inherited reSubmit would forward content/metadata, but valid usage never has an op to resubmit. Rollback is inherited unsupported, calling `throwUnsupported("rollback")`; do not invent a local restoration. `reference/fluidframework-3.11.0/packages/dds/shared-summary-block/src/sharedSummaryBlock.ts:87-95`, `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:474-476`, `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:669-670`.

## Invariants and asserts

No package-specific assert codes. Op receipt and stash are explicit errors as above. `reference/fluidframework-3.11.0/packages/dds/shared-summary-block/src/sharedSummaryBlock.ts:89-95`.

## JS-semantics hazards

The summary builder uses ordinary property assignment, not Object.fromEntries or a null-prototype dictionary. A `__proto__` key changes object prototype for object/null values, is ignored for primitives, and never becomes an own summary property. It remains a normal key in the live Map but disappears after reload; e.g. setting only `__proto__` to `{ "n":1 }` produces header `{}`. A manually-authored JSON header with an own `__proto__` property loads that Map key through Object.entries, then loses it again on the next summary. Numeric property ordering and `JSON.stringify` omission/null conversion must match TS. `reference/fluidframework-3.11.0/packages/dds/shared-summary-block/src/sharedSummaryBlock.ts:63-83`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/dds/shared-summary-block/src/test/sharedSummaryBlock.spec.ts:1-20` is the behavioral fixture entry; include empty and multi-key summaries, dirtying, and load roundtrips. Add differential inputs for integer-like keys and `__proto__` because the implementation's ordinary-object assignment is observable.

## Open questions

None.
