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

## Scope (channel foundation)

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
| `events` / `queries` | `{ clientId }` | `{ events: JSONValue[] }` / `{ queries: JSONValue }` |
| `summarize` | `{ clientId }` | `{ "summary": SummaryTree }` |
| `disconnect` | `{ clientId }` | `{ outbound }` |
| `reconnect` | `{ clientId, newClientId }` | `{ clientId: newClientId, outbound }` |
| `membership` | `{ clientId, members: string[] }` | `{ outbound }` |
| `flush` / `rollback` | `{ clientId }` | `{ outbound }` |
| `stash` | `{ clientId, contents }` | `{ outbound }` |
| `reset` | `{}` | `{}` |
| `disposeClient` | `{ clientId }` | `{}` |

- `createClient`: `summary: null` creates a new attached channel with empty state at
  `sequenceNumber` 0. A non-null summary loads the channel from it; the client's last processed
  sequence number is `sequenceNumber`.
- `edit`: performs one local edit through the DDS public API and returns every message the client
  submitted as a result (flush mode immediate by default). `referenceSequenceNumber` is the client's last
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

Summary bytes are **not** a cross-replica invariant in TS. They depend on each client's local
history. For example, SharedMap's header key order depends on when each key was applied locally,
and SharedDirectory's creator-ID lists change when a client calls `createSubDirectory` on an
existing child (see "Oracle preconditions" below). So byte-exactness is checked against
a **lockstep TS twin**, where TS is deterministic, and cross-replica checks are semantic.

**Lockstep twin.** Every client that does not run on the TS peer has a twin on the TS peer:
- The twin has the same `clientId`. Anything else a client's identity feeds into (ID-compressor
  session IDs, quorum and audience membership) is identical between the two.
- The twin receives exactly the same calls, in the same order: every `edit`, `process`, flush,
  rollback, stash, disconnect/reconnect and membership change.
- The twin's outbound messages are never sequenced. The driver compares them with its subject's
  outbound messages after every call.
- The twin sees the subject's own ops as local acks, exactly as the subject does.

On every call, the subject's outbound messages must equal its twin's, byte-exact as JSON text.

At a *checkpoint*, the driver sequences everything and delivers to every client, then:

1. **Across replicas:** `state` of every client is deep-equal.
2. **Against the twin:** each subject's `state`, `summarize` output and recorded events equal
   its twin's, byte-exact as JSON text.
3. **Cross-load:** each client's summary, loaded by a fresh TS client and by a fresh Swift client,
   yields that same `state`. The fresh clients are discarded afterwards.

In `--peers ts,ts` self-check runs, the second TS peer plays the subject, so the twin machinery
itself is exercised against TS.

Any mismatch, peer error, or protocol violation (wrong `referenceSequenceNumber`,
`clientSequenceNumber` not strictly increasing per client) fails the seed. A failing seed writes a
trace (`harness/traces/<seed>.jsonl`, every request/response in order) that `replay` re-runs
exactly.

## Per-DDS contracts

### Counter — `https://graph.microsoft.com/types/counter`

- edit: `{ "kind": "increment", "amount": <integer> }` → `SharedCounter.increment(amount)`.
- state: `{ "value": <number> }`.

### Other DDS contracts (E1)

Names accepted by `--dds` are the following names, comma-separated, or `all`.
`hello.ddsTypes` contains the actual factory URLs, not these CLI aliases.
A Swift adapter must reproduce the TS adapter in `src/dds.ts` exactly:
the same API call per edit, the same `state`, `queries` and event journal JSON
(property order included; `undefined` members are omitted, as `JSON.stringify` does).
`canonicalValue(v)` is `v` with handles encoded, or `{"$fluid":"undefined"}` for undefined.
Sorted means JS `<` on keys, which compares UTF-16 code units.

