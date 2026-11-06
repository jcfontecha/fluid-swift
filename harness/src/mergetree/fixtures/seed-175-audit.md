# TS 3.11.0 oracle audit (F1 resume)

> Third-pass update: this document preserves the historical experimental audit.
> The production farm now disables obliterate and has NO prefix exclusion or seed
> skips. Seeds 0–499 pass, including 175 and 197. Both archived failures contain
> obliterate. Repro scripts explicitly enable it; the independent experimental
> field farm is selected with `--obliterate`. See ../README.md for current gates.
>
> Revalidation correction: seed-197.json passes the schedule audit and reproduces
> A/B/C lengths 3/8/4. seed-197-minimized.json FAILS the current audit at
> "service minimum cannot pass a lagging client". The historical claim below
> that the reduced fixture passes is not valid current evidence. Do not weaken
> the audit; use the original fixture until the reducer's minSeq handling is fixed.

## Seed 175: valid schedule, upstream divergence

`npx tsx src/mergetree/reproduce.ts` first prints `service/runtime schedule audit
passed`, then intentionally exits 1 for A/C length 19 versus B length 18.
`minimize.ts 175` greedily removes complete operations and every associated delivery,
regenerates wire contents from the actual local edits, clamps positions to valid
candidate ranges, and renumbers sequence/ref/min/client counters. It reduces 45
operations to 15 (`seed-175-minimized.json`). This is a deletion-minimal result for
that reducer, not a claim of globally minimal edit count.

The independent `obliterate-repro.ts` reduces the mechanism further to six ops:

1. C inserts `abcdefghijklm`; everyone receives sequence 1.
2. A inserts `X` at 11 (sequence 2, ref 1).
3. B inserts `Y` at 13 (sequence 3, ref 1).
4. A obliterates [10,13) (sequence 4, ref 1).
5. B obliterates [8,13) (sequence 5, ref 1).
6. Deliver sequence 2 to B. B sees `abcdefghY`, removes [6,9)
   (sequence 6, ref 2), then everyone drains the same log.

A and C end at `abcdefY`; B ends at `abcdef`. The script asserts those exact
results, so it exits 0 only while this pinned oracle defect is reproduced. There
are no markers, annotations, references, surrogate halves, manual minSeq changes,
or snapshot calls in this six-op reproducer. The minimum stays zero throughout.
It uses the real `Client` local methods and `applyMsg`, not handcrafted contents.

## Why this is a legal service/runtime schedule

All source paths below are relative to `reference/fluidframework-3.11.0/`.

- `server/routerlicious/packages/lambdas/src/deli/lambda.ts:935-957` rejects a
  submitted refSeq below the service minimum, not a refSeq behind the newest
  sequenced operation. Lagging clients can submit with pending local operations.
- `server/routerlicious/packages/lambdas/src/deli/clientSeqManager.ts:73-104`
  records each client's advertised reference/client sequence. The farm computes
  the minimum of advertised references, not the largest delivery cursor.
- `packages/dds/merge-tree/src/client.ts:1356-1388` acknowledges an op when its
  sender matches the local client, otherwise applies it remotely, then advances
  sequence/minimum numbers. Local operations are submitted FIFO and their acks
  arrive in that same order. The same envelope is delivered once to every client.
- `packages/dds/merge-tree/src/mergeTree.ts:1151-1169` permits monotonic minSeq no
  higher than currentSeq and runs zamboni on advancement. The farm's explicit
  checkpoint drains all submitted operations and deliveries before advancing;
  it models all clients advertising the drained reference. It never manually
  invokes zamboni on unacknowledged work. Normal ack-time zamboni at
  `mergeTree.ts:1409` is the oracle's own behavior.
- `schedule-audit.ts` checks contiguous delivery and service order, FIFO client
  submission, exact locally generated contents, submission ref equal to the
  sender's currentSeq, monotonic minimum bounded by advertised client refs, and
  checkpoint drainage. Original seed 175 and reduced seed 197 pass these checks.

The failing semantic intersection is overlapping obliterate and subsequent
ordinary removal while local obliterate acknowledgements are outstanding. TS
already special-cases overlapping removals and obliterates in
`mergeTree.ts:2159-2183`; a precise upstream code fix has **not** been established.
Do not port a guessed fix into Swift.

## Exact exclusion

The farm compares the complete first 135 mutation requests from `seed-175.json`
plus the next candidate edit against the recorded first 136 requests. Only on
exact equality does it omit that one triggering B remove. It does not skip seed
175, disable any edit kind, ignore a result, or change the convergence check.
Any changed request, client, position, contents, sequence, ref, min, or ordering
prevents the match. The rest of seed 175 continues normally.

## New failure: seed 197 (not excluded)

The attempted `--seeds 0..500` run passed seed 175 with the exact exclusion, then
failed seed 197: A length 3 versus B length 8. `seed-197.json` preserves the
original mutation trace. `minimize.ts 197` reduces it to 19 operations; the reduced
trace passes the schedule audit but ends at A/C length 4 versus B length 5.
The last three operations are a concurrent A insertion, B insertion, and B
obliterate after earlier removals/obliterates and a drained minSeq checkpoint.
This is **not** the six-op seed-175 remove pattern. No second exclusion has been
added. Next work is to simplify that preceding history and determine the exact
obliterate/reclamation interaction. The 500-seed oracle prerequisite remains red.
