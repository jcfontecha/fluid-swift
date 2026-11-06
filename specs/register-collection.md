# register-collection (3.11.0)

## Role

Per-key consensus register with an atomic winner and a causally unshadowed version list. Attached writes are ACK-based, not optimistic. `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:128-218`.

## Surface used by other packages

`ConsensusRegisterCollection<T>` / factory-kind, `write(key,value): Promise<boolean>`, `read(key,policy=Atomic)`, `readVersions(key)`, `keys()`, `ReadPolicy.Atomic = 0`, `ReadPolicy.LWW = 1`. Atomic read returns the chosen register; other policy values take the latest version. Events `atomicChanged(key,value,local)`, `versionChanged(key,value,local)`. `reference/fluidframework-3.11.0/packages/dds/register-collection/src/interfaces.ts:15-88`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:226-248`. Type `https://graph.microsoft.com/types/consensus-register-collection`, version `0.1`. `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollectionFactory.ts:28-33`.

## Wire and persisted formats

Current write op construction order: required string `key`, literal `type`, required serialized JSON string `serializedValue`, required object `value`, required numeric `refSeq` captured from deltaManager.lastSequenceNumber:

```json
{"key":"a","type":"write","serializedValue":"7","value":{"type":"Plain","value":7},"refSeq":10}
```

Wrapper construction order is `type`, then arbitrary serializable `value`; undefined omits inner value and can also omit serializedValue at runtime despite its string TS declaration. Both redundant representations are emitted for compatibility; receiver tests property presence (`"value" in op`) and prefers `op.value.value`, not serializedValue, even when inner value is undefined. Legacy form without value is accepted: `{"key":"a","type":"write","serializedValue":"7"}`; absent/undefined refSeq is filled from envelope.referenceSequenceNumber. Local metadata is numeric message ID, not sent. `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:65-105`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:168-179`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:288-308`.

Single `header` blob, no partition: serializer.stringify on a plain object populated from data Map. Key payload has `atomic`, then `versions`; each register is constructed `sequenceNumber`, then `value:{type:"Plain",value:T}`. Concrete state after the above op sequences at 11:

```json
{"a":{"atomic":{"sequenceNumber":11,"value":{"type":"Plain","value":7}},"versions":[{"sequenceNumber":11,"value":{"type":"Plain","value":7}}]}}
```

Empty state `{}`. Handles anywhere serialize to `{"type":"__fluid_handle__","url":"/store/channel"}` and deserialize through serializer.parse; no old Shared-object atomic values may load (`0x06d`). Loader uses Object.keys order, asserts then stores each data payload without recomputing versions or emitting events. `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:33-58`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:250-271`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:409-415`, `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/serializer.ts:120-162`.

Handle encoding additionally permits required-type/url plus optional final `payloadPending:true`: `{"type":"__fluid_handle__","url":"/store/blob","payloadPending":true}`. It is emitted only when the internal handle has payloadPending===true; otherwise the field is absent, never false. Decoder recognizes any value whose type property equals the marker (not a structural url validator), resolves relative URLs against serializer context, and constructs a remote handle with pending flag iff payloadPending===true. User objects with this marker therefore decode as handles rather than ordinary data. `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/handles.ts:31-56`, `reference/fluidframework-3.11.0/packages/runtime/runtime-utils/src/handles.ts:95-105`, `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/serializer.ts:149-162`.

## Behavior

1. `write`: disposed runtime returns Promise(false). Detached invokes inbound-write with refSeq=seq=0 and local=true synchronously, then resolves true. Attached captures original reference sequence, allocates next local ID, installs ACK/rollback/runtime-dispose listeners, submits; visible state/events do not change yet. ACK of matching ID resolves winner flag; rollback/disposal resolves false; listeners removed on settlement. `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:157-218`.
2. Process each op envelope member in order. For write fill missing refSeq, assert original refSeq ≤ envelope reference, choose value representation, then inbound-write. Original refSeq is retained over reconnect even though envelope refSeq can increase. Unknown type is unreachable-case failure. `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:276-334`.
3. Inbound-write: look up current key. Winner iff absent or `refSeq >= atomic.sequenceNumber`. Winner constructs `{sequenceNumber,value:{type:"Plain",value}}`; for absent key create `{atomic,versions:[]}`, otherwise replace atomic. Losing writes leave atomic unchanged. `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:350-374`.
4. Remove versions from **front** while `refSeq >= first.sequenceNumber`. Construct a new register at incoming sequenceNumber, validate detached zeros or attached nondecreasing sequence order, append even if atomic loser. Emit atomicChanged only for winner, then always versionChanged. Finally for local message validate numeric metadata and emit internal pendingMessageAck(ID,winner), resolving write after public events. `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:309-327`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:377-406`.
5. Example: concurrent A(seq=11,ref=10) then B(seq=12,ref=10) → atomic A, versions [A,B], LWW B. Later C(seq=13,ref=12) replaces atomic and removes A,B → versions [C]. First sequenced concurrent writer wins atomic; a causally later writer wins once its captured ref sees atomic. `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:350-406`.
6. ReSubmit inherits exact original op/metadata forwarding, no refSeq recapture or local replay. Disconnect no-op. Rollback asserts numeric ID and emits internal rollback; no data inverse because write wasn't applied locally. Stash asserts write, allocates ID and submits original op; no public write Promise/listeners, optimistic events, or value change. `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:274`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:421-439`, `reference/fluidframework-3.11.0/packages/dds/shared-object-base/src/sharedObject.ts:474-476`.

## Invariants and asserts

`0x06c`: nonmissing versions must be nonempty when read; `0x06d`: loaded atomic value cannot have type Shared; `0x06e`: captured refSeq not newer than envelope refSeq; `0x06f`: loser has data; `0x070`: detached ref/seq both zero; `0x071`: appended version sequence ≥ last version; `0xc0e` ACK metadata number; `0xc0f` rollback metadata number; `0xccc` stash write-only. `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:226-238`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:264-268`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:300-320`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:350-395`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:421-438`.

## JS-semantics hazards

Do not collapse atomic into LWW or prune all concurrent versions. Equal sequence numbers are legal for grouped batch members; >= comparisons are intentional. Values are not cloned on the Plain inbound path. Undefined differs from null; serializedValue is a JSON **string**, not a nested JSON value. Summary object plain assignment drops `__proto__` even though live Map and ops retain it. Integer-like keys reorder in summaries and therefore after loading. `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:168-176`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:250-270`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:306-308`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/consensusRegisterCollection.ts:350-405`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/dds/register-collection/src/test/consensusRegisterCollection.spec.ts:1-20`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/test/consensusRegisterCollection.fuzz.spec.ts:1-20`, `reference/fluidframework-3.11.0/packages/dds/register-collection/src/test/fuzzUtils.ts:1-20` are behavioral and fuzz entry points. Preserve atomic-winner vs version-list comparisons, original-ref reconnect cases, rollback Promise settlement, legacy serialized-only ops and summary bytes.

## Open questions

None.