| Name | Edit → API call | `state` | `queries` | Events (`[name, ...args]`) |
|---|---|---|---|---|
| map | `set{key,value,valueKind?}` → `set`; `delete{key}`; `clear` | sorted `[key, canonicalValue][]` | `{}` | `valueChanged {key,previousValue}, local`; `clear local` |
| directory | as map, plus `path`; `createSubDirectory`/`deleteSubDirectory{path,name}` on `getWorkingDirectory(path)` | `{entries: sorted pairs, children: [name, state][]}` in `subdirectories()` order | `{}` | `valueChanged {key,path,previousValue}, local`; `clear local`; `cleared path, local`; `containedValueChanged {key,previousValue}, local`; `subDirectoryCreated`/`subDirectoryDeleted relativePath, local` |
| cell | `set{value,valueKind?:"handle"}` → `set(value)`; `delete` → `delete()` | `{empty, value: empty ? null : canonicalValue(get())}` | `{}` | `valueChanged value`; `delete` |
| task-manager | `volunteer` → `volunteerForTask` (ignores only the "Disconnected/Abandoned before acquiring task assignment" rejections); `subscribe` → `subscribeToTask`; `abandon`; `complete` (tolerates only "Attempted to complete task in disconnected state") | non-empty queues from the `header` summary blob, sorted by task ID | `{canVolunteer, tasks: [{key,assigned,queued,subscribed}]}` for tasks `a`,`b`,`c` | `assigned key`; `lost key`; `completed key` |
| register-collection | `set{key,value}` → `write(key,value)` (a rejection fails the peer) | sorted `[key, read(Atomic), read(LWW), readVersions][]` | `{keys: keys()}` in DDS order | `atomicChanged key, value, local`; `versionChanged key, value, local` |
| ordered-collection | `add{value}`; `acquire{result}` → `acquire` whose callback returns Complete or Release | `{available: header blob, acquired: jobTracking blob sorted by acquire ID}` | `{}` | `add value, newlyAdded`; `acquire value, clientId`; `complete value`; `localRelease value, intentional` |
| pact-map | `set{key,value,valueKind?:"undefined"}` → `set`; `delete{key}` | for keys `a,b,c,0,10,constructor`: `{key, value: get, details: getWithDetails, pending: isPending, proposal: getPending}` | `{}` | `pending key`; `accepted key` |
| shared-summary-block | `set{key,value}`, issued to every client identically | `[key, get(key)][]` for the six keys | `{}` | none |
| shared-array | `insert{index,value}`; `delete{index}`; `move{oldIndex,newIndex}`; `toggle{entryId}`; `toggleMove{oldEntryId,newEntryId}`; `insertBulkAfter{ref?,values}`, each applied as given | `get()` | `{length, values: get(), insertIds, deleteIds, moveIds: [old,new][]}`, the upstream fuzzUtils entry bookkeeping driven by `valueChanged` | `valueChanged op, local` |
| shared-signal | `notify{value}` | `{persistent:false}`; notifications are checked through events, never invented as persistent state | `{}` | `notify value, local` |

TaskManager and ConsensusQueue have no public read API for their global state, so their
canonical state reads the DDS's own summary blobs. Register `keys()` order is twin-only
(see "Oracle preconditions" below); everything else in `queries` is client-relative.

Summary trees and blob strings remain byte-exact against the twin, without normalization.
Map/Directory state sorting does not change their authored summaries. Set edits support
`valueKind: "undefined" | "handle"`: the TS adapter creates actual native handles, not
handle-shaped plain objects. Undefined map entries use `{$fluid:"undefined"}` in canonical
state to distinguish them from null; summaries retain the upstream omitted-value encoding.
`events` drains the domain-event journal. `queries` compares client-relative public queries
against the twin only: assignments cannot be equal across replicas with different identities.
UUID entropy is deterministic per client/method/call ordinal in `entropy.ts`; every UUID
byte still participates in outbound, summary and event comparison. Read-only calls do not
shift mutation entropy. Cross-loading uses every configured implementation, so TS-only runs
can self-check DDSes whose Swift implementations deliberately remain red.
Twin comparisons use each response's exact `result` JSON text, as the peer wrote it.

A client has a stable protocol `clientId` and a changing wire identity. The driver
supplies `newClientId` on reconnect and resets the wire CSN to zero. The TS adapter
uses the upstream reconnection algorithm with only UUID allocation replaced by that
trace-supplied ID. Membership is propagated to every local quorum after joins and
connection changes. A reconnect scenario drains the session, disconnects one client,
makes three offline edits (every DDS except shared-summary-block), then reconnects/resubmits.
It does not yet exercise disconnect with outstanding sequenced acknowledgements or
remote edits during the offline interval. `membership` currently updates quorum,
not audience. Flush/rollback/stash are available as protocol operations but are not
selected by the random scheduler yet. `createClient.flushMode` optionally selects
`turnBased`; default is `immediate`.

