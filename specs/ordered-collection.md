# ordered-collection — consensus queue (3.11.0)

## Role

Sequenced FIFO work queue with exclusive acquisition and quorum-loss requeueing. Unlike an optimistic array, attached add/acquire/complete/release mutate only on sequencing. `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:114-164`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusQueue.ts:19-52`.

## Surface used by other packages

`ConsensusQueue` kind/factory, `ConsensusOrderedCollection<T>` base, `IConsensusOrderedCollection<T>`: add(value), acquire(callback):Promise<boolean>, waitAndAcquire(callback). Callback returns `ConsensusResult.Release = 0` or `Complete = 1`. Events add(value,newlyAdded), acquire(value,clientId), complete(value), localRelease(value,intentional). `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/interfaces.ts:10-144`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/index.ts:6-22`. Type `https://graph.microsoft.com/types/consensus-queue`, snapshot version `0.1`. `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollectionFactory.ts:30-35`.

## Wire and persisted formats

Ops, required fields in producer order (deserializedValue is optional only on read):

```json
{"opName":"add","value":"{\"n\":1}","deserializedValue":{"n":1}}
{"opName":"acquire","acquireId":"2c37cf9a-d973-4c6f-9d42-83d37de05e11"}
{"opName":"complete","acquireId":"2c37cf9a-d973-4c6f-9d42-83d37de05e11"}
{"opName":"release","acquireId":"2c37cf9a-d973-4c6f-9d42-83d37de05e11"}
```

Add.value is serializer JSON text, deserializedValue is the original serializable T (omitted for undefined). Receiver falls back to parsing value only when deserializedValue === undefined; not when null. acquireId is UUID v4 string generated for each attempt. Local-only metadata is a resolver function; not a numeric ID. `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:53-98`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:149-164`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:325-360`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:404-413`.

Exactly two blobs in emission order: `header` = serializer.stringify(queue.asArray()), then `jobTracking` = serializer.stringify([...tracking.entries()]). No splitting. Empty blobs are each `[]`. Example after acquiring first of [1,2] as client c:

```text
header: [2]
jobTracking: [["2c37cf9a-d973-4c6f-9d42-83d37de05e11",{"value":1,"clientId":"c"}]]
```

Tracking record field order value,clientId; clientId omitted if undefined (detached). Summary first calls removeClient(undefined), requeueing all detached acquisitions, so a normal newly-produced summary contains no undefined-owner records. Handles recursively use `{type:"__fluid_handle__",url:"/store/channel"}`. Loader asserts tracking empty, reads/parses jobTracking into Map; asserts queue empty, reads/parses header and calls loadFrom. No migration branch or load-time quorum scrub. `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:211-222`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:283-303`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:385-432`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/snapshotableArray.ts:15-17`, `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/serializer.ts:120-162`.

Handle encoding additionally permits required-type/url plus optional final `payloadPending:true`: `{"type":"__fluid_handle__","url":"/store/blob","payloadPending":true}`. It is emitted only when the internal handle has payloadPending===true; otherwise the field is absent, never false. Decoder recognizes any value whose type property equals the marker (not a structural url validator), resolves relative URLs against serializer context, and constructs a remote handle with pending flag iff payloadPending===true. User objects with this marker therefore decode as handles rather than ordinary data. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/handles.ts:31-56`, `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/handles.ts:95-105`, `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/serializer.ts:149-162`.

## Behavior

1. Queue add pushes, remove shifts; empty remove throws SnapshotableQueue is empty. Detached add serializes/parses the input first (normalizes/clones it), then addCore pushes and emits add(value,true). Attached add submits without local data change and awaits ACK-based Promise. `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusQueue.ts:19-29`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:149-164`.
2. Acquire detached directly calls acquireCore(UUID,undefined); attached submits acquire with resolver. On sequencing, empty queue yields undefined with no event/tracking. Otherwise shift value, record acquireId→{value,clientId}, emit acquire(value,clientId), then return {acquireId,value}. In an op batch all members process synchronously in order before async callback continuations; competing attempts consume FIFO items in sequence order. `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:313-363`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:385-413`.
3. Public acquire awaits result; undefined returns false without callback. Otherwise awaits callback(value). Complete result awaits complete(acquireId); release result invokes release(acquireId), then emits localRelease(value,true), then returns true. Callback rejection escapes without automatic release. Detached complete deletes tracking and emits complete(value); detached release deletes tracking, pushes value at tail and emits add(value,false) **before** localRelease. `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:171-195`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:229-281`.
4. Attached complete/release submit only if runtime.connected && deltaManager.active. If inactive, silently do nothing (acquire still returns true and release still emits localRelease). Complete awaits op ACK; release does not wait and logs rejection under ConsensusQueue_release. Applying missing acquireId is no-op; there is no sender-ownership validation on completion/release. `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:225-281`.
5. Op processor ignores non-op envelopes; add prefers nonundefined deserializedValue, then addCore; acquire invokes acquireCore with envelope clientId (null→undefined); complete/release invoke corresponding core. Public events occur before local metadata resolver(value), where value is acquisition result only for acquire and undefined otherwise. Unknown op is unreachable. `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:320-363`.
6. removeMember requires truthy clientId then removes all matching tracking entries in Map order, appends all their values, **then** emits add(value,false) for each. Summarize does the same for undefined-owner jobs before writing. Disconnect merely emits localRelease(value,false) for each job owned by runtime.clientId; it does not itself requeue/delete. `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:140-143`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:211-214`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:305-310`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:416-428`.
7. waitAndAcquire loops: if queue empty install one-shot add listener using ACK-based Promise; then acquire; repeat on false until one success. Resolver microtasks and event listeners matter; do not synchronously invoke callback during op processing. Submission's ACK-based rejection is caught to undefined, so acquire can return false and add/complete can resolve after that failure. `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:200-208`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:365-377`.
8. ReSubmit inherits original content/resolver forwarding; disconnect does not discard pending ops. Stash resubmits original content with no-op resolver and no local replay. Rollback requires resolver function then calls it(undefined), no inverse mutation/public event. `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:474-476`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:439-460`.

## Invariants and asserts

`0x067` truthy quorum removal client; `0x068` empty tracking at load; `0x069` empty queue at load; `0x06a` submit only attached; `0x06b` loadFrom only empty underlying array; `0xc93` rollback metadata function. `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:140-142`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:283-298`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:365-368`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:451-459`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/snapshotableArray.ts:15-17`.

## JS-semantics hazards

Arrays preserve order and tracking Map preserves acquisition insertion order. Undefined in arrays serializes as null; undefined clientId object property disappears. Detached add performs JSON roundtrip; attached modern add uses original value until serialized at runtime. Release moves to tail, not original position. Summary has side effects/events (requeue undefined-owner jobs). UUID uniqueness and Promise/microtask ordering are protocol-relevant. `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:149-164`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:211-222`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:273-281`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/consensusOrderedCollection.ts:385-428`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/test/consensusOrderedCollection.spec.ts:1-20`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/test/consensusOrderedCollection.fuzz.spec.ts:1-20`, `reference/fluidframework-3.11.0/packages/dds/ordered-collection/src/test/fuzzUtils.ts:1-20` provide queue, acquisition, disconnect/requeue, snapshot and fuzz entry points. Preserve complete vs release event order and concurrent acquire outcomes.

## Open questions

None.
