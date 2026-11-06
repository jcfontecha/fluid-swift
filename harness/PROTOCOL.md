# Differential harness protocol

The harness proves the Swift implementation matches the TS oracle by running **mixed sessions**:
one simulated document whose clients live in different *peers* (the TS oracle and the Swift
implementation), all consuming one sequenced op log.

```
              ┌──────────── driver (TS, harness/src/driver) ────────────┐
              │ seeded generator · sequencer · per-client cursors ·     │
              │ comparator · trace writer                               │
              └──────┬───────────────────────────────────────┬──────────┘
        JSON-RPC over stdio                       JSON-RPC over stdio
              ┌──────┴──────┐                         ┌──────┴──────┐
              │ ts peer     │  clients A, C, …        │ swift peer  │  clients B, D, …
              │ (oracle)    │                         │ fluid-swift-│
              └─────────────┘                         │ peer        │
                                                      └─────────────┘
```

The driver is the only component that sequences. Peers never talk to each other.

## Scope (phase 0)

Channel level: each client hosts **one DDS channel** behind a mock container runtime, mirroring
`MockContainerRuntime` + `MockFluidDataStoreRuntime` from `@fluidframework/test-runtime-utils`.
Op `contents` are the DDS op exactly as passed to `submitLocalMessage`; there is no datastore
envelope, batching, compression, chunking or ID allocation. Container-level sessions against a real
service come later and extend this protocol.

## Transport

- Peer is launched by the driver; requests on stdin, responses on stdout, **one JSON object per
  line**, UTF-8. Logs go to stderr only.
- JSON-RPC 2.0 shape. One request in flight at a time; the driver waits for each response.
- Every JSON text on the wire is produced by `JSON.stringify` (TS) or `FluidJS.JSONEncoder`
  (Swift), which must be byte-identical for equal values.
- An error is `{"jsonrpc":"2.0","id":n,"error":{"code":-32000,"message":"…"}}`. A peer error
  during a session fails the session (it is a finding, not something to retry).

## Messages

`UnsequencedMessage` — produced by a peer when its client submits:

```json
{ "clientId": "A", "clientSequenceNumber": 1, "referenceSequenceNumber": 0, "contents": { … } }
```

`SequencedMessage` — produced by the driver, delivered to every client in log order:

```json
{ "clientId": "A", "clientSequenceNumber": 1, "referenceSequenceNumber": 0,
  "sequenceNumber": 1, "minimumSequenceNumber": 0, "type": "op", "contents": { … } }
```

`SummaryTree` — the channel summary as returned by the TS `SharedObject` summarize call, in
`ISummaryTree` JSON form. Phase 0 blobs are strings:

```json
{ "type": 1, "tree": { "header": { "type": 2, "content": "{\"value\":5}" } } }
```

## Methods

| Method | Params | Result |
|---|---|---|
| `hello` | `{}` | `{ "implementation": "ts" \| "swift", "ddsTypes": [string] }` |
| `createClient` | `{ clientId, ddsType, channelId, sequenceNumber, summary }` | `{}` |
| `edit` | `{ clientId, edit }` | `{ "outbound": [UnsequencedMessage] }` |
| `process` | `{ clientId, message: SequencedMessage }` | `{ "outbound": [UnsequencedMessage] }` |
| `state` | `{ clientId }` | `{ "state": JSONValue }` |
| `summarize` | `{ clientId }` | `{ "summary": SummaryTree }` |
| `disposeClient` | `{ clientId }` | `{}` |

- `createClient`: `summary: null` creates a new attached channel with empty state at
  `sequenceNumber` 0. A non-null summary loads the channel from it; the client's last processed
  sequence number is `sequenceNumber`.
- `edit`: performs one local edit through the DDS public API and returns every message the client
  submitted as a result (flush mode immediate). `referenceSequenceNumber` is the client's last
  processed sequence number.
- `process`: delivers one sequenced message. The client treats it as local iff
  `message.clientId == clientId`, and then matches it against its oldest pending message by
  `clientSequenceNumber` (as `MockContainerRuntime.processInternal` does).
- `state`: the DDS's observable state in its canonical form (per DDS, below).
- `ddsType` is the DDS factory type string, e.g. `https://graph.microsoft.com/types/counter`.

## Sequencing (driver)

- Unsequenced messages enter a FIFO queue in submission order. A *sequence* step pops the head,
  assigns `sequenceNumber = ++seq`, and appends to the log.