### Oracle preconditions

Raw-summary equality across replicas fails in the real TS oracle independently of Swift.
The original Map seed 33 had equal data with header keys in different orders; Directory's
creator-ID arrays also depend on local history. `src/oracle-precondition-check.ts` preserves
a minimal executable proof: calling createSubDirectory on an existing child changes its
creator IDs without submitting an op. The lockstep contract above preserves byte checks
where the oracle actually guarantees deterministic inputs.

ConsensusRegisterCollection `keys()` order is likewise local history. Its summary is a plain
object, so a replica loaded from it enumerates array-index keys (`"0"`, `"10"`) first, while a
live replica keeps arrival order: 17 of `ts,ts` seeds 0..19 failed cross-load on order alone.
Upstream `assertEqualConsensusRegisterCollections` compares `keys()` in order, but its key pool
has no index keys. The canonical state is sorted; `queries.keys` holds the order against the twin.

### SharedArray convergence counterexample (expanded E1)

`tsx src/oracle-array-precondition-check.ts` proves a separate problem in one TS
process, with two clients, two values, six ops and no Swift, summaries, joins or
reconnections. Insert "1" and "2", then move "1" to the end: both see `["2","1"]`.
Concurrently, A undoes the move while B deletes "1". Sequence the undo then the deletion:
both see `["2"]`. B undeletes "1": A sees `["1","2"]`, B sees `["2","1"]` after both have
processed every op.

The cause is in `legacy-dds/src/array/sharedArray.ts`. `handleToggleMoveOp`, `handleMoveOp`
and `handleToggleOp` suppress (or mark dead) an incoming remote change while the receiver
has a local delete or move of that entry pending. Acknowledging the local op
(`handleDeleteOp`) never replays what was suppressed, so the replicas keep different live
positions, which a later toggle exposes. This is a state convergence failure, not summary
order or twin entropy. Upstream knows this class: `arrayFuzzTests.spec.ts` skips seeds 3,
14 and 42 for "Concurrent move/undo-move and delete can resurrect a deleted entry" and
"Concurrent move and delete/toggle undo can restore an entry at its old position".

With the upstream fuzz model, `--dds shared-array --peers ts,ts --seeds 0..199` fails seeds
56, 78, 121 and 189, every one on cross-replica state; seed 56 replays exactly. Each failing
trace processes a remote op that this suppression swallows: a remote move against a local
pending delete (56, 121, 189), or a remote toggle against a local pending move (78).
Comparisons are not loosened and no seeds are skipped; the reference TS client is
read-only. SharedArray cannot be certified green until the coordinator decides how the
harness treats this upstream behavior.

## Harness generation

Clients are assigned to peer slots round-robin (two `ts` slots are separate processes).
The fixed Mulberry32 generator uses 2–5 initial clients, up to 10 after joins, and 120 random
steps per seed. Counter increments in [-100,100] retain arbitrary edit/sequence/delivery interleaving.
Map and Directory use key contention over `a,b,c,0,10,constructor`, deletes/clears, 8,200-unit
values (separate summary blobs), undefined and handle values, and nested directory
create/delete races on the actual tree. Where upstream has a fuzz model
(`packages/dds/<dds>/src/test/fuzzUtils.ts`), the generator follows its operations, weights
and acceptance conditions:

- task-manager: a task from `a,b,c`, then volunteer (if `canVolunteer`), abandon (if
  queued), subscribe, or complete (if assigned), each weight 1, read from the acting
  client's `queries`.
- register-collection: write only, keys `a,b,c,0,10`, random 5-letter values. The index keys
  are added deliberately (see "Oracle preconditions").
- ordered-collection: add (from 3 values) and acquire (Complete or Release), weight 1:1.
- shared-array: insert 5, delete 3, move 3, insertBulkAfter 1, toggle 1, toggleMove 1, with
  upstream indices, 1–5 letter values and entry IDs from `queries`. Index-based operations
  also require a non-empty array: upstream's insertIds bookkeeping can drift non-empty over
  an empty array (`ts,ts` seed 24), and its own generator would then emit a throwing
  `delete(0)`.

