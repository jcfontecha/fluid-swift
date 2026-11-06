# `@fluidframework/container-loader` — native Swift port contract

## 1. Role

This package owns container lifetime, protocol consensus/membership, ordered op and signal delivery, connection eligibility, attachment, and offline serialization. Runtime processing is downstream of protocol processing; storage and delta-stream services are supplied by the driver. This specification targets the checked-out `reference/fluidframework-3.11.0` tree, including its frozen/pending-state extensions, not a different npm installation. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:1618-1779`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2348-2414`.)

The normative chapters are [protocol and audience](container-loader/protocol.md), [delta delivery](container-loader/delta.md), [connections](container-loader/connections.md), [container lifecycle](container-loader/lifecycle.md), and [pending state](container-loader/pending-state.md). Each chapter supplies concrete algorithms and formats, rather than requiring source navigation.

## 2. Surface used by other packages

- Host entry points: `createDetachedContainer`, `loadExistingContainer`, `rehydrateDetachedContainer`, `loadFrozenContainerFromPendingState`, `captureFullContainerState`, summarizer loading/summary helpers, `createFrozenDocumentServiceFactory`, `loadContainerPaused`, `loadContainerToSequenceNumber`, and the retained `Loader`. Public types include `ConnectionState`, `ContainerAlpha`, protocol builder/snapshot types, driver/host/load props, summary result types, and `PendingLocalStateStore`. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/index.ts:6-74`.)
- Runtime boundary: `ContainerContext` supplies storage, base snapshot/version, delta manager, quorum, audience and signalAudience; submission callbacks for container messages, summaries, batches, signals; fetchOps; close/dispose; dirty and pending-op updates; URL/identity/attachment/connection accessors; pending runtime state and optional snapshot contents. Instantiate through `fluidExport.IRuntimeFactory.instantiateRuntime(context, existing)`, with `existing = snapshotTree !== undefined`; validate runtime compatibility before publishing `_runtime`. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2455-2506`.)
- Protocol builder takes `(attributes, quorumSnapshot, sendProposal)` and returns a handler with `quorum`, `audience`, attributes, snapshot/state, connection setter, message/signal processors and close. `sendProposal` returns a client sequence number or negative failure. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol.ts:61-103`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/protocol.ts:25-45`.)

## 3. Wire and persisted formats

The chapters define `.protocol`, sequenced messages, outgoing message property order, audience signal JSON, attached/detached pending JSON, binary attachment encoding, and legacy reads. Runtime payloads are opaque at this layer: preserve them, do not parse/re-encode application ops; only proposal contents are parsed in place. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/protocol.ts:125-139`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:302-345`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/serializedStateManager.ts:73-150`.)

## 4. Behavior

All synchronous callbacks and event emissions run on the container's serial executor. Network completions, queue starts and noop microtasks are ordered asynchronous boundaries, not permission to interleave within an op. The end-to-end successful op order is delta validation → connection-manager accounting → protocol validation/dispatch/MSN approvals → runtime.process → serialized-state accumulation → noop/accept processing → container `op` → delta-manager `op` → inbound-queue `op`. A thrown processing error terminates that path and closes the container through the queue error handler. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:1090-1186`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2348-2392`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaQueue.ts:161-169`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:479-486`.)

## 5. Invariants and asserts

Assertion codes and the associated predicates are tabulated in each chapter. Do not replace corruption failures with skipped messages, clamp MSN, merge duplicate quorum clients, or mark a socket as an eligible runtime connection. Each of those changes changes behavior. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:1096-1175`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:97-117`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionStateHandler.ts:520-529`.)

## 6. JS-semantics hazards

Preserve ordered Maps, JSON property order, missing/undefined/null distinctions, mutable message identity, synchronous listener reentrancy, microtasks, and UTF-16 content lengths. Snapshot caches can remain visible during synchronous quorum events because invalidation occurs after emission; this is observable and must not be silently corrected. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:88-117`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:307-321`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:330-331`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaQueue.ts:118-141`.)

## 7. Test assets to reuse

The chapter test sections identify focused oracle tests and fixture scenarios. Reuse source tests without running a build as part of this research task. The differential checks should compare literal blob strings and ordered events, not only final values. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/test/protocol.spec.ts:38-93`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/test/quorum.spec.ts:24-134`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/test/deltaManager.spec.ts:338-461`.)

## 8. Open questions

None for the six requested wave-2 areas. Driver-specific transport framing, runtime-specific pendingRuntimeState and application summary payloads remain owned by their respective packages; this loader contract explicitly preserves these opaque values rather than inventing a second schema. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2348-2356`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2395-2414`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/serializedStateManager.ts:447-480`.)
