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
- `minimumSequenceNumber` = min over editing clients of that client's latest
  `referenceSequenceNumber` (initialized to the client's join `sequenceNumber`), matching deli.
- Each client has a **cursor** into the log. A *deliver* step advances one client's cursor by k,
  calling `process` for each message. Clients therefore lag independently, so edits carry varied
  `referenceSequenceNumber`s — the concurrency that conflict resolution must handle.
- *Join*: a new client is created from `summarize` of a **non-editing summarizer replica**,
  starting at that replica's cursor. Clients may join on either peer regardless of
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
3. **Cross-load:** each summarizer replica's summary, loaded by a fresh TS client and by a fresh Swift client,
   yields that same `state`. The fresh clients are discarded afterwards.

One summarizer per peer joins before the editors, consumes every sequenced operation,
and is never selected for generated edits or reconnects. Read-only replicas do not
constrain MSN, since they never submit reference updates (upstream
`test-runtime-utils/src/mocks.ts:630,645` records these only on submission). Editor summaries still undergo
exact twin comparison; they are not load sources. This mirrors upstream
`packages/dds/test-dds-utils/src/ddsFuzzHarness.ts:954-959` (non-editing summarizer),
`:733-740` (joins), and `:1502-1514` (summary source). SharedSummaryBlock has no
sequenced edits: its existing local-only fixture writes are mirrored to every replica,
including summarizers, so its local state remains comparable.

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
| matrix | `insertRows/removeRows/insertCols/removeCols{start,count}`, `setCell{row,col,value,valueKind?}`, `switchSetCellPolicy` | `{rowCount,colCount,cells}` dense grid; undefined is `{$fluid:"undefined"}`; handles use Fluid wire encoding | `{rowCount,colCount,fww}` | `rowsChanged/colsChanged start,removed,inserted`; `cellsChanged row,col,rows,cols`; `conflict row,col,current,ignored` |
| shared-string | `insertText{position,text,props?}`; `insertMarker{position,props}` (Tile); `removeRange{start,end}`; `annotateRange{start,end,props}`; `addInterval{collection,id,start,end,props?}`; `changeInterval{collection,id,start?,end?,props?}`; `deleteInterval{collection,id}` | `{text: UTF-16 units, positions: [{properties,marker}], collections: [{label,intervals:[{id,start,end,properties}]}]}`; labels, IDs and property keys sorted by UTF-16; absent property bags mean `{}` | `{length,collections}` | `sequenceDelta`/`maintenance operation,local,ranges`; `createIntervalCollection label`; `addInterval`/`deleteInterval label,interval,local`; `changeInterval label,interval,previous,local,slide`; `propertyChanged label,interval,delta,local` |
| shared-signal | `notify{value}` | `{persistent:false}`; notifications are checked through events, never invented as persistent state | `{}` | `notify value, local` |

TaskManager and ConsensusQueue have no public read API for their global state, so their
canonical state reads the DDS's own summary blobs. Register `keys()` order is twin-only
(see "Oracle preconditions" below); everything else in `queries` is client-relative.

Matrix follows `matrix/src/test/fuzz.ts`: insert/remove rows/columns weighted 10 each,
set weighted 200, and the one-way FWW switch weighted 1 while eligible. Dimension
changes are 1–3; values include numbers, short strings, native handles and undefined
(the clearing case extends the upstream pool). No upstream-defect exclusions apply.
The upstream model has no undo/redo. `npm run matrix:check` additionally checks
turn-based rollback, stashed sets/vector edits and concurrent LWW/FWW writes against
the twin; its load/summarize observer never edits.

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

SharedString interval endpoints accept numbers, `"start"`/`"end"`, or `{pos,side}` (Before=0,
After=1). The default generator covers all three shapes; stickiness is enabled on both peers.
Maintenance events are compared alongside sequence and interval events, including intermediate
split positions. `src/sequence-lifecycle.ts` separately covers turn-based rollback, stash, and
repeated reconnect without changing the shared Session scheduler.

### SharedString oracle precondition (F2, default legacy summaries)

`npx tsx src/sequence-oracle-precondition.ts` reproduces a pinned 3.11.0 legacy
summary defect using only upstream mocks and two concurrent text insertions:
A inserts "A", B inserts "B", both converge to "BA", but B's legacy summary
loads as "A". `sequence.ts:965-990` transforms a non-current-reference local
ack through `sequenceDelta`; local acknowledgements emit no text delta, so the
catchup op becomes an empty group. V1 preserves "BA" in the same test.
The repro also creates a non-editing summarizer and proves its summary reloads as
"BA" under both legacy and V1. Production defaults remain legacy (`sequence.ts:497,532-536`).
Upstream explicitly keeps the attached summarizer free of edits
(`packages/dds/test-dds-utils/src/ddsFuzzHarness.ts:954-959`) and loads joins from it
(`:733-740`, `:1502-1514`). Session follows that precondition; it does not skip
seeds or normalize editor summary bytes. This is not an interval fuzz exclusion. See `src/sequence-README.md` for scope and
execution evidence. The Swift SharedString peer passes 500/500 mixed seeds with sided/sentinel
intervals and maintenance events, 200/200 TS/TS seeds, and the planted/reverted sliding-divergence
check. Legacy remains the default; both legacy and V1 layouts have byte-exact upstream fixtures.

SharedString summaries require recursive tree nodes; the transport now accepts
nested trees while retaining exact blob strings. Its loader uses upstream
`MockStorage` because the flat `MockObjectStorageService.list()` returns full
paths rather than the child-relative names expected by the scoped loader.
A loaded runtime takes its minimum sequence from snapshot metadata, independently
of its current cursor, so joining does not artificially advance merge-tree's
minimum beyond the service minimum. Semantic state treats an absent property bag
as empty; queries, events, outbound operations and summary bytes retain their
separate exact twin checks.


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
read-only.

**Decision: the generator avoids the interaction.** Upstream skips by seed
(`packages/dds/legacy-dds/src/test/array/arrayFuzzTests.spec.ts:29-33`: seed 3, "Concurrent
move/undo-move and delete can resurrect a deleted entry", and seeds 14 and 42, "Concurrent move
and delete/toggle undo can restore an entry at its old position"), which does not carry over to
this generator. Only the SharedArray generator (`arrayEdit` in `src/dds.ts`) changed; the oracle,
every comparison and every other op stay as they were, and `src/oracle-array-precondition-check.ts`
still reproduces the defect. The session passes `generate` a `SessionHistory` (the sequenced log,
the unsequenced queue, and the acting client's cursor and wire ID), so a client can tell which
operations of other clients it has not processed yet, those it would be concurrent with. A chain
of moved entries keeps its value, so the exclusion is by value (two entries that share a value only
make it stricter). For an entry that another client concurrently:

- deletes or toggles, this client does not move or toggleMove it;
- moves or toggleMoves, this client does not delete or toggle it;
- moves, deletes or toggles, this client does not toggleMove it, and
- toggleMoves, this client does not toggleMove or move it.

The last two rules go beyond the documented counterexample. Seed 138 of `--peers ts,ts` with only
the first two fails on cross-replica state: a remote move arriving while the receiver's undo-move
(toggleMove) is pending leaves a dead entry at the end of the chain through `updateDeadEntry`, and
later operations resolve to it. Concurrent moves with moves, deletes with deletes, and everything a
single client does to its own entries stay enabled, as do inserts and insertBulkAfter. Entries
created by an offline edit (made after every client drained) are not in the history, so no other
client has an operation on them. With this generator `--dds shared-array --peers ts,ts --seeds 0..499`
passes.

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
  Operations on an entry that another client is concurrently moving, deleting or toggling are
  excluded where upstream's fuzz suite skips seeds instead (see "SharedArray convergence
  counterexample").

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

## T1 — native SharedTree change family

Both `npm run fuzz:tree-changes -- --self --seeds=1000` and
`npm run fuzz:tree-changes -- --seeds=1000` pass. Native mode builds
`FluidTreePeer` in release with `--scratch-path .build/t1` and uses NDJSON
stdin/stdout. It executes every generated operation in Swift, with no TS
substitute or skipped seeds. Native requests have a 30-second deadline. Failures
save the scenario, first divergent row and complete record arrays in `traces/tree`.

The generator tracks live nodes, nested children, optional occupancy, detached
roots and ordered empty cells. Root ownership is distinct from empty-cell
identity: move sources retain tombstones. Fresh attaches tie-break left of old
empty cells, and overlapping moves follow the editor's split source ordering.
Siblings share a declared parent; the chosen first sibling advances the trunk.
`scenario-check.ts` applies every branch to its parent for 1,000 seeds and checks
the seed-75, insert-order, move-tombstone and overlapping-move regressions.

Two comparison contracts remain distinct and both run in the default native farm:

1. Algebra uses modular 5 exact bytes, TS semantic/byte roundtrips, native byte
   roundtrips, and the original tagged structural projection. Maps, sets,
   undefined, property order, metadata and B-tree/COW internals are retained.
2. Individual edits use their revision as context and exact bytes at all four
   actual writer gates: 2.0/2.43/2.80/2.117 -> modular 3/4/5/5,
   sequence 2/3/3/3, optional 2. `wire-check.ts` independently passes 73,644 edits.

ContainerRuntime propagates oldestSupportedClient as minVersionForCollab;
explicit Tree configuration wins, then the runtime value, then 2.0.0. Message
formats 3/4/6/7 map to modular 3/4/5/5. Older compatible writeVersionOverrides
remain possible; incompatible/unstable versions require the explicit override
permission. Outer Message encoding is not T1 coverage.

The farm additionally checks the enabled upstream rebaser laws: compose identities,
empty rebase, inverse cancellation, do/undo and undo/redo, left distributivity,
associativity including rollback sandwiches, and composed sandwich rebase.
Semantic axiom equality respects delta-defined unordered collections and no-op
representations; raw differential records are not normalized. Upstream-skipped
right distributivity is not claimed.

Native sequence/optional/generic handlers, modular family/editor/codecs,
constraints, aliases, cross-field invalidation/amendment and exact B-tree/range
unions are implemented. Typed provenance preserves JS construction order without
changing semantic atom identity. The current shared FluidTreeTests target passes
82 tests (including T2 suites). Supplementary 1,000-scenario fixture sets cover
all major field algorithms and collection operations. ModularForestCodec uses
the actual native forest codec, with 4,000 TS-matched build/refresher encodings
across writer gates, plus summary/op identifier and cancellation tests.

The full native transport caught a planted reversed rebase tie-break at seed 0,
row 438 with divergent wire bytes. It was reverted byte-for-byte, then both
1,000-seed gates passed cleanly. Evidence is in
`src/tree/fixtures/planted-native-tiebreak.{txt,json}`. No git writes were made.
See `src/tree/README.md` for commands, source mapping and coverage boundaries.

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

## Service mode (M2): native fluid-static SharedMap

`npm run service:m2 -- --seeds 0..9` builds `FluidServicePeer` with
`--scratch-path .build/m2`, starts an isolated tinylicious on **7074**, and disposes
all clients, server processes and temporary storage when finished. No existing
server or document is reused. Run from `harness/` with the installed dependencies.

The creator uses the pinned 3.11.0 `TinyliciousClient` and `SharedMap` from
`fluid-framework/legacy`, with `initialObjects: { map: SharedMap }`. Each seed:

1. Creates and attaches in TS. Swift loads the original sequence-zero attach summary;
   TS then sets a nested value and produces an acknowledged summary.
2. Opens Swift from the document ID, resolves `rootDOId` through `.aliases`, loads
   aqueduct's `root` directory, and follows `initial-objects-key` handles.
3. Interleaves TS and Swift set/delete/clear operations, including nested JSON and
   nested handles to the existing map. TS must consume Swift's real submitted ops.
4. Summarizes again in TS and opens a second Swift client from a snapshot at least
   as recent as the pre-summary checkpoint.
5. Joins another TS writer; disconnects Swift; edits Swift offline while TS changes
   the same key; reconnects and resubmits; disconnects the extra TS writer.

Checkpoints require equal sequence numbers, zero pending runtime/DDS ops, deep-equal
maps on every client, and matching native datastore/channel identities. Overlapping
socket runtime ops are compared to the TS inbound stream as raw JSON. Handle values
are normalized to their serialized absolute paths, not compared by process identity.
The Swift wire is sequenced by tinylicious and consumed by TS, not translated by the
harness. Failures preserve RPC requests/responses and checkpoint states under
`harness/traces/service-m2-<seed>.jsonl`.

`npm run service:m2 -- --seeds 0..0 --plant-divergence` deliberately corrupts a
Swift checkpoint observation and **must exit nonzero** with a deep-equality failure.
Without the flag the corruption is absent. Every normal seed also asserts that the
same comparator rejects a planted extra map entry.

The captured real summary fixture for focused Swift load tests is
`Tests/FluidContainerLoaderTests/Fixtures/m2-summary.json` and `m2-attach.json`. Regenerate deliberately
with `npm run service:m2 -- --seeds 0..0 --capture-fixture`; ordinary runs do not
rewrite it. Tests additionally reject protocol/runtime sequence mismatch and missing
root aliases, and cover optional blob redirects, GC snapshot and elected-summarizer
state. Swift summary generation and detached creation remain outside M2.

Native entry point:

```swift
let container = try await Container.open(endpoint: "http://localhost:7074", document: id)
let entries = try await container.mapEntries("map")
try await container.withMap("map") { map in
    try map.set("hello", .string("Swift"))
}
await container.disconnect()
try await container.withMap("map") { map in
    try map.set("offline", .bool(true))
}
try await container.connect()
```

DDS access inside `withMap` is synchronous on the container actor. Only storage,
socket sends and connection lifecycle suspend. `Container` owns both protocol and
runtime state; runtime batches use DeltaManager's actual client sequence numbers,
including intervening protocol noops/accepts, before pending-state registration.

Existing service/routing/datastore farms accept `--scratch-path=.build/m2` so M2
verification does not use or disturb another lane's build directory. Defaults are
unchanged. M1 retains the equal-sequence checkpoint views before awaiting storage
reads, so later ops cannot race a comparison against an older TS observation.

## Summary generation (M3a)

Run `npm run fuzz:summarize -- --self --seeds=1000`, then
`npm run fuzz:summarize -- --seeds=1000`. The native peer builds exclusively in
`.build/m3`. No service, npm install, upload, election loop or summary-op flow is
needed. `--plant-divergence --seeds=1` corrupts `__gc_root` in a native response
and must fail at seed 0; omit the flag to remove the injection.

The oracle is the installed 3.11.0 **ContainerRuntime**, not an independently
written container-tree formatter. A typed mock loader/storage context hosts real
FluidDataStoreRuntime instances with SharedMap, SharedDirectory and SharedCounter.
Two datastores include cyclic channel handles, root aliases, a real uploaded blob
handle and finalized compressor allocations. One datastore is alternately reachable
or unreferenced. Creation metadata and UUID entropy are inputs: the TS attach
snapshot seeds both non-editing summarizer replicas, so generated wall-clock
creation timestamps are shared rather than normalized out of summary blobs.

Three real TS editor runtimes submit through the DDS public APIs. The driver owns
their sequenced log, delivered
identically to both summarizers. At each checkpoint it compares the complete
summary tree, every blob string and stats as exact JSON text, and GC data and
observable DDS state. Full generation starts from the attach snapshot; incremental
generation starts from the acknowledged full baseline. The TS harness starts a
real SummarizerNodeWithGC tracking pass (checked by instanceof at the private
runtime seam); native generation uses its acked baseline and change trackers.
Storage-owned handle materialization resolves paths against that baseline, never
normalizing blob contents. Both generated summaries are then cross-loaded into
the opposite implementation, with full regenerated trees, stats, GC and DDS state
compared again. The TS self-check exercises the same load/summary/cross-load paths.

Independent GC vectors use the actual upstream graph algorithm and
GCSummaryStateTracker: graph-order mark results, cycles/missing targets, numeric,
case and Unicode node ordering, unreferenced timestamps, no reuse before ack,
whole-GC handle reuse after ack, and forced full generation. Native Swift Testing
also covers transient references resetting ages, UTF-8 stats, nonmutating graph
sorting and changes arriving between generation and acknowledgment.

Native ports: ContainerSummary.swift composes runtime state; SummarizerNode.swift
tracks changes without treating reverted content as unchanged;
GarbageCollector.swift implements mark/reference tracking and GC summary state;
SummaryStats.swift counts authored tree/blob/handle nodes and unreferenced bytes.
SnapshotLoad.swift retains datastore package/root attributes and initializes GC
and summary baselines. The container loader forwards protocol-only messages for
last-message metadata as well as runtime operations.

Scope boundaries remain M3b's election, heuristics, summarize/summaryAck op flow
and uploads. Sweep and tombstone processing are not implemented by M3a.


## Presence (H9) — `@fluidframework/presence` differential

`npm run fuzz:presence -- --self` runs the real `@fluid-internal/presence-runtime` 3.11.0 twice per seed and
requires identical traces (and that the generator reached every required behavior). `npm run fuzz:presence`
builds `FluidPresencePeer` (`--scratch-path .build/h9`, release) and compares 1,000 seeds as raw JSON text;
`--seeds=N` selects fewer. Requests are newline-delimited scenarios, responses one trace line each. Mismatches
keep scenario, expected and actual rows in `traces/presence/<seed>.json`. Peer requests have a 30-second deadline.

**Code under test.** The oracle (`src/presence/oracle.ts`) drives the real `createPresenceManager`, the real
`latest`/`latestMap`/`Notifications` factories, and the real `MockAudience`/`MockQuorumClients` from
`@fluidframework/test-runtime-utils`. The Swift mirror is `Sources/FluidPresencePeer/Simulation.swift` over
`FluidPresence`. Both read the scenario after a JSON round trip, so they see identical data.

**Scenario** `{seed, slots (2-4), network[64]: {delay, drop}, randoms[16], commands[]}`. Time starts at 1,000,000 ms
and moves only through `advance` commands: the oracle replaces `Date.now`, `setTimeout`/`clearTimeout` and
`Math.random` (`src/presence/clock.ts`); Swift uses `ManualPresenceClock`. Both fire due timers earliest-first, ties
by creation order, with `now` set to each timer's due time. Every non-`advance` command is followed by
`advance(0)`. A timer callback that throws is recorded as `{t, error:"timer"}`. `randoms` is the `Math.random`
sequence (cycled); the only consumer is the backup join-responder offset for a client not in the quorum.

**Signal bus.** A submitted signal is recorded (`{t, slot, signal}`, after a JSON round trip, so NaN is `null`),
then delivered to every connected slot (the sender included, `local = true`) or only to `targetClientId`. The
delivery to destination `d` for event number `k` uses `network[(3k + 11d) % 64]`: `delay` ms later, or dropped.
Audience add/remove for other slots uses the same table (delay only). A delivery whose destination has
disconnected, or reconnected under another ID, is discarded. The driver adds `clientId`; `local` is `sender ==
destination`. Connecting follows `MockEphemeralRuntime.connect` (members cleared, then re-added, then self) with
the service's current membership; quorum views are immediate and write members get `sequenceNumber = 10 * n`.

**Commands**: `create`, `connect {write, interactive}`, `disconnect`, `workspace {space, address, schema[], latency?}`
(repeated calls ensure content, including type conflicts), `arm` (register a workspace from inside the
`workspaceActivated` listener), `set`, `mapSet`, `mapDelete`, `mapClear`, `notify {name, args, target?}`,
`controls {latency?, refresh?}`, `inject {from, local, addressChain, message}` (Ack, unknown types with and without
the `?` optional marker, `acknowledgementId` updates), `advance {ms}`. Schemas use `latest` (optionally validated),
`latestMap` (optionally validated, optionally rejecting keys that start with `bad`) and `Notifications`. A logging
validator emits `{t, validate}` each time it runs.

**Trace rows**: signals; listener events (`attendeeConnected`/`attendeeDisconnected`, `workspaceActivated`,
`localUpdated`, `remoteUpdated`, `localItemUpdated`, `localItemRemoved`, `remoteItemUpdated`, `remoteItemRemoved`,
named `notification`, `unattended`) with attendee, revision and timestamp; command and delivery failures as
`{error: <command>}` / `{error:"processSignal"}` (the decision to throw is compared, not the message); and after
every command a state snapshot of every created slot: attendees (ID, status, connection ID or `"error"`),
and per registered manager the local state, `getRemotes()`, `getStateAttendees()` and `getRemote(a)` for every
attendee (self included), with timestamps. Keys are compared in JS insertion order.

**Upstream behavior the farm pins** (all from specs/presence.md): `Pres:Ack` (a local echo makes the average latency
NaN, so later `avgLatency` is `null`; a remote Ack throws); "unicast" notifications are broadcast; registered
states keep the sender's timestamps while unregistered ones are shifted by the time modifier; `size` undercounts
after a tombstone is set again; `clear` throws; late partial map updates keep newer keys; the validated-value
cache (`validatedValue`) is stored on the state object, so reading a getter over the *local* state caches there,
partial updates serialize it, and a receiver that finds `validatedValue` present returns it without running its own
validator (this is not in the spec; seed 2 found it); full sends strip it; join-response election, `joinResponseFor`,
stale-connection resolution after 30 s, and workspace activation order.

**Native source map** (all under `Sources/FluidPresence`): `PresenceManager.swift` ↔ presenceManager.ts;
`PresenceDatastoreManager.swift` ↔ presenceDatastoreManager.ts; `SystemWorkspace.swift` ↔ systemWorkspace.ts;
`PresenceStates.swift` ↔ workspace/presenceStates.ts (merge rules); `LatestValueManager.swift`,
`LatestMapValueManager.swift`, `NotificationsManager.swift`, `ValidatedGetter.swift` ↔ states/*;
`TimerManager.swift`, `BroadcastControls.swift` ↔ utils/*; `Protocol.swift` ↔ runtime/protocol.ts;
`ContainerPresence.swift` ↔ runtime/extension/containerPresence.ts; `Definitions.swift`, `InternalTypes.swift`,
`EphemeralRuntime.swift` ↔ presence-definitions and runtimeTypes.ts. `Testing/` ports `MockEphemeralRuntime`
and the mock audience/quorum. One target covers the three TS packages (they are one feature with one wire format).

**Not covered.** Telemetry events are not ported. `getPresenceFromDataStoreContext` is not ported. The
container-level `getPresence` and the real-service scenario are in "Service mode (presence)" below.
The planted-divergence record is
`src/presence/fixtures/planted-divergence.txt`.

Swift Testing ports of the upstream unit tests (`swift test --scratch-path .build/h9 --filter FluidPresenceTests`):
TimerManager, join response election (preferred, backup, fully and partially answered), `workspaceActivated`
cases, acknowledgement, unrecognized messages, attendee lifecycle (connect, disconnect, rejoin, stale after 30 s),
latest, latestMap, notifications, batching, and the upstream behaviors above.

## ODSP compact snapshot codec (H10)

`npm run fuzz:odsp-snapshot` builds `FluidOdspSnapshotPeer` in release mode with `--scratch-path .build/h10` and checks
seeds 0–999. `--self` runs the harness against the TS oracle instead of the Swift peer (the TS self-check: it exercises
the generators, the outcome classification and the comparison path); `--seeds=10` selects the first ten seeds. No
package installation or service is needed. Failures save `harness/traces/odsp-snapshot/<seed>.json` with the step, both
outcome texts and the input.

The oracle imports the installed 3.11.0 `lib` files of `@fluidframework/odsp-driver` directly:
`parseCompactSnapshotResponse`, `convertToCompactSnapshot`, `ReadBuffer`, `TreeBuilderSerializer` and
`TreeBuilder`. Swift is `Sources/FluidOdspDriver` (one file per TS file: `ReadBufferUtils`, `WriteBufferUtils`,
`ZipItDataRepresentationUtils`, `CompactSnapshotParser`, `CompactSnapshotWriter`).

**Peer protocol.** Newline-delimited `{method, params}`; one outcome per line, `{"ok": value}` or `{"err": class}`.
Bytes travel as lowercase hex. Methods: `writeSnapshot(spec)` → hex; `parseSnapshot(hex)` → the canonical parse result;
`writeTree(elements)` → hex (the raw `TreeBuilderSerializer`); `parseTree(hex)` → the loaded top-level elements. The
canonical parse result has a fixed key order (`snapshotTree` {`id`, `blobs`, `trees`, `unreferenced`, `groupId`},
`blobContents` as `[id, hex]` pairs in Map order, `ops`, `sequenceNumber`, `latestSequenceNumber`,
`snapshotFormatV`, `telemetry` = the three slow-path counters; durations are not compared). Replies compare as exact
text, so the `Object.keys` order of `trees` and `blobs` (integer-like keys first) is part of the check.

**Error classes** (compared, not just "it threw"): `assert` with its 0x code, `invalidCode`, `bufferParsing` (message,
`nodeType`, `expectedNodeType`), `undefinedAccess` (a JS `TypeError` from reading a missing element or property),
`invalidJSON` (`SyntaxError` from a delta string), and `sequenceNumberOutOfRange`. The last is the one deliberate
difference: Swift protocol counters are exact integers below 2^53 (ARCHITECTURE §3), so a parsed `sequenceNumber` or
`lsn` above that is rejected where TS returns a rounded double; the oracle outcome is mapped to the same class.

**Per seed** (deterministic Mulberry32):
1. A random `ISnapshot`: nested trees (wide ones with more than 255 distinct names, so dictionary IDs reach 256+ and
   big declarations), `unreferenced` true/false, `groupId` including `""`, integer-like and `__proto__` names, lone
   surrogates, blobs of 0/1/255/256/257/65536/70000 bytes as `ArrayBuffer`, and `IBlob` strings (UTF-8 with astral
   characters, default encoding, base64 with whitespace/URL-safe/unpadded/garbage variants), 0–6 ops (including an op
   without `sequenceNumber`, a non-object and `null`), explicit/undefined/zero `latestSequenceNumber`, missing
   `sequenceNumber`. Checks: (a) the TS writer's bytes equal the Swift writer's exactly (or both fail identically);
   (b) TS's bytes parsed by Swift equal TS's parse; (c) Swift's bytes parsed by TS equal that same parse; four byte
   mutations of the bytes (truncate, flip, insert, delete, plant markers, plant NUL) parse identically in both
   `parseSnapshot` and `parseTree`.
2. A random raw ZipIt tree written by both `TreeBuilderSerializer`s (integer boundaries 0/255/256/65535/65536/2^24/2^32/
   2^53/2^63/2^64-2048/2^64, invalid numbers, 250–290 dictionary strings, strings of 255–70000 bytes), loaded back by
   both, and mutated.
3. A hand-shaped `application/ms-fluid` snapshot built with the raw writer so the reader sees every path: fast-path
   entries, service-style `nodeType` entries, `unreferenced` with `true`/`false`/non-bool, general-path entries with
   shuffled pairs, unknown fields and duplicates, `groupId` on empty/non-empty children, `value` beside `children`,
   odd pair counts, non-string keys, `__proto__` keys, blob entries in both orders, version strings (`1.00`, `abc`,
   ` 1`, `2.0`, …), missing `lsn`/sections, empty/mismatched/malformed deltas, extra or missing roots; then mutated.
4. Grammar bytes: every valid marker written directly, including the ones the TS writer never emits: Int8/16/32/64
   markers with the high bit set, 16/32-bit string lengths, 2/4-byte dictionary references, big declarations with
   IDs 0/256/70000/2^32-1, 64-bit blob lengths, mismatched list/set end markers, invalid UTF-8, a BOM, embedded NUL.

**Reproduced oracle behavior** (all from specs/odsp-driver/compact-snapshot.md): "signed" markers decode unsigned;
declarations are not elements; an embedded NUL in any string fails with 0x3ea after structural errors; a missing child
or property is a `TypeError` (`undefinedAccess`); `unreferenced` marks the enclosing tree; `groupId` is dropped on an
empty child; `cv` must be exactly `"1.0"` (`parseFloat` gates for the rest); `Object.entries` order; the writer's
8-byte blob-length marker bug. Two further consequences of TS building records as plain objects were derived from the
source, are ported, and are covered by the farm: a `__proto__` key in an entry is not stored but replaces the record's prototype (so an inherited
`children`/`data` array can appear), and a tree or blob *named* `__proto__` silently disappears from the parsed
snapshot. See `src/odsp-snapshot/planted-divergence.txt` for the planted-divergence record.

**Not covered.** The `logger` argument and its `StringParsingError` event (it is emitted immediately before the 0x3ea
assertion) are not ported; `telemetryProps` durations are measured but not compared; blob lengths of 4 GiB or more;
sequence numbers above 2^53 (see above); `IBlob` encodings other than `utf-8`/`base64`.

Swift Testing ports (`swift test --scratch-path .build/h10 --filter FluidOdspDriverTests`): the unit tests of
`zipItDataRepresentationTests.spec.ts` and `snapshotFormatTests.spec.ts`, the spec's 133-byte worked hex example in
both directions, and the byte-grammar, hazard and error-code tests.

## ODSP network differential harness (ODSP 2)

`npm run fuzz:odsp-net -- --self` exercises the installed 3.11.0 driver against itself;
without `--self` it builds `FluidOdspNetPeer` using `--scratch-path .build/odsp2` and compares
1,000 scripted seeds over a loopback HTTP server. `--seeds=N` selects a smaller run.
The same run also checks named live Socket.IO, discovery, snapshot-manager, persisted-cache,
limiter, redirect and redemption scenarios (these are deterministic fixtures, not 1,000 socket seeds).

The current comparisons run the actual TS `OdspDeltaStorageService`, `EpochTracker`,
`downloadSnapshot`, `fetchJoinSession` and `OdspSummaryUploadManager`. They cover REST delta
storage (wrapped ops, holes, 401 claims refresh, 403, 404, missing/same-epoch 409, true epoch
mismatch with cache clearing, 429/retry-after and 500), successful join-session, successful
JSON/compact snapshot downloads, and successful summary upload (text, binary, handle and attachment).
A separate comparison runs the actual TS `runWithRetry` with Node virtual timers/Date and a fixed
random source against native clock injection: five attempts at 0/1000/2000/3000/4000 ms and a
terminal nonretryable error. It does not yet cover random backoff; redemption timing is compared separately below.

Each request compares method, raw URL (including query order/escaping), protocol headers,
and UTF-8 body including CRLF boundaries. Multipart boundary UUIDs become `BOUNDARY` and
only the driverId UUID within X-RequestStats becomes `NORMALIZED`. RequestNumber and the
rest of correlation text remain compared. Transport-generated Host, Connection,
Content-Length, User-Agent, Accept-Language, Accept-Encoding and Sec-Fetch-Mode are omitted.
Accept is compared for snapshot requests; the implicit transport default is omitted otherwise.
Authenticated native requests explicitly send the no-cache headers observed from Node fetch;
these are compared, not filtered. Caller results compare deep JSON, including error category,
retryability, optional status, claims, tenant, server epoch, cache-clear count, and
`getRetryDelayFromError` converted to milliseconds. Snapshot blob bytes compare as hex.
Telemetry-only error fields and messages are not yet compared.

The resumed lane additionally certifies these bounded behaviors against the installed TS classes:

- `OdspDocumentDeltaConnection` over real websocket-only Socket.IO: exact ordered handshake and
  outbound frames, nonce mismatch rejection, early ops/signals, initial op sorting, multiplex filtering,
  two simultaneous documents on one physical socket (including parallel initialization), zero-reference reuse before deletion and new
  transport after the 2-second deletion timer. Ops, targeted/batched signals, nacks, get-ops with a
  non-200 response containing messages, flush success, overlapping-flush cancellation, targeted server
  disconnect during flush and disconnect-document ordering are compared. Handshake 400/404 retryability,
  406 failure and mode mismatch are compared. For parallel initialization only, frames compare as a multiset because independent Swift tasks can
  start in either order; all other socket scenarios compare ordered traces. Native transport uses committed `FluidSocketIO` through
  the factory-owned `OdspSocketIOFactory`; protocol state remains `OdspDocumentDeltaConnection`.
- Actual `OdspDelayLoadedDeltaStream` discovery cache/default 3,600-second lifetime, cache hits and
  exact expiry at the 30-second refresh buffer. A live connection refreshes discovery, receives a 403
  server disconnect, clears its timer/cache and rediscovers. Node virtual Date drives discovery;
  native clock injection drives the same boundary. Native tests also exercise the real refresh timer,
  cancellation, stale-client guard and preservation on non-authorization disconnect.
- Actual storage-manager defaults (`mds=500000000`, timeout 120000 ms), host timeout forwarding,
  summarizer removal of limits, 413 blobless retry with limits removed, and host-mds suppression of that
  retry. Timer registrations are observed on TS; native request timeout values are observed before I/O.
  Seven cache/network races compare cache/network wins, cache miss/failure, network failure, and both
  failure completion orders. Background network cache writes finish even when cache wins.
- Actual `prefetchLatestSnapshot`: untracked request framing, immediate deferred publication, consumers
  obtaining the snapshot before persisted put completes, 4,999/5,000-ms eviction, and a rejected put
  returning false/removing the entry without retracting an already-resolved consumer snapshot.
  TS additionally emits a duplicate unhandled rejection from its unawaited put wrapper: the harness
  observes and asserts that specific rejection without terminating Node; process-level rejection
  delivery is not compared to Swift error delivery.
- Actual epoch-cache version-3 envelopes: missing/wrong-version/other-epoch entries, ops strings,
  snapshot missing-time and exact 5-day expiry, epoch learning before expiry, cache clearing and puts
  with preserved/defaulted timestamps. The 48-request loopback test observes exactly 24 concurrent
  requests in both clients. This concurrency probe compares peak/count, not nondeterministic arrival
  order or individual request traces. Native URLSession's connection cap is above 24 so the driver
  limiter, not Foundation's default six-connection cap, controls this test.
- A 404 relocation facet becomes `locationRedirection`, patches only the site origin and clears cache.
  Actual `EpochTrackerWithRedemption` comparisons cover trees-latest success, trees-latest failure and
  the 14,999/15,000-ms synchronization boundary, including replayed requests/correlation numbers. The parallel redemption request traces are sorted by
  their compared RequestNumber, not physical HTTP arrival order.


`harness/src/odsp-net/planted-divergence.txt` records the failed run with native numeric
retry-after interpreted as milliseconds instead of seconds. The source was restored afterward.
`npm run fuzz:odsp-snapshot -- --scratch-path=.build/odsp2` runs the independent H10 codec farm.

**This lane is not fully certified. Remaining implementation/integration work:**

- Full create-new/share-link/nav resolution and the Office/OneNote/ODC adapter packages.
- Full persisted-cache host-adapter integration for native binary snapshot values, cache I/O failure metadata, already-completed/cache-hit redemption branches, invalid relocation URLs and HTTP redirect responses.
- Snapshot grouped/summarizer/concurrent-policy combinations, deadline-triggered HTTP aborts and timeout-driven blobless retry (413 retry and timeout configuration are compared), overlapping/factory-shared prefetch integration and malformed-cache transformation branches.
- Ops cache backing-store adapters and automatic flush timer; streaming/concurrent range fetching and cancellation.
- Socket transport/error/namespace and actual 62-second handshake-timeout branches, disconnect during initialization, get-ops eviction/stale-response combinations, unsupported flush and host-header propagation; full document-service/factory integration of the live adapter.
- Join-session separate websocket-token acquisition/retry, connection-failure cache-preservation combinations, sensitivity-label metadata and storage-only facet transitions.
- Full error telemetry/message mapping, all host-token failure metadata, HTTP redirect behavior and all special-facet/error branches.
- Summary relay-flush retry and empty-file pending rename integration.

`python3 harness/src/odsp-net/test-swift.py` compiles and runs the real ODSP test files through
an ephemeral five-target manifest, reusing the same `Sources`/`Tests` and `.build/odsp2` scratch path.
This avoids compiling sibling lanes' in-progress test targets; it does not substitute copies or mocks
for native ODSP source. The ordinary full-package filtered command can still fail on unrelated
concurrent edits (observed: ContainerRuntime `SummaryManagerTests` referencing a missing `Throttler`).

The green REST/codec farms must not be presented as whole-driver certification.

## Service mode (M3b): Swift as the summarizing client

`npm run service:m3 -- --seeds 0..N` runs tinylicious 7.0.1 with mixed Swift and 3.11.0 TS clients.
Swift ports `SummarizerClientElection` (3.11.0 has no `OrderedClientElection`; ordering lives there),
`SummaryManager`, `RunningSummarizer`, `SummarizeHeuristicData` with its exact constants,
`SummaryGenerator`, `Throttler`, and the routerlicious `SummaryTreeUploadManager` and
`WholeSummaryUploadManager`. Seeded scenarios, on deterministic clocks:

- a Swift summarizer is elected, schedules by the heuristics, and uploads; TS acks it;
- a fresh TS client loads from Swift's summary and matches state;
- election handover between Swift and TS summarizers when the summarizer leaves;
- a summaryNack path;
- incremental summaries against the acked baseline;
- a graceful-stop summary.

Each upload is compared byte-exact with what TS uploads for the same state (the M3a comparison).
Shredded uploads run live against tinylicious. Tinylicious 7 answers whole-summary uploads with 404,
so that path is compared against TS through a recording HTTP endpoint instead.

## Service mode (presence): Swift and TS exchange presence over tinylicious

`npm run service:presence -- --seeds 0..4` builds `FluidServicePeer` with `--scratch-path .build/presence`,
starts an isolated tinylicious on **7076**, and disposes all clients, server processes and temporary storage when
finished. Run from `harness/`. `--plant-divergence` corrupts a Swift observation and **must exit nonzero**.

**Code under test.** The TS side is the real 3.11.0 presence reached the way an application reaches it:
`getPresenceAlpha(fluidContainer)` from `@fluidframework/fluid-static/alpha`, which acquires the presence container
extension (`fluid-static/src/getPresence.ts`). `@fluidframework/presence` is not installed and is not needed: its
`getPresence` is a re-export of that function, and `StateFactory`/`Notifications` come from
`@fluid-internal/presence-runtime/states` (the package the H9 oracle already imports). The Swift side is
`Container.withPresence`, the native `getPresence`, over `FluidPresence`:

```swift
let container = try await Container.open(endpoint: "http://localhost:7076", document: id)
try await container.withPresence { presence, clock in
    let states = try presence.states.getWorkspace("app:cursors", WorkspaceSchema([
        ("cursor", LatestFactory(local: cursor, clock: clock))]))
    try states.latest("cursor").setLocal(next)
}
```

`body` runs synchronously on the container's executor, then the signals presence queued are sent. `clock` is the
container's timer-backed `PresenceClock`, which the state factories read for `Date.now`.

**Native wiring** (all in `FluidContainerLoader`, additive):

- `Container.processSignal` follows container.ts: a signal with no `clientId` and type `clear`/`join`/`leave` is an
  audience signal (the signal audience takes every client, read and write, like `wrapProtocolHandlerBuilder`; the protocol
  audience still takes reads only); every other signal goes to `ContainerRuntime.processSignal(message, local)`, with
  `local = clientId == own clientId`. A new connection resets the signal audience from `initialClients` (the synthesized
  `clear` then `join` signals of connectionManager.ts) before `initialSignals`.
- `runtime.onRuntimeDispatch("extension", ...)` reaches `ContainerPresenceManager.processSignal`. `ContainerRuntime.extensions`
  holds the acquired extension ids, as the TS `extensions` map gates routing; an unacquired extension's signal is dropped
  (and a local one asserts 0xba0).
- `runtime.onSubmitSignal` queues; `Container.flushSignals` sends in order on the I/O edge, after the synchronous caller returns.
- `ContainerExtensionHost` is the `ExtensionHost` of `acquireExtensionInternal`: the signal audience (adapted to presence's
  `IAudience` by `PresenceAudienceAdapter`), the runtime quorum, `getClientId` from the connection, and
  `getJoinedStatus` (no connection = `disconnected`; a connection that has not yet seen its own join = `joinedForReading`,
  TS `CatchingUp`; after it = `joinedForWriting`). `supportedFeatures` is empty, exactly as in 3.11.0
  (`runtimeCompatDetailsForLoader`), so presence sends no targeted signals even though the driver negotiates `submit_signals_v2`.
- `ContainerPresenceClock` backs `setTimeout` with `Task.sleep` and runs the callback by hopping back onto the owning
  `Container`, never on a detached task. A callback that throws, or a presence listener that throws, is held as the
  container's presence failure and surfaces on the next `withPresence`, as a thrown TS listener would surface at the raiser.
- Disconnect (explicit, or a failed socket) raises presence's `disconnected` event.

**Scenario.** Both sides register the same workspaces: states `app:cursors` with `latest` `cursor` (`{x, y}`) and
`latestMap` `items`; notifications `app:events` with `ping(label, count, tag)`. Per seed: TS creator `ts0` and Swift
`swift0` join; seeded edits (set, map set, map delete, notify) on random connected clients; late joiners `ts1` and `swift1`
learn the existing state from join responses, in random order; more edits; `ts1` and `swift0` leave (audience removal, state is kept);
both edit offline, which stays local; both reconnect, which publishes the offline state through a new `ClientJoin`; final edits.
Each checkpoint polls (30 s) until **every connected client's** view equals a model that the harness maintains from the
commands it issued. A view is `{attendees: [label, status], cursor: {local, remotes: [label, value, revision]}, items:
{local, remotes}, notifications: {sender: [name, args]}}`, with session IDs replaced by labels. So TS observes Swift's
attendees, states and notifications exactly as Swift observes TS's, and both equal the model. Timestamps are not compared: a
workspace that registers after the data arrives shifts them (specs/presence.md, "State merge").

At the end, every presence signal that Swift received is byte-identical to the one `ts0` received (`deltaManager.inboundSignal`),
and every signal sent by a Swift connection has the address `/ext/dis:bb89f4c0-80fd-4f0c-8469-4f2848ee7f4a/` and a
`Pres:ClientJoin` or `Pres:DatastoreUpdate` message. The comparator is also checked against a planted wrong cursor value
and a planted extra attendee. Failures keep every view and expected view under `harness/traces/service-presence-<seed>.jsonl`.

**Settling.** The harness sleeps 1.5 s after each membership change before it sends notifications. In upstream presence a
notification sent while a join response is queued is absorbed by it (`queuedData` `sendAll` dominates later partials) and never
leaves, because notifications are not stored state. This is TS behavior, pinned by the H9 farm, and both sides do it.

## T2: SharedTree forest storage formats

`npm run fuzz:tree-forest -- --self --seeds=1000` runs the real pinned 3.11.0
codecs against generated stored schemas and trees; `npm run fuzz:tree-forest --
--seeds=1000` builds `FluidTreeForestPeer` using `.build/t2` and compares Swift.
No npm installation is needed. Strict lane-local checking is
`npx tsc --noEmit -p src/tree-forest/tsconfig.json`.

Each seed varies stored type names, object field multiplicities, allowed leaf types,
map multiplicity, and nested object/map/array/leaf contents. Cases include identifiers
finalized through the ID compressor, UTF-16 lone surrogates, numeric and prototype-like
map keys, absent optional fields, and zero-token constant null runs. The record stream
contains byte-exact JSON strings for field-batch 1, 2, and experimental `text`, each
uncompressed and schema-compressed; forest payload 1/2 independently crossed with all
field-batch versions; and schema-index 1/2. Separate cases drive actual TS UniformChunk
cursors, plus v2/text incremental encoders with recursively encoded chunk references.
Both peers read the other's field batches, including the incremental reference map.
The Swift peer communicates through newline-delimited FluidJS JSON, never Foundation JSON.

Oracle quirk: 3.11.0 `getChecked` rejects a literal null stream token. Thus uncompressed
null-leaf data encodes but fails to decode in TS. Both peers report the narrow
`decode-error:null-token` result; schema-compressed null constants round-trip normally.
Other errors fail the run. This is compatibility coverage, not skipped null coverage.

Failures preserve the seed, schema, trees, expected records, and actual records under
`harness/traces/tree-forest/`. A 30-second response deadline fails a stalled peer.
T2 does not modify T1's `harness/src/tree/` or its change-family types.

Additional T2 cases cross-read both forest envelopes and both schema envelopes, exercise
chained `f`-shape field replacement/appending and explicit-clear overlays, and cover
ordinary string/v5 identifiers plus unfinalized v4 identifiers. Op encoding uses the
originator session for negative IDs; summaries preserve unfinalized UUID strings.
A planted empty-array shape index of `999999` was rejected by the byte comparison and
restored to the dictionary index before the final passing run.

## ODSP 3 — document service

`npm run fuzz:odsp-service` builds `FluidOdspNetPeer` (`--scratch-path .build/odsp-service`) and drives the installed 3.11.0 TS
`OdspDocumentServiceFactory` and the Swift `OdspDocumentServiceFactory` through the same scripted fake ODSP endpoint on
127.0.0.1:7091 (REST plus websocket-only Socket.IO). It runs 300 seeds by default; `--seeds=N` and `--from=N` choose
the range, `--self` runs TS twice as a determinism check, `--all` keeps going and saves every failing trace, and
`--coverage` prints what the seeds exercised. Sources are `harness/src/odsp-net/service/` (`scenario.ts` generator,
`fake.ts` endpoint, `oracle.ts` TS script, `fuzz.ts` driver) and `Sources/FluidOdspNetPeer/ServiceScenario.swift`.
Failures save `harness/traces/odsp-net-service/<seed>.json` with the scenario, both outcomes and both wire traces.

**Per seed** (Mulberry32), one of three kinds:
- Load (two thirds of seeds): `createOdspUrl` → `OdspDriverUrlResolver.resolve` → `createDocumentService`.
- Create from summary: `createOdspCreateContainerRequest` → resolve → `createContainer`, with `.app`/`.protocol` at
  sequence 0, a binary blob and a grouped tree.
- Create an empty file: the same with no summary.

Then, through the contract objects only:
- Storage: either `getSnapshot()` or the default loader path `getVersions(null, 1)` → `getSnapshotTree(version)`.
  Then `readBlob` of snapshot blobs (blob cache) and of a blob missing from the snapshot (attachments GET), and
  optionally `getSnapshotTree()` and `getVersions` with count 1 (cache) or 2 (versions GET).
- `connectToDeltaStorage().fetchMessages(from, to?)` over the snapshot's ops plus the REST delta feed: wrapped or
  plain ops, open or fixed ranges, and the empty fixed range TS fails with 0x270.
- `connectToDeltaStream` before or after the fetch, with a host websocket fetcher or the join-session token; submits
  the fake sequences and echoes; one signal.
- `uploadSummaryWithContext`: a container summary with a handle after a socket flush, a channel summary, or the
  empty file's first summary followed by the PATCH rename.
- `createBlob`; then connection dispose and service dispose.

The fake serves JSON or compact (`application/ms-fluid`) snapshots. It can fail one request class (trees/latest,
join session, ops, blob, createBlob, upload, versions, createFile, push handshake) with 401 (claims challenge),
403, 404, 409 (coherency, retried with backoff), 429 (`retry-after: 0`) or 500, or answer it with a mismatched epoch
(`x-fluid-epoch: F`, or a handshake epoch). It answers `get_ops` without ops: a response with ops races the
script's dispose when the REST fetch fails at once, in TS as in Swift; ODSP 2 covers that routing.

**Compared** exactly (`deepStrictEqual` after a JSON round trip), per seed:
- The outcome: resolved URLs as JSON (load, create-new request, created file, after rename), the absolute URL and
  policies. Every host token-fetch call, with refresh, claims, tenant, URL parts, request URL and method.
- Every step result: snapshot trees, blob bytes as hex, versions, delta batches, connection details with merged
  initial messages and signals, upload handles, created blob IDs. Errors compare as errorType/canRetry/statusCode
  or the assert message.
- The connection events, in order.
- Every HTTP request (method, raw URL, protocol headers, body with CRLF boundaries) and every socket frame the
  server observes, in order.

Multipart boundaries and the driverId are normalized as in ODSP 2. So are UUIDs in socket frames (connection nonces,
get_ops/flush nonce prefixes) and create-new blob IDs (renamed by first-seen index). Transport headers are excluded as
in ODSP 2. A 500-seed run passed: 303 seeds end with every step done, the rest with one of 10 error classes; 57
fault classes (target × status) occur; 248 connections; 190 summary uploads; 170 loads on the versions path.

**Swift structure** (one TS class per type, in `Sources/FluidOdspDriver`):
- `OdspDocumentServiceFactoryCore` (`OdspDocumentServiceFactory` is a typealias: the TS subclass adds nothing).
- `OdspDocumentService`, plus `RetryErrorsStorageAdapter` (what `connectToStorage` returns).
- `OdspDocumentStorageService`; the abstract base members are an extension in
  `OdspDocumentStorageServiceBase.swift`, with `BlobCache`.
- `OdspDeltaStorageWithCache`, over `requestOps`/`ParallelRequests` (driver-utils, internal for now).
- `OdspDocumentDeltaConnection`, the IDocumentDeltaConnection the loader holds. The ODSP 2 protocol-state class it
  wraps is renamed `OdspDocumentDeltaConnectionState`; the code is unchanged and still confined to the factory's
  socket actor.
- `createFile`/`createNewUtils` in `CreateFile.swift`/`CreateNewUtils.swift`.

`EpochTracker` and `OdspNetwork` are now shared Sendable objects, with mutex-protected state and an `OdspFileEntry`.
Storage, delta storage, join session, summary upload and create-new share one tracker and file entry, as
`createOdspCacheAndTracker` makes them do in TS. `IOdspResolvedUrl` is the typed view of the contract
`IResolvedUrl`. Its JSON is the source of truth, so TS property order survives resolve, create-new and rename.

`fetchHelper` now sends `Pragma`/`Cache-Control: no-cache` only for conditional requests (`If-Match` etc.), which is
what Node's fetch does. The old "any Authorization header" rule only matched because the one authorized request in
ODSP 2 also carried `If-Match`. ODSP 2 stays green.

**Deliberate differences:**
1. TS shares sockets across factories (a module-global cache) unless `isolateSocketCache`; the Swift registry is per
   factory. The oracle runs with `isolateSocketCache: true`.
2. TS starts the websocket token fetch and the join session concurrently; Swift awaits the token first. The calls and
   their order are the same, but a failing token fetcher would skip the join request.
3. `SnapshotBlobContents.buffers` is a JSObject, which puts integer-like blob IDs first where the TS Map keeps
   insertion order. Lookups are unaffected; the fake uses non-numeric IDs.

`harness/src/odsp-net/service/planted-divergence.txt` records the planted divergence: the join-session request
asked for a socket token despite a host websocket fetcher, and seed 3 failed on its HTTP body.

**Not covered or not ported:**
- The ops cache (opsCaching.ts) is not wired: `getCached` always misses and `opsReceived` drops ops. TS writes ops to
  the persisted cache only after a full 100-op batch or a 5-second flush timer, so no scenario here can observe the
  gap. A reload in the same factory that is served from cache would differ.
- Share links and redeem fallback; sensitivity labels; sessionForbidden storage-only facets; point-in-time loads;
  `getRelayServiceSessionInfo`; the factory-level prefetch-result cache. Also loading groups,
  `snapshotFormatFetchType`, host request headers and telemetry.
- Persisted-cache JSON entries through `EpochTracker.get`/`put`. Snapshots use the factory's native cache instead,
  and an epoch-tracker cache hit does not complete the redemption deferral.
- `createNewContainerOnExistingFile` is ported but not exercised; OdspClient never creates into an existing item.
- The handshake timeout, socket transport errors and nacks are left to ODSP 2.