Cell, PactMap, SharedSummaryBlock and SharedSignal have no upstream fuzz model; their
generators cover the unit-test surface: Cell plain and handle values; PactMap set,
undefined set and delete (no handles: PactMap summarizeCore uses plain JSON.stringify);
summary-block sets; signal notifications. Rollback, stashed clients and turn-based
batching (upstream `rollbackProbability`, `stashableClientProbability`, rebasing suites)
are not scheduled yet: TS's turn-based mock sends one CSN for a whole batch, which the
strictly-increasing CSN check above would first have to admit.
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

## Merge-tree mode (F1)

Build `swift build --scratch-path .build/f1 --product FluidMergeTreePeer`.
`npm run fuzz:mergetree -- --peers ts,ts --seeds 0..499` and
`--peers ts,swift --seeds 0..999` use isolated stdio peers around the actual
3.11.0 Client and the native Swift Client. F1 never uses E1's peer.

Each peer hosts shadow copies of A/B/C. Generated operations enter the driver's
FIFO sequencer; independent delivery cursors and service-minimum tracking model
optimistic concurrent edits. Peer responses compare structurally, historical
lengths compare at every sequence/client perspective, and snapshot blob strings
compare byte-for-byte. Checkpoints require cross-client text/length convergence.
No production seed exclusions or obliterate operations are enabled.

Methods use JSON-RPC with `params.client`:

- `reset`, `create`: clear peers/create a client. `create.endpointSliding` opts
  into TS's endpoint-sliding behavior; default false.
- `edit`: insert, marker, remove, raw annotate, or local reference. Reference
  types 0/64/128/256, optional slidingPreference 0/1 and canSlideToEndpoint.
- `process`: apply the sequenced envelope in `message`, including grouped ops.
- `state`: UTF-16 text units, visible length/segments, named reference positions,
  and historical A/B/C lengths. Local-client lengths use TS's local fast path.
- `minSeq`: advance the collaboration minimum in `seq`.
- `snapshot`: `version: "legacy" | "v1"`, optional legacy `catchup` envelopes;
  returns the upstream summary tree with exact JSON blob strings.
- `load`: replace the named client from `summary`, including catchup replay.
  Local reference handles are deliberately not persisted by merge-tree snapshots.
- `reconnect`: regenerate all unsequenced pending messages, returning an ordered
  operation array. The farm catches up sequenced messages first, then updates
  queued operations and their reference sequences. It repeats regeneration before
  sending to check idempotence and submitted-message grouping.
- `rollback`: roll back the most recent pending message, without submitting it.

The 120-step farm exercises text/marker insertion, ordinary removal, raw annotation,
references, rollback, reconnect, and snapshot reload. V1 reloads occur both before
and after minimum advancement; legacy reloads occur after it. Catchup and multichunk
loading have additional direct differential scenarios in `snapshot-check.ts`.
Strings include lone surrogates, paired surrogates, LF and non-ASCII characters.
Failure preserves requests and responses in `traces/mergetree-failure.jsonl`.

`reference-check.ts` verifies 32 combinations of endpoint configuration, per-ref
endpoint permission, direction and reference type through deletion/reclamation.
`benchmark.ts` measures large-document many-client op apply including transport.
See `src/mergetree/README.md` for measured results and exact validation status.

`--obliterate --peers ts,ts` is a separate pinned upstream field farm. It never
runs against Swift. Its seed-0 matrix and archived TS divergences remain documented
in the handoff. Obliterate and annotation adjustment remain out of production.

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

`npm run fuzz:tree-changes -- --self --seeds=1000` runs installed 3.11.0
ModularChangeFamily with real sequence/optional editors. Every seed contains
insert, remove, move, revive, set, clear, crossMove and nested, plus sixteen
seeded random edits. `scenario.ts` preserves the previous generator schedule.

Two separate comparison contracts apply:

1. **Algebra:** compose, undo, rollback, rebase and their chains use byte-exact
   modular **5**, the newest available codec, with no implicit revision. There
   is no fallback or seed skipping. Semantic and byte roundtrips are asserted.
   A direct tagged structural projection also compares all enumerable in-memory
   data, preserving Maps, Sets and undefined, including metadata codecs omit.
2. **Wire:** every individual editor change uses its tagged revision as the
   encoding context. Exact bytes and semantic/byte roundtrips are checked for
   every modular writer format, selected through the real Message codec builder.
   `wire-check.ts` independently checks 24,000 edits across 1,000 seeds; it does
   not claim valid shared histories or Swift differential coverage.

