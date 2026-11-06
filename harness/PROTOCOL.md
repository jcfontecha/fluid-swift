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
