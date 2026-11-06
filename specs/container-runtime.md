# container-runtime — 3.11.0 porting index

## 1. Role

The container-level state machine between the loader/driver and datastores. It owns transport virtualization, pending local changes, schema negotiation, IDs, blobs, GC and summaries; datastore contents are dispatched rather than interpreted as DDS operations. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3352-3393` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3721-3771`

## 2. Surface used by other packages

Implement `ContainerRuntime.loadRuntime`/`loadRuntime2`, the runtime base/container runtime interfaces, datastore registry/creation and entry-point APIs, blob creation, signals, ordering/flush, pending-state capture, and summarizer internals. The concrete dispatcher and resubmit hooks define the dependency boundary: stores, blob manager, compressor, schema controller and GC each receive their own operation type. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:1008-1056` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3721-3799` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:5476-5591`

Normative area specs (read all; they share one serial container executor):

- [Operation lifecycle](container-runtime/op-lifecycle.md): raw ops → batching → grouping → LZ4 → chunking and reverse.
- [Pending state](container-runtime/pending-state.md): ack correlation, stashing, reconnect/rebase, staging.
- [ID compressor](container-runtime/id-compressor.md): allocation ordering and session persistence.
- [Summarizer](container-runtime/summarizer.md): election, scheduling, summary transaction and incremental trees.
- [Garbage collection](container-runtime/garbage-collection.md): graph tracking, tombstones, sweep and persistence.
- [Blobs](container-runtime/blobs.md): payload/upload/attach state machine and summary attachments.
- [Routing and signals](container-runtime/routing-signals.md): datastore envelopes, aliases, signals and extensions.
- [Compatibility](container-runtime/compatibility.md): client floor, feature defaults and schema CAS.

## 3. Wire and persisted formats

The area documents include literal JSON vectors, transform boundary predicates, persistence omission rules and serial-executor event order. They specify runtime-owned behavior rather than requiring a new Swift implementation in this research pass. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3352-3397`

Runtime operations use ordered `{type,contents}` envelopes. Types are `component`, `attach`, `chunkedOp`, `blobAttach`, `rejoin`, `alias`, `idAllocation`, `schema`, `GC`; undefined contents are omitted by JSON serialization. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/messageTypes.ts:26-81` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/opLifecycle/opSerialization.ts:77-96`

Root summary state comprises `.channels`, `.metadata`, optional `.idCompressor`, `.chunks`, `.recentBatchInfo`, `.aliases`, `.electedSummarizer`, `.blobs`, and **`gc` (not `.gc`)**. The area specs define contents and omission rules. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:2924-2970` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/summary/summaryFormat.ts:214-222` `reference/fluidframework-3.11.0/packages/runtime/runtime-definitions/src/garbageCollectionDefinitions.ts:11-29`

## 4. Behavior

On receive: verify open, flush local accumulation before the reference sequence changes, then process under the no-data-model-change runner. Deserialize runtime contents only; undo virtualization; check duplicate batch and pending state before dispatch. Intermediate chunks do not enter logical processing. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3352-3397` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3400-3454`

A duplicate batch is fatal only if either occurrence has an explicit batch ID; implicit duplicates are telemetry-only. An empty grouped batch is still processed for batch bookkeeping, but is not dispatched as a runtime/DDS op. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3439-3444` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3485-3510`

## 5. Invariants and asserts

Unknown logical op types close and throw; a chunk reaching the logical dispatcher is assertion `0x93d`. Summary attempts cannot begin with a nonempty outbox. The specific ordering/assert contracts are in the area specs. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:3747-3770` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/containerRuntime.ts:4711-4725`

## 6. JS-semantics hazards

Serialized bytes and property order are observable: pending acks compare stringified envelopes exactly. Transport sequence numbers, synthetic grouped CSNs and DDS-local metadata are different domains. Preserve synchronous listener ordering and async I/O boundaries, not merely final state. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/pendingStateManager.ts:169-175` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/pendingStateManager.ts:713-779` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/opLifecycle/opGroupingManager.ts:181-192`

## 7. Test assets to reuse

Use the package's `src/test/containerRuntime.spec.ts`, `batching.spec.ts`, `pendingStateManager.spec.ts`, `test/opLifecycle/`, `test/summary/`, `test/gc/`, and `test/blobs/`; each area below identifies targeted cases. Source tests are the oracle, not new Swift interpretations. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/test/containerRuntime.spec.ts:1` `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/test/batching.spec.ts:1`

## 8. Open questions

The source leaves GC node-key collation dependent on host locale/ICU; this is the remaining environment-dependent byte-order question. Codec integration, including ID base64 wrapping and LZ4 framing, is specified in the area documents. `reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/gc/gcHelpers.ts:83-95`