Writer gating: ContainerRuntime accepts `oldestSupportedClient`, resolves it to
its internal `minVersionForCollab` (the deprecated alias cannot coexist with the
new option), and propagates it to SharedTree. `treeFactory.ts` gives an explicit
Tree `minVersionForCollab` precedence, then the runtime value, then 2.0.0.
`shared-tree-core/messageCodecs.ts` selects Message 3 at 2.0, 4 at 2.43, 6 at
2.80 and 7 at 2.117. `shared-tree/sharedTree.ts` maps those to SharedTreeChange
and modular 3, 4, 5, 5 respectively; sequence formats are 2, 3, 3, 3 and optional
is 2 throughout. `codec/versioned/codec.ts` chooses the newest compatible format.
`writeVersionOverrides` can select an older compatible format; incompatible or
unstable selections throw unless `allowPossiblyIncompatibleWriteVersionOverrides`
is explicitly true. Experimental SharedBranches maps to modular 4, so introduces
no additional modular format. Outer Message encoding is not covered by T1.

`codec-precondition.ts` remains the seed-17 documentation: modular 3 cannot
serialize the raw composed Rename (0x996, or 0x964 with an implicit revision),
while 4/5 can. This is not an ordinary individual-op compatibility failure.
Seed 17 now passes the split comparison.

**Full TS farm is still red at seed 75, not certified.** `history-precondition.ts`
reduces it to remove b[2..5), revive root:32 at b[3], and concurrently revive
root:32..34 at b[2]. The generator places the same detached cells at inconsistent
base positions; chained rebase asserts 0x8a0 in compareCellPositionsUsingTombstones.
A forest-backed valid-history generator is still needed. Failures save
`traces/tree/<seed>.json`; no seeds are skipped and no expected-failure exception
is added to the farm.

Native FluidTree contains the identity foundation and SequenceFieldEditor only.
Eight Swift tests pass, including 1,000 identity fixtures and 1,000 sequence
editor fixtures (7,000 outputs). The sequence tests failed to compile against
missing native types before implementation. No sequence algebra/codecs,
optional handler, ModularChangeFamily or native change-family transport exists.
The default mixed command therefore continues to fail explicitly. The requested
planted rebase tie-break divergence is not yet exercised. See `src/tree/README.md`.

## H4 — runtime routing, signals and attachment blobs

`npm run fuzz:routing -- --self` checks independent real 3.11.0 TypeScript instances.
`npm run fuzz:routing` builds `FluidRoutingPeer` with `--scratch-path .build/h4`
and compares 1,000 seeds as raw JSON text. `--seeds=N` selects a smaller farm.
Requests are newline-delimited `{seed,uuids,detached,pending,commands}` scenarios;
responses are ordered `{destination,value}` observations. Peer requests have a
30-second deadline. Mismatches retain scenario, expected and actual observations
in `traces/routing/<seed>.json`.

The oracle constructs the real BlobManager, BlobHandle, Outbox and
SignalTelemetryManager. It invokes the installed ContainerRuntime's actual
`validateAndProcessRuntimeMessages`, `processInboundMessages`, and `processSignal`
methods on a prototype-backed host with explicit service stubs. The real
ChannelCollection methods strip datastore envelopes and bunch contiguous ops;
datastore contexts only record calls. GC, schema, and ID-allocation destinations
record dispatch rather than implementing those services again. H2/H3 separately
certify actual ID finalization. Compatibility probes call the installed runtime
option/default and minimum-version validators. Summary reload uses the installed
`loadBlobManagerLoadInfo`, including snapshot blob *values*, not attachment names.

Each seed covers all nine logical ContainerMessageType values, rejection of
`groupedBatch`/future types at the logical boundary, mixed-type outbound grouped
batches, grouped and ungrouped batch event order, contiguous datastore bunching,
missing/deleted datastore decisions, and local metadata/logical CSNs. H1 remains
the transport compression/chunk-reassembly oracle: intermediate `chunkedOp` must
never reach logical dispatch. Signals cover omitted versus empty addresses,
broadcast numbering, targeted non-numbering, null server clients, missing/deleted
stores, extension suffixes including the trailing empty segment, and unknown
slash routes. Listener envelopes, routing decisions, outbound messages and all
blob summary strings are compared without key sorting or payload normalization.

