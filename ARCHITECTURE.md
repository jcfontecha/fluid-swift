# Architecture

A native Swift implementation of the Fluid Framework client, wire- and summary-compatible with the
TypeScript client (`microsoft/FluidFramework`). The TypeScript client is the specification: where
this document and observed TS behavior disagree, TS wins and this document is wrong.

Oracle version: `@fluidframework/*` **3.11.0** from npm (pinned in `harness/package.json`).

## Decisions

### 1. Correctness is defined by the differential harness

No Swift code merges unless it produces the same observable state, the same summaries (byte-exact
blob strings) and wire-compatible ops as the TS oracle under seeded fuzzing in **mixed sessions**:
TS and Swift clients in one document, each consuming the other's ops. See
[`harness/PROTOCOL.md`](harness/PROTOCOL.md).

Every lane is **test-first**. Before any implementation, the failing tests land: ported TS unit
tests, golden fixtures generated from the TS oracle, and harness scenarios. The implementation is
done when those tests pass, not before. Work is routed by difficulty, not by phase. Mechanical
porting (types, codecs, straightforward DDS logic, test transliteration) goes to small, cheap
models in well-bounded units, because a red test suite pins the behavior. Hard porting goes to
strong models, which implement it themselves: conflict resolution, rebase algebra, the op
lifecycle, and divergence debugging, with Astra on the most challenging parts. Strong models
also write the tests and review.

### 2. One owner per container; DDS code is synchronous

The TS runtime relies on a single-threaded event loop: op processing, local edits and event
emission happen in a fixed order with no interleaving. Swift mirrors this exactly. Everything a
container owns (loader, runtime, datastores, DDSes, merge-tree, SharedTree) is plain, synchronous,
non-Sendable code — no `async`, no locks, no `Task` in op-apply paths. Async exists only at the I/O
edge (sockets, storage). The whole graph belongs to exactly one owner actor, chosen when it is
created, and runs one event-loop task on that owner. Converged design and evidence:
`specs/design/threading-opus.md` and `specs/design/threading-astra.md`, each ending in a
"Convergence round" section.

- **The owner is an explicit, non-optional `isolated any Actor` argument** on every public factory
  (`loadExistingContainer(_:isolation:)`, `OdspClient.getContainer(_:containerSchema:isolation:)`).
  Apps pass `MainActor.shared` and hold DDS references directly in MainActor code. Headless
  clients, summarizer children and harness peers pass a private actor. There is no default and no
  `= #isolation` form: in Swift 6.4 that form lets a nil owner escape, and TSan reports races.
- **Loading is off-owner.** A `@concurrent` preparation step downloads and parses the snapshot and
  applies stored ops, then returns the graph as `sending`. The owner adopts it before anyone else
  can see it.
- **Submission is synchronous.** `submit`/`submitSignal` enqueue in FIFO order onto one ordered
  transport writer; no `await` sits between preparing a message and enqueueing it. Local flushing
  follows TS TurnBased batching (`scheduleFlush`); there is no app-facing forced-flush `edit {}`.
- **Catch-up yields only at a runtime `batchEnd`**, as TS `DeltaScheduler` does, with a fixed 4 ms
  slice for interactive owners. Lockstep harness peers call the synchronous core directly and never
  run the scheduler.
- **Events are synchronous owner-local callbacks.** `AsyncSequence` and Observation are app-side
  adapters only. Apps need no OT layer between UI and DDS.

### 3. JavaScript value semantics are reproduced, not approximated (`FluidJS`)

- **Numbers are `Double`.** Every DDS-visible value that is a JS `number` is a `Double` in Swift,
  so overflow and precision match JS. Protocol counters (sequence numbers) are `Int`: they are
  integers below 2^53, exact in both, and decoding rejects anything else.
- **Strings are UTF-16 code units.** `JSString` stores `ContiguousArray<UInt16>`. JS strings may
  contain lone surrogates (a TS client can insert text inside a surrogate pair), which Swift
  `String` cannot represent. All positions/lengths are UTF-16 offsets, as in TS.
- **Objects follow JS property order** (`JSObject`): array-index keys (`"0"`…`"4294967294"`)
  ascending first, then all other keys in insertion order — enforced by the type, so iteration and
  encoding both match `Object.keys` / `JSON.stringify`.
- **`JSONEncoder` output equals `JSON.stringify`**: ECMAScript `Number::toString` formatting
  (`1` not `1.0`, `1e+21`, `1e-7`, non-finite → `null`) and `JSON.stringify` string escaping
  (well-formed escapes for lone surrogates). Foundation `JSONSerialization` / `Codable` JSON are
  not used for anything that crosses the wire or enters a summary.

### 4. Layout mirrors the TS packages

One Swift target per TS package, named `Fluid<Package>` (`FluidCounter` ↔ `@fluidframework/counter`),
so ports, specs and upstream diffs map 1:1. The mapping holds inside a package too: each TS class
gets a Swift type with the same name and the same responsibilities. Each type's doc comment names
the TS file it ports. Do not collapse several TS classes into one namespace of static functions.

Code is written for review: one statement per line, no `;`-joined statements, small functions,
and a comment wherever behavior mirrors a non-obvious TS rule (cite the assert code or the spec
section). This applies to harness TypeScript too. Shared JS semantics live in `FluidJS`. The harness peer
is the executable `fluid-swift-peer`.

### 5. Performance is designed in, then measured on device

- Value types and contiguous storage in hot structures (columnar chunks in SharedTree's forest, not
  one class instance per node).
- Native C libraries where TS uses JS ports (lz4).
- On-device benchmarks start with the first DDS and gate regressions from then on.