- `minimumSequenceNumber` = min over connected clients of that client's latest
  `referenceSequenceNumber` (initialized to the client's join `sequenceNumber`), matching deli.
- Each client has a **cursor** into the log. A *deliver* step advances one client's cursor by k,
  calling `process` for each message. Clients therefore lag independently, so edits carry varied
  `referenceSequenceNumber`s — the concurrency that conflict resolution must handle.
- *Join*: a new client is created from `summarize` of an existing client with **no pending local
  messages**, starting at that client's cursor. Clients may join on either peer regardless of
  which peer produced the summary.

## Checks

At a *checkpoint*, the driver sequences everything and delivers to every client, then:

1. `state` of every client is deep-equal.
2. `summarize` of every client is identical as JSON text (blob strings byte-exact).

Any mismatch, peer error, or protocol violation (wrong `referenceSequenceNumber`,
`clientSequenceNumber` not strictly increasing per client) fails the seed. A failing seed writes a
trace (`harness/traces/<seed>.jsonl`, every request/response in order) that `replay` re-runs
exactly.

## Per-DDS contracts

### Counter — `https://graph.microsoft.com/types/counter`

- edit: `{ "kind": "increment", "amount": <integer> }` → `SharedCounter.increment(amount)`.
- state: `{ "value": <number> }`.

## Harness generation

Clients are assigned to peer slots round-robin (two `ts` slots are separate processes).
The fixed Mulberry32 generator uses 2–5 initial clients, up to 10 after joins, and 120 random
steps per seed. Integer increments near ±2^53 are isolated between checkpoints, then undone
before random concurrent edits resume: JS addition is not associative outside the safe-integer
range, so concurrent boundary probes can make even two real TS counters disagree legitimately.
Ordinary increments in [-100, 100] retain arbitrary edit/sequence/delivery interleaving.
The sequencer updates the sender's latest reference when sequencing its message, before
computing the minimum over all clients; receiving a message alone does not advance that reference.

## Service mode (M1)

`npm run service -- --seeds 0..9` owns a tinylicious 7.0.1 process on port **7073**
with temporary storage, and launches `.build/debug/FluidServicePeer`. It uses the same
JSON-RPC stdio framing. Requests are serialized; each has `params.client` (a local
client handle). Runtime payloads are recorded, not interpreted in Swift.

| Method | Additional params | Result |
|---|---|---|
| `open` | `endpoint`, `document` | view (connection may still be waiting for its own join) |
| `view` | none | view, or error if processing failed |
| `disconnect` | none | null |
| `reconnect` | none | null (retains protocol state and observation log) |
| `signal` | `content` (serialized runtime signal envelope) | null |

A view contains the loaded `snapshotSequenceNumber`, `sequenceNumber`, `minimumSequenceNumber`, quorum `members`,
`proposals`, `values`, raw `audience` entries, `clientId`, `connected`, raw received
`ops`, and raw `signals`. `opSources` is parallel to `ops`, containing `socket` or
`storage`: tinylicious's REST deltas and live broadcasts can carry **different
trace fields for the same sequence number**. No fields are stripped or normalized.
Socket entries compare byte-for-byte with the TS inbound queue before protocol
mutation; storage entries compare with the real TS driver's delta-storage stream.
Quorum and audience compare against the live TS container at equal sequence numbers.

Each seed creates/attaches a TS SharedMap container, opens Swift at creation, edits
from TS, obtains a real acknowledged TS summary, opens another Swift client from
that snapshot, adds a second TS writer, checks a pending quorum proposal while that
writer's outbound queue is paused, resumes it and checks commitment, sends a runtime
signal, disconnects the second TS client, and disconnects/reconnects Swift across a
TS edit. Failures write `traces/service-<seed>.jsonl` with RPC exchanges and checkpoint
views. Service runs clean up their processes and temporary storage on success/failure.

## H1 — container-runtime operation lifecycle

`npm run fuzz:oplifecycle` builds `FluidOpLifecyclePeer` in release mode using
`--scratch-path .build/h1`, then checks seeds 0–999. `--self` runs TS against TS;
`--seeds=10` selects the first ten seeds. No package installation or service is needed.
The peer accepts newline-delimited `{method:"outbound"|"inbound",value:...}` requests,
returns one JSON value per line, and exits nonzero on malformed input. Requests are
serial, with a 30-second response deadline. Failure scenarios (including seed and
configuration) are saved to `harness/traces/oplifecycle/<seed>.json`.

The oracle imports the installed 3.11.0 internal classes directly: Outbox (which
owns the real BatchManagers), OpGroupingManager, OpCompressor, OpSplitter and
RemoteMessageProcessor/OpDecompressor. A real PendingStateManager receives flushes.
The deterministic Mulberry32 generator covers three flushes per seed, grouping
on/off, singleton/multi-message/empty replay batches, explicit replay identities,
ID creation-range envelopes, UTF-16 surrogates, quoting, threshold configurations
(including 614400), and small through multi-chunk payloads. The Swift peer is only
an adapter: batching, transformation and inbound state live in FluidContainerRuntime.

Outbound comparison is exact for serialized uncompressed runtime contents and
metadata. LZ4 compressed bytes intentionally differ between native liblz4 and
lz4js: both payloads are decompressed by the **real TS OpDecompressor** before
comparison. Chunk streams are reassembled only for this payload comparison.
Independently, each Swift compressed payload is passed through the **real TS
OpSplitter** at the configured chunk size; every emitted Swift chunk, envelope,
metadata and serialized chunk-content string must match that oracle output.
Thus differences in codec compression ratio may legitimately change chunk counts,
but cannot hide incorrect chunk sizes, boundaries, framing or final metadata.

Inbound comparison feeds the complete TS wire stream into Swift and compares every
RemoteMessageProcessor result, including null intermediate chunks, batch starts,
key messages, synthetic grouped CSNs and outer batch-start CSNs. The same check is
performed on the Swift wire stream, proving the actual TS decoder accepts it.
Streams are compared with their own sequenced envelopes: differing native compression
ratios legitimately move the final chunk's CSN/sequence number. Missing object
properties are compared as their JSON wire representation, not JS `undefined` keys.

Focused Swift Testing cases port the upstream lifecycle invariants: singleton
bypass, boundary markers, grouped CSNs and identity, UTF-16 splitting/extra empty
chunk, corruption and partial-stream clearing, allocation-before-marking, staged
send suppression, rollback LIFO, marker alternation, exact compression threshold,
empty replay and disconnected pending registration, and synchronous rebase.
Run `swift test --scratch-path .build/h1 --filter FluidContainerRuntimeTests`.

Test-first evidence: the initial TS self-check passed; Swift's API skeleton failed
seed 0 and both initial Swift tests. Native implementation passed 1,000 seeds in
both directions. A planted `chunkId = i + 2` mutation failed seed 7; it was reverted.
Pending-registration and disconnected-empty tests each exposed a separate red case
before their fixes. These are lifecycle tests, not claims of a complete runtime.

Next lanes supply the real pending-state/ack/reconnect policy, ID compressor range
producer, document schema and compatibility configuration, summary persistence of
partial chunks, and datastore dispatch. Outbox exposes synchronous submit, flush,
allocation, resubmit and pending-registration hooks; RemoteMessageProcessor takes
sequenced JSON envelopes and returns the same result shapes as TS. Loader wiring,
legacy loader submission, historical initial-partial-stream recovery, summarizer,
GC and datastores are not implemented by this lane. Live chunk processing is strict.

## Merge-tree mode (F1, implementation in progress)

`npm run fuzz:mergetree -- --peers ts,ts --seeds 0..499` uses isolated
stdio peers around the real 3.11.0 `Client`, not SharedString or a rewritten TS
model. The oracle subclasses `Client` only to expose its internal tree and
short-ID lookup, matching the upstream TestClient technique. It uses upstream
TextSegment, Marker, perspectives, local references and both snapshot writers.
The packaged TestClient itself imports an unavailable private testing dependency,
so the oracle does not load that module or install dependencies.

Build the independent native peer with
`swift build --scratch-path .build/f1 --target FluidMergeTreePeer`.
`--peers ts,swift` launches `.build/f1/debug/FluidMergeTreePeer`; it never uses
or changes the phase-0 peer owned by E1.

Each slot hosts shadow copies of A, B and C. A client's authoritative slot is
its index modulo peer count; its generated op enters the single driver-owned
FIFO sequencer. Shadows apply identical local edits and compare generated ops,
then consume the same wire log. This compares each client's optimistic and
historical state against its corresponding oracle, as well as cross-client
convergence after delivery. The driver maintains independent client cursors,
submission counters, and latest submitted reference sequences. At fully drained
checkpoints, a simulated all-client heartbeat advances minSeq to the current
sequence. No minSeq advance occurs while messages remain in flight.

Methods: `reset`, `create`, `edit`, `process`, `state`, `minSeq`, `snapshot`.
Requests use the usual JSON-RPC framing with a local `params.client` identifier.
`edit` returns the upstream op directly, or null for a local-reference edit.
`process` takes the sequenced message in `params.message`. `snapshot` takes
`version: "legacy" | "v1"` and returns the upstream summary tree, retaining blob
strings byte-for-byte. `state` returns UTF-16 `text` units, `length`, ordered
visible `segments`, local `references`, and `lengths` for each sequence from
minSeq through currentSeq crossed with client IDs A/B/C. The local-client
getLength fast path intentionally reports the current local length.

The 120-step seeded farm includes text/marker insertions, ordinary removal,
annotation and sliding/staying/transient references. Obliterate is disabled,
matching the production default; the oracle enables it only for explicit repros.
Strings include lone surrogates, paired surrogates, LF and non-ASCII text;
positions are uniformly chosen UTF-16 offsets, including between surrogate halves.
All corresponding peer responses compare structurally; snapshot blob strings
compare exactly. Failure writes `traces/mergetree-failure.jsonl`, including seed,
peer slot, requests and responses. Reconnect and snapshot loading are not yet
part of this protocol.

**Production oracle gate is green:** all 500 TS/TS seeds (0–499), no exclusions.
The archived seed-175 and seed-197 failures both use experimental obliterate.
Repro scripts explicitly enable it and retain the strict schedule audit.

`--obliterate --peers ts,ts` runs the pinned upstream field farm, not the shadow
protocol above. It uses TestClient, the upstream RNG and field operations, sided
obliterate + annotate-adjust, 3 clients, lengths 1–512 doubling, 8 rounds, and
ops/round 1–128 doubling, testing exact and zero-length field replacements.
The unpublished RNG subset is transpiled from the read-only reference tree into
ignored node_modules; best-random is pinned to 1.0.0. Seed 0 passes the entire
matrix. No Swift obliterate support is claimed. The upstream merge-tree farm has
no seed skips; SharedString's different workload skips 51/AB#7220, 71/AB#35446,
68/AB#45138, which are documented but not applied to unrelated random streams.

`npx tsx src/mergetree/core-check.ts` passes 1,000 TS/Swift seeds with
insert/remove/raw annotations, optimistic state, pending legacy snapshots,
historical lengths and byte-exact V1/legacy blobs. This is narrower than the
full farm: full mixed seed 0 still stops on unsupported local references.
A deliberately reversed Swift insertion tie-break was caught by the FULL farm
on seed 0 (text-order mismatch), then reverted and the peer rebuilt.

PropertiesManager now handles production raw-property pending overlays, remote
consensus, split copies, acknowledgements and legacy reconstruction. Remaining:
stable identities/local references, §4 class split, incremental block-tree partial
lengths, physical zamboni, snapshot readers, pending regeneration/rollback and
reconnect. See `src/mergetree/README.md` for exact validation and next steps.

## H2 — ID compressor

`npm run fuzz:idcompressor -- --self` runs the installed 3.11.0 IdCompressor
against independent TS twins. Without `--self`, the driver builds the native
FluidIdCompressorPeer with `--scratch-path .build/h2` and compares 1,000 seeds.
`--seeds=N` selects a smaller farm. Each newline request is one scenario
`{sessions,version,commands}`; the response is the ordered command results.
Every command compares its return value and exact base64 local/summary state.
The entire response is also compared as raw JSON text, retaining creation-range
property order and JS number spelling.
The seeded scheduler queues per-session creation ranges and chooses their global
finalization order, preserving each session's FIFO. It covers eager finals,
cluster overflow/expansion, capacities 1 through 2^20, normalization, UUID
carry, pending-state reload, summary reload and reconnect cursor reset.
Frozen oracle snapshots additionally exercise V3 root/child sharding state,
stride-based generation, version upgrade preservation and Number.MAX_SAFE_INTEGER
allocation edges. Shard creation/synchronization/reclaim and ghost-session
cleanup have focused Swift tests; they are not randomized by this scheduler.

Test-first evidence: the TS self-check passed 1,000 seeds; the initial Swift
API skeleton failed all five initial tests. A planted `claimed = overflow +
requestedClusterSize + 1` failed seed 0 with `Unknown op space ID` / peer exit,
then was reverted. Run focused tests with
`swift test --scratch-path .build/h2 --filter FluidIdCompressorTests`.

Failures retain scenarios under `traces/idcompressor/<seed>.json`.

## H3 — pending state, reconnect, stash and allocation integration

`npm run fuzz:pendingstate -- --self` checks independent real 3.11.0 TS instances;
without `--self`, it builds `FluidPendingStatePeer` with `--scratch-path .build/h3`
and compares the complete response as raw JSON text. Every seed runs both the
original duplicate-detector scenario and a three-client runtime scenario.
Default: 1,000 seeds; `--seeds=N` reduces the farm. Failures retain their input in
`traces/pendingstate/<seed>.json`.

The original `{snapshot,commands}` protocol remains supported: `process`,
`summary`, and `reload` exercise explicit/derived batch identities, duplicate
windows, strict MSN eviction, summary round trips, and lone-surrogate identities.

Runtime requests are `{runtime:true,seed,uuids,commands}`. Commands carry
`{kind,client,count,ids,rebase}`; kinds are `submit`, `disconnect`, `connect`,
`deliver`, `drop`, `duplicate`, and `reload`. The driver owns the ordered wire
queue and sequence numbers. Three clients use the real Outbox, PendingStateManager,
RemoteMessageProcessor, DuplicateBatchDetector and IdCompressor. Native glue lives
in `ContainerRuntime`, not the peer. Datastore contents are opaque; the resubmit
callback either preserves them or replaces their inner content deterministically.

Each seed covers sent-but-unacked batches, disconnected submissions, changed
connection IDs, resubmission, fresh-instance stash application, acknowledgments
before and after reconnect, duplicate delivery, and interleaved ID allocations.
Comparisons include every outbound batch, inbound local/remote/duplicate
classification and correlated metadata, pending count and dirty state, serialized
pending records, complete stash captures, generated IDs and stable IDs, and the
session-inclusive compressor serialization after every command. UUID entropy is
an explicit input shared with Swift, not normalized out of the output.

Reconnect resets the compressor cursor and drops old allocation messages during
resubmit; Outbox generates the replacement allocation. The planted opposite
behavior failed seed 0 with `Ranges finalized out of order`; the mutation was
reverted. Evidence: `src/pendingstate/fixtures/allocation-replay-divergence.txt`.
The TS self-check and Swift differential both pass 1,000 seeds. This certifies
the named pending-state integration slice, not the full ContainerRuntime:
staging commit/discard, schema/blob/GC services, loader connection arbitration,
and aggregate blob/host dirty-event reentrancy are outside this farm.

Regression commands can share the isolated H3 build directory:
`npm run fuzz:oplifecycle -- --scratch-path=.build/h3` and
`npm run fuzz:idcompressor -- --scratch-path=.build/h3`.

## T1 — SharedTree change-family oracle (not yet native-certified)

`npm run fuzz:tree-changes -- --self --seeds=1000` invokes the installed 3.11.0
ModularChangeFamily and real sequence/optional editors. Input is
`{seed, edits:[{kind,index,count,destination,field}]}`. Kinds are insert, remove,
move, revive, set, clear, crossMove and nested. All edits describe a common base
with two populated sequence fields, a populated optional field, nested children
and detached roots. Sequential composition first rebases the second concurrent
edit. Every seed contains all eight kinds plus sixteen seeded random choices.

Results include editor changes, singleton compose, undo, rollback, rebase,
pair composition, rebase over rollback and rebase over composition. Each result
is encoded with modular versions 3/4/5, selecting sequence 2/3 and optional 2.
Real compressor-backed RevisionTagCodec handles IDs. Encoded JSON strings compare
exactly across independent TS runs and encode/decode/encode. Semantic comparisons
use upstream areEquivalent for singleton compose, empty-base rebase, codec
roundtrip and rebase-over-composition; these are not the full upstream axiom suite.
Failures save `traces/tree/<seed>.json`. No seeds or formats are skipped.

**Current TS gate is red at seed 17:** raw multi-revision composition containing
Rename fails modular 3 / sequence 2 encode's internal decode with `0x996`.
Supplying an implicit context revision instead fails `0x964` because the result
has two revisions. `npx tsx src/tree/codec-precondition.ts` is the two-edit repro;
it verifies those failures and successful modular 4/5 roundtrips. This is a
raw-result serialization limitation, not proof that ordinary SharedTree ops fail.
The harness does not silently squash/relabel revisions to bypass it.

The default mixed command deliberately fails because no Swift change-family peer
exists. Native FluidTree currently contains RevisionTagCodec, ChangeAtomIdCodec
and DefaultAtomIdAliasAllocator only. Swift Testing covers these, including
1,000 generated real-TS identity fixtures (`src/tree/identity-fixtures.ts`). An
atom-codec `localId + 1` mutation was detected and reverted; this is identity-only
mutation evidence, not sequence rebase certification. See `src/tree/README.md`
for isolated build/test commands and remaining work.