Blob schedules include detached pseudo-storage IDs, deduplication and redirect
patching, legacy creation waiting for ack, pending payload handles, attachGraph,
sharing, original-client acks after pending-state restoration, resume, cache reads,
unknown reads, TTL resubmit, identity reconstruction on summary load, shared-storage
sweep, abort during upload, and authoritative ack defeating a late upload. Storage
is a deterministic byte-preserving stub on both sides. UUIDs and the millisecond
clock are explicit inputs. Each completed command drains TS microtasks before
comparison; native state transitions and callbacks run synchronously on the
container executor. Pending reads remain callback-pending until a matching ack;
there is no invented timeout. Expected command errors compare the command's
failure decision, not engine-specific diagnostic text. Oracle assertions also
require the expected batch/op events and reject unexpected command failures.

Swift Testing ports upstream blob-handle sharing, pending capture, aggregate-work
transitions, TTL's strict half-life boundary, detached dedup/sweep, unknown blob
metadata, pending reads, late upload races and dirty-listener abort. The abort
regression failed before the native fix (`uploads == 0` and `!hasBlob("a")`).
Additional tests cover actual ContainerRuntime outbox/pending/blob-ack integration,
stashed blob bytes, signal addressing, and lone-surrogate handle paths. Initial
skeleton test builds encountered concurrent merge-tree compile errors; those were
not treated as behavioral red evidence. Run:
`swift test --scratch-path .build/h4 --filter FluidContainerRuntimeTests`.

The planted localId→localId redirect mutation was rejected at seed 0 and reverted;
see `src/routing/fixtures/planted-divergence.txt`. The clean 1,000-seed self-check
and native farm pass. Existing farms can use the same isolated build directory:
`npm run fuzz:oplifecycle -- --scratch-path=.build/h4`,
`npm run fuzz:idcompressor -- --scratch-path=.build/h4`, and
`npm run fuzz:pendingstate -- --scratch-path=.build/h4`.

Native source map (paths relative to container-runtime/src unless noted):

| Swift type/functions | TypeScript source |
| --- | --- |
| ContainerRuntime | containerRuntime.ts (routing, signals, op/pending/blob glue) |
| ContainerMessageType | messageTypes.ts |
| ChannelCollection | channelCollection.ts (routing boundary; recording datastore contexts) |
| SignalTelemetryManager | signalTelemetryProcessing.ts (wire tracking counter) |
| BlobManager, BlobHandle | blobManager/blobManager.ts |
| BlobManagerLoadInfo, loadBlobManagerLoadInfo, toRedirectTable, summarizeBlobManagerState | blobManager/blobManagerSnapSum.ts |
| getGCNodePathFromLocalId, isBlobPath | blobManager/blobManager.ts |
| getMinVersionForCollabDefaults, validateRuntimeOptions | containerCompatibility.ts |
| validateMinimumVersionForCollab | runtime-utils/src/compatibilityBase.ts |

The host must serialize storage completions onto its container executor. Native
BlobManager's storage/read completions are its asynchronous I/O boundary, not
Tasks or actors inside op application. Its explicit local-ID overload supports
harness entropy; normal creation uses its injectable UUID generator. Runtime
schema/GC services, datastore materialization, extension acquisition/version
negotiation, and telemetry logging/latency statistics are not reimplemented by
this routing lane. The signal counter and all wire-tracking fields are native.

## H5 — datastore runtime and channel contexts

`npm run fuzz:datastore -- --self` runs independent real 3.11.0
`FluidDataStoreRuntime` instances with real SharedMap, SharedDirectory and
SharedCounter factories. `npm run fuzz:datastore` builds `FluidDatastorePeer`
with `--scratch-path .build/h5` and compares raw JSON text for 1,000 seeds.
`--seeds=N` selects a smaller farm. Each newline-delimited request is `{seed}`;
failures preserve input and both outputs in `traces/datastore/<seed>.json`.
The native peer has a 30-second response deadline.

Every seed exercises detached creation and edits, binding, datastore attachment,
local acknowledgments, contiguous inbound channel ops, connection transitions,
DDS resubmission, counter rollback, handle storage in a map, summary reload into
lazy remote contexts, deferred inbound replay, stashed DDS ops and captured
metadata expansion, late channel attach ops, and stashed attach loading into a
rehydrated local context. Numeric map keys, deletions, emoji and lone surrogates
vary with the seed. The detached map stores a handle to an initially unbound
counter, exercising transitive attach-graph binding. The oracle asserts counter state, reload state and stored
handles independently of native comparisons. Both targeted and broadcast signal
submissions and inbound signals are observed.

