# counter — SharedCounter (3.11.0)

## Role

Optimistic additive numeric register. This package is already represented by `Sources/FluidCounter/SharedCounter.swift`; this specification records TS behavior, including surfaces not yet exposed by that Swift class. `reference/fluidframework-3.11.0/packages/dds/counter/src/counter.ts:63-115`.

## Surface used by other packages

`SharedCounter.value`, `increment(number)`, `incremented(amount,newValue)`; channel kind/factory type `https://graph.microsoft.com/types/counter`, version `0.1`. `reference/fluidframework-3.11.0/packages/dds/counter/src/interfaces.ts:15-81`, `reference/fluidframework-3.11.0/packages/dds/counter/src/counterFactory.ts:30-38`.

## Wire and persisted formats

One op, required fields in order `type` literal `increment`, `incrementAmount` JS number: `{"type":"increment","incrementAmount":2}`. One blob `header` containing `{"value":2}`, sole required number field, no split/version branch. Local-only metadata is numeric monotonic message ID; pending records are `{type:"increment",incrementAmount,messageId}`. Summary includes the optimistic value. Load copies `content.value` without events. `reference/fluidframework-3.11.0/packages/dds/counter/src/counter.ts:32-57`, `reference/fluidframework-3.11.0/packages/dds/counter/src/counter.ts:99-109`, `reference/fluidframework-3.11.0/packages/dds/counter/src/counter.ts:123-137`.

## Behavior

1. Start value 0 and next ID 0. Reject when `amount % 1 !== 0` with `Must increment by a whole number` (reject fractions, NaN, infinities; accept ±0 and finite integral Doubles beyond safe integer range). Construct op, allocate ID even detached, add amount, emit `incremented(amount,value)`, then if attached append pending record and submit. `reference/fluidframework-3.11.0/packages/dds/counter/src/counter.ts:76-115`.
2. Process members in order; ignore non-op envelopes. Local ACK shifts FIFO record, validates metadata number then record ID/type/amount equality; never adds again or emits incremented. Remote increment adds amount and emits incremented; unknown remote type throws. Concurrency adds in sequencing order over already optimistic local state; do not claim mathematical exactness beyond JS Double arithmetic. `reference/fluidframework-3.11.0/packages/dds/counter/src/counter.ts:144-188`.
3. Disconnect no-op; inherited reSubmit forwards original op/ID, without allocating or adding. Stash asserts increment then invokes normal increment (new ID, optimistic state/event/submission). Rollback validates op shape, numeric ID, pops matching last pending record and invokes incrementCore with negated amount, emitting incremented(-amount,newValue); no next-ID rewind. `reference/fluidframework-3.11.0/packages/dds/counter/src/counter.ts:142`, `reference/fluidframework-3.11.0/packages/dds/counter/src/counter.ts:193-238`, `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:474-476`.
4. Swift cross-check: matching type, header JSON, Double state, remainder validation, allocation before detached decision, FIFO pending-ID/amount check and local-vs-remote additive behavior are present. Swift currently has no event emitter, rollback, stashed-op or explicit reSubmit API (its saved submit closure acts as its attached predicate); its `process` validates op type before the local branch, whereas TS validates local type through pending-op equality. These are explicit fidelity boundaries, not changed by this research. `Sources/FluidCounter/SharedCounter.swift:1-82`, `reference/fluidframework-3.11.0/packages/dds/counter/src/counter.ts:157-185`.

## Invariants and asserts

`0xc8e` numeric ACK metadata; `0xc8f` pending FIFO ID/type/amount equality; `0x3ec` stash type; `0xc90` numeric rollback metadata; `0xc91` LIFO rollback equality; `0xc92` rollback content nonnull object with increment type and numeric amount. `reference/fluidframework-3.11.0/packages/dds/counter/src/counter.ts:163-174`, `reference/fluidframework-3.11.0/packages/dds/counter/src/counter.ts:193-238`.

## JS-semantics hazards

Use Double, not Swift Int. `-0 === 0`; JSON outputs 0. Large integer additions can round; overflowing accumulated value stringifies as null although local increment rejects infinite inputs. Preserve event-before-submit ordering and optimistic summaries. `reference/fluidframework-3.11.0/packages/dds/counter/src/counter.ts:92-130`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/dds/counter/src/test/counter.spec.ts:1-20`, `reference/fluidframework-3.11.0/packages/dds/counter/src/test/counter.fuzz.spec.ts:1-20`, `reference/fluidframework-3.11.0/packages/dds/counter/src/test/fuzzUtils.ts:1-20` provide package tests and mixed/reconnect operation generation. Existing Swift source is the baseline for number/JSON adaptation, not evidence of full lifecycle parity.

## Open questions

None.