Comparisons include container-level envelopes produced at the minimal context
boundary, attach `ITree` strings (including `.attributes` and `.gcdata`), channel
summaries, datastore summaries wrapped in `.channels` plus `.component`, GC
routes, resolved and stored handle URLs, and DDS state. Native context metadata
is retained in generic boxes; only local token IDs cross the existing native
container pending-state seam, never DDS metadata on the wire. The twin runs the
same local history; summary blobs are not sorted or normalized. Reload storage
is deterministic and byte-preserving; the oracle uses real summarizer nodes for
remote contexts and the installed wrapping helper for container summary layout.

Swift Testing ports cover datastore/channel ID validation, empty GC, disposal,
bound/unbound attach summaries, pending attach acknowledgments, lazy remote
message replay, local rollback/stash rejection and activity cleanup, short/legacy
registry names, compact ID namespaces, unloaded detached attach-summary reuse,
lone-surrogate and empty handle paths, real ChannelCollection routing, transitive handle binding, and a DDS edit traveling
through ContainerRuntime outbox, pending correlation and local acknowledgment.
Run `swift test --scratch-path .build/h5 --filter FluidDatastoreTests`.
Sixteen H5 tests pass with the normal focused Swift test command. While another lane has uncompilable test sources, the
focused target can be built with `swift build --scratch-path .build/h5 --target
FluidDatastoreTests`, then its `.xctest` bundle run through Xcode's
`swiftpm-testing-helper --test-bundle-path <bundle>/Contents/MacOS/FluidDatastoreTests
--testing-library swift-testing`, with Xcode's Developer frameworks and
Developer/usr/lib on the corresponding DYLD search paths. This avoids building
or loading unrelated unfinished test targets; it is not a whole-repo green claim.

A planted `.channels` -> `.wrong-channels` mutation in the native integration
was rejected at seed 0, then reverted. See
`src/datastore/fixtures/planted-divergence.txt`. Clean self-check and differential
farms each pass 1,000 seeds; all four existing runtime farms also pass 1,000.
The initial skeleton test build was interrupted by concurrent DDS compile errors,
not counted as behavioral-red proof. The expanded attach farm separately caught
missing `ITree.mode` fields and the wrong `.gcdata` blob name before correction.

Native source map (TS paths relative to runtime/datastore/src):

| Swift type | TypeScript source |
| --- | --- |
| FluidDataStoreRuntime, LegacyTypeAwareRegistry | dataStoreRuntime.ts |
| ChannelContext, ChannelFactory/ChannelInstance bridge | channelContext.ts |
| LocalChannelContextBase, LocalChannelContext, RehydratedLocalChannelContext | localChannelContext.ts |
| RemoteChannelContext | remoteChannelContext.ts |
| ChannelDeltaConnection | channelDeltaConnection.ts |
| ChannelStorageService | channelStorageService.ts |
| FluidObjectHandle | fluidHandle.ts |
| ChannelCollection datastore registration, dispatch and metadata bridge | container-runtime/src/channelCollection.ts |
| summarizeDatastore | container-runtime/src/dataStoreContext.ts summarizeInternal/getAttachSummary |
| summaryToITree, summaryFromITree | runtime-utils/src/summaryUtils.ts / snapshot conversion |

The native host must resolve asynchronous storage before entering the synchronous
container executor. Incremental summary handles, telemetry, extension acquisition,
and automatic application entry-point provisioning are not part of this harness.
Channel creation/binding is exposed as throwing native runtime calls; DDS APIs
remain the previously certified native DDS interfaces. Registered datastore
signals propagate synchronously to the container signal submission path; native errors propagate through the throwing submit API.

Final shared-checkout caveat: after the focused 16-test command passed, a new
concurrent `FluidTreeTests/RevisionReplacerTests.swift` caused the whole-repo
`swift test --scratch-path .build/h5` build to fail because
`DefaultRevisionReplacer` was not yet in scope. No tree files were changed by H5.
The H5 target and differential results above remain separate from that moving
whole-checkout build. The final routing regression used the existing routing
driver copied to `/tmp/h5-routing.mts` with only imports/root and `.build/h4` ->
`.build/h5` adjusted; its committed source was not changed.
