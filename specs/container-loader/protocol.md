# Container-loader: protocol and audience

## 1. Role

`ProtocolOpHandler` owns sequence/MSN and Quorum; `ProtocolHandler` adds sender validity and the mixed read/write audience. Quorum composes separate membership and proposal objects. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/protocol.ts:52-81`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol.ts:105-159`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:424-462`.)

## 2. Surface used by other packages

`IQuorumSnapshot = {members,proposals,values}`; `IScribeProtocolState = {sequenceNumber,minimumSequenceNumber,members,proposals,values}`. Handler attributes getter returns `{minimumSequenceNumber,sequenceNumber}` in that order, distinct from the scribe state's order. `getProtocolState(true)` replaces each member's `client.user` with `{id:""}` through object spreads without changing other member fields; that scrubbed output is not valid summary data. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/protocol.ts:25-45`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/protocol.ts:69-73`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/protocol.ts:160-183`.)

Quorum provides `getMembers` (new Map, shared value objects), `getMember`, `has`, `get` (committed proposal's value), `propose`, `addProposal`, `updateMinimumSequenceNumber`, snapshot and connection setter. Audience supplies `getSelf`, `setCurrentClientId`, add/remove and membership accessors. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:473-561`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/audience.ts:25-100`.)

## 3. Wire and persisted formats

### Exact `.protocol` tree

`SummaryType.Tree = 1`, `Blob = 2`. `captureProtocolSummary` constructs outer properties `tree,type`; tree properties are `attributes,quorumMembers,quorumProposals,quorumValues`; each blob properties are `content,type`. `content` is a JSON string, not an embedded JSON object. No optional blob or version discriminator is emitted. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:1959-1983`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/summary.ts:24-56`.)

| Blob | Literal JSON content schema and order |
|---|---|
| `attributes` | `{"minimumSequenceNumber":number,"sequenceNumber":number}`; both required. |
| `quorumMembers` | `[[clientId:string,{"client":IClient,"sequenceNumber":joinSN}], ...]`; array order is Map insertion order. |
| `quorumProposals` | `[[proposalSN:number,{"sequenceNumber":number,"key":string,"value":JSON},[]], ...]`; fresh snapshots emit empty rejection arrays. `local` is never emitted by fresh snapshot generation. |
| `quorumValues` | `[[key:string,{"approvalSequenceNumber":approvalOpSN,"commitSequenceNumber":-1,"key":string,"sequenceNumber":proposalSN,"value":JSON}], ...]`; Map insertion order, overwriting a key retains its position. |

The member record order is produced at join; fresh proposal and approval record orders are produced by their respective constructors. Restored snapshot arrays are cached verbatim until invalidated: a restored proposal's third element (legacy rejections) and restored object property order survive unchanged until the proposal cache is rebuilt. On restoration, the internal map key is **the inner proposal.sequenceNumber**, not the outer tuple number; restored proposals always have `local=false`. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/protocol.ts:107-114`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:77-91`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:165-204`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:343-357`.)

A concrete empty-members/pending-proposal summary after proposing `theme="dark"` at SN 8, followed by an op at SN 9 with MSN 7, is the following `.protocol` subtree (spacing outside content strings is illustrative; content strings are exact):

```json
{"tree":{"attributes":{"content":"{\"minimumSequenceNumber\":7,\"sequenceNumber\":9}","type":2},"quorumMembers":{"content":"[]","type":2},"quorumProposals":{"content":"[[8,{\"sequenceNumber\":8,\"key\":\"theme\",\"value\":\"dark\"},[]]]","type":2},"quorumValues":{"content":"[]","type":2}},"type":1}
```

After SN 10 with MSN 8, the exact changed blob contents are `attributes = {"minimumSequenceNumber":8,"sequenceNumber":10}`, `quorumProposals = []`, `quorumValues = [["theme",{"approvalSequenceNumber":10,"commitSequenceNumber":-1,"key":"theme","sequenceNumber":8,"value":"dark"}]]`. This is one approval/commit step, **not** a later commit-message phase. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/protocol.ts:100-153`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:328-401`.)

Detached initialization is a different committed-record order and sentinel: `[["code",{"key":"code","value":{"package":"example"},"approvalSequenceNumber":0,"commitSequenceNumber":0,"sequenceNumber":0}]]` for code details `{package:"example"}`. Do not normalize it to the approval record above. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/quorum.ts:9-20`.)

Combining a runtime summary emits `{type:1,tree:{".protocol":protocolSummary,".app":appSummary}}` with `.protocol` before `.app`. For detached snapshot conversion, flatten `.app.tree` into root and append `.protocol`. Loading uses `snapshot.trees[".protocol"]` if that key exists, else the root. Attribute blob ID comes from `.protocol.blobs.attributes`, or legacy root `blobs[".attributes"]`; quorum blob names stay `quorumMembers`, `quorumProposals`, `quorumValues` in the chosen protocol tree. No tree gives zero sequence/MSN; an existing tree triggers parallel reads of all three quorum blobs. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/utils.ts:119-139`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/utils.ts:254-285`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/utils.ts:439-458`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:1887-1911`.)

### Message and signal payloads

The sequenced envelope requires `clientId:string|null, sequenceNumber:number, minimumSequenceNumber:number, clientSequenceNumber:number, referenceSequenceNumber:number, type:string, contents:unknown, timestamp:number`. Optional `metadata,serverMetadata` are unknown JSON; `origin?:{id:string,sequenceNumber:number,minimumSequenceNumber:number}`, `traces?:[{service:string,action:string,timestamp:number}]`, `data?:string`, `expHash1?:string`, `compression?:string`. Received field order is preserved, not reconstructed from interface declaration order. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/protocol.ts:100-115`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/protocol.ts:196-299`.)

| type | Payload consumed by protocol | Result |
|---|---|---|
| `join` | `data` JSON string, e.g. `"{\"clientId\":\"c1\",\"detail\":{\"mode\":\"write\",\"details\":{\"capabilities\":{\"interactive\":true}},\"permission\":[],\"user\":{\"id\":\"u1\"},\"scopes\":[]}}"` | add `{client:detail,sequenceNumber:message.sequenceNumber}` |
| `leave` | `data` JSON string encoding the ID, e.g. `"\"c1\""` | remove member |
| `propose` | emitted contents string `"{\"key\":\"theme\",\"value\":\"dark\"}"`; already-parsed object accepted too | pending proposal, immediateNoOp=true |
| `noop`, `accept`, `reject`, `summarize`, `summaryAck`, `summaryNack`, `op`, `noClient`, `tripComplete`, `control`, any other type | no type-specific processing by protocol | still advance sequence/MSN and approve eligible proposals |

These literal message types come from the driver enum; `reject` remains recognized as a client message but rejection support is removed from proposal handling. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/protocol.ts:11-79`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/protocol.ts:106-153`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:1918-1920`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:110-125`.)

`IClient` requires mode `read|write`, details `{capabilities:{interactive:boolean},type?:string,environment?:string,device?:string}`, permission:string[], user object with id:string and opaque additional user fields, scopes:string[], timestamp?:number. `ISignalClient` is `{clientId:string,client:IClient,clientConnectionNumber?:number,referenceSequenceNumber?:number}`. Preserve received client property order in summaries and duplicate comparisons. (`reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/clients.ts:41-151`.)

Raw signals have `clientId:string|null`, `content:string` containing JSON, optional `clientConnectionNumber:number,referenceSequenceNumber:number,targetClientId:string`; a top-level `type` property is forbidden even if its value is undefined. System audience content is exactly `{"type":"clear"}`, `{"type":"join","content":ISignalClient}`, or `{"type":"leave","content":"c1"}`. Example raw clear: `{"clientId":null,"content":"{\"type\":\"clear\"}"}`. Synthetic join generation preserves `priorClient` as content, not an op-style `detail`. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionManager.ts:122-132`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionManager.ts:947-980`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/protocol.ts:339-378`.)

### Nonempty member blob example

For the `join` payload above sequenced at SN 1, the exact `quorumMembers` blob string content is:

```json
[["c1",{"client":{"mode":"write","details":{"capabilities":{"interactive":true}},"permission":[],"user":{"id":"u1"},"scopes":[]},"sequenceNumber":1}]]
```

The client object is the parsed `detail` object, not a projection onto known fields; extra properties and their JSON insertion order survive. A `leave` deletes this tuple, preserving the relative order of remaining tuples. Rejoining the same ID after removal appends it at the end. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/protocol.ts:107-122`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:77-117`.)

## 4. Behavior

### Protocol dispatch: execution order

1. Wrapper checks non-nullish sender: absent quorum membership throws `Remote message's clientId is missing from the quorum` unless type is `join`. Then if sender is flagged should-have-left and type is neither `noop` nor `accept`, throw `Remote message's clientId already should have left`.
2. Base requires SN = previous SN+1, otherwise throws `Protocol state is not moving sequentially. Current is N. Next is M` without advancing state.
3. Assign sequenceNumber, then minimumSequenceNumber. Start immediateNoOp=false.
4. Dispatch join/leave/propose as above. Propose parses string contents **by mutating message.contents**, adds proposal, then sets immediateNoOp=true. Other types do nothing in switch.
5. Update quorum MSN on **every** message, then return `{immediateNoOp}`. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol.ts:135-159`, `reference/fluidframework-3.11.0/packages/loader/driver-utils/src/messageRecognition.ts:28-33`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/protocol.ts:88-153`.)

### Membership

QuorumClients initializes Map and snapshot cache from supplied array. Add asserts nonempty ID and absent member, inserts, synchronously emits `addMember(id,sequencedClient)`, then invalidates snapshot cache. Remove asserts nonempty/present, deletes, emits `removeMember(id)` with no details arg, then invalidates. Quorum forwards these events synchronously. `dispose` only marks the clients object disposed. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:77-136`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:440-446`.)

### Proposal states and events

- **Unsequenced local**: `propose(key,value)` first calls sendProposal. Negative return emits proposal object's `error({eventName:"ProposalInDisconnectedState",key})`, then rejects `Can't propose in disconnected state`. Otherwise install internal listeners for localProposalSequenced, disconnected, disposed. Quorum does not forward this error event.
- **Pending**: addProposal asserts SN absent, constructs fields `sequenceNumber,key,value,local`, inserts by SN, emits public `addProposal(proposal)`, then if local emits internal `localProposalSequenced(CSN,SN)`, then invalidates proposals cache. Matching local CSN records assigned SN, removes sequence/disconnect listeners, installs localProposalApproved listener.
- **Approved/committed**: on each MSN collect proposals whose SN <= MSN, numerically sort increasing. For each: construct committed record in the exact order above; values.set(key,record); invalidate values cache; count matching-key entries in the **still-pending map including this proposal** (stop after second); emit `approveProposal(SN,key,value,approvalSN)`; if there was exactly one matching pending proposal emit `approveProposalComplete` with the same four args; delete this proposal; invalidate proposals cache; if local emit internal `localProposalApproved(SN)`. Matching promise resolves and listeners are removed. Two same-key proposals can both approve on one message; the later one wins and only its final approval emits Complete, unless a higher pending proposal for that key remains.
- **Disconnected before sequence**: do not reject immediately. Register a once-connected callback; if assigned SN is still undefined when connected fires, reject `Client disconnected without successfully sending proposal` and clean listeners. An ack before that callback rescues the promise. Disconnect after sequencing does not reject the approval wait.
- **Disposed**: proposals object sets disposed then emits internal disposed; every outstanding proposal rejects `QuorumProposals was disposed`. Quorum.close merely removes listeners on the outer quorum; it does **not** dispose children or resolve/reject promises. Quorum.dispose throws `Not implemented.`.

Only `addProposal` and `approveProposal` are forwarded from proposals to Quorum; `approveProposalComplete`, error and internal state events are not. Each listener runs synchronously in registration order; promise continuations run later. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:226-294`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:300-416`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:448-467`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:560-566`.)

Container's registered quorum listeners turn `code`/`code2` addProposal into `codeDetailsProposed(value,proposal)`. On approval for these keys, start processCodeProposal; it pauses inbound and signal queues, tests module constraints and either resumes both or closes with GenericError `Existing context does not satisfy incoming proposal` (no `codeDetailsChanged` event). The proposal approval itself is synchronous; the constraint test is asynchronous. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:1932-1950`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:1491-1507`.)

### Audience and self

Constructing ProtocolHandler first seeds audience from quorum members in Map order, then registers quorum add/remove → audience add/remove listeners. Write membership is controlled exclusively by ops. Audience.add inserts and emits `addMember(id,client)` only if absent; duplicate must stringify identically or assert 0x4b2, with no second event. Audience.remove absent returns false/no event; present deletes, emits `removeMember(id,removedClient)`, returns true. No removal clears currentClientId or emits selfChanged. Disconnect retains membership until later signals/ops change it. getMembers returns a new Map with shared client values. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol.ts:124-132`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/audience.ts:52-100`.)

Self is undefined only when no ID has ever been set. Otherwise getSelf returns `{clientId,client:getMember(id)}`, even when client is undefined. setCurrentClientId(sameID) is silent; different ID assigns first, then emits `selfChanged(oldID===undefined ? undefined : {clientId:oldID}, {clientId:newID,client:getMember(newID)})`. Old-self has no client field. Adding a matching member later emits addMember, not selfChanged. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/audience.ts:25-46`.)

Delta signal processing JSON-parses content once. Only `clientId===null` and inner type clear/join/leave selects the protocol handler. Default handler clear removes read-mode members in copied-Map order; join adds only read-mode client; leave removes only when existing member.mode is read. Others remain runtime signals, including system signals with other inner types. Local runtime signal = sender equals signalAudience.getSelf()?.clientId OR container.clientId. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:489-501`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol.ts:162-214`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2399-2414`.)

The builder wrapper, applied to both the default and custom builders, maintains **signalAudience for all modes**: before delegating target.processSignal, clear removes every signal-audience member, join adds every client, leave removes ID. It is not the read-filtered protocol audience. Proxy preserves dynamic getters. Container always installs this wrapper, including around the default ProtocolHandler (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:808-823`). On CatchingUp container sets signalAudience's self to pending ID; on Connected sets protocol audience self, then signalAudience self, then runtime status, then protocol connection state, then host connected event. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol.ts:217-263`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2211-2250`.)

### Nested event order during a join or leave

A quorum join first inserts membership, then QuorumClients emits to Quorum's forwarding listener. Quorum emits to ProtocolHandler's audience listener, which inserts the audience entry and emits audience `addMember`. The connection-state listener installed later by `initProtocol` can therefore promote connection state **inside this audience callback**, before later quorum `addMember` listeners run. Only after the entire synchronous emission unwinds does QuorumClients invalidate its snapshot cache; protocol then evaluates MSN approvals; runtime.process follows. Leave similarly deletes quorum membership before audience removal, so the connection handler's absent-quorum assertion sees the deletion. Do not flatten this into an event list emitted after the op finishes. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:97-117`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:440-446`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol.ts:124-132`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionStateHandler.ts:733-765`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2351-2355`.)

`QuorumProposals.setConnectionState` emits internal `connected` or `disconnected` on every call, without deduplicating state or using clientId. Cleanup of a proposal promise removes its four named listeners but does **not** remove an already registered anonymous once-connected callback; that callback can later run and observes whether sequencing occurred. There are no disposed guards on add/get/snapshot/propose methods; disposal flags are not additional implicit failure predicates. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:262-294`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:404-416`.)

## 5. Invariants and asserts

| Code | Predicate / failure |
|---|---|
| 0x9a0 / 0x9a2 | quorum add/remove ID truthy |
| 0x9a1 / 0x9a3 | add ID absent / remove ID present |
| 0x9a4 | proposal sequence key absent |
| 0x4b2 | duplicate audience JSON.stringify equal |

These are assertions, not idempotent quorum operations. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:97-117`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:307-321`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/audience.ts:55-60`.)

## 6. JS-semantics hazards

Snapshot getter cache is invalidated **after** add/remove/addProposal listeners, so a synchronous snapshot from a listener may see the old cache. Values cache invalidates before approveProposal, proposals cache after its deletion. Restored arrays are returned unchanged while cached. Preserve `undefined` values: JSON.stringify omits undefined object value properties but emits null for an undefined array slot; arbitrary JSON values must not be coerced to strings. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:88-117`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:193-204`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:307-321`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/quorum.ts:343-401`.)

## 7. Test assets to reuse

Existing protocol tests cover sequential counters, nonsequential rejection, scrubbed and unscrubbed users (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/test/protocol.spec.ts:38-218`). Quorum tests cover local/remote proposals, overwrites, disconnection promises, stable proposal snapshots and member add/remove (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/test/quorum.spec.ts:24-297`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/test/quorum.spec.ts:299-450`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/test/quorum.spec.ts:451-679`). Additional differential cases should compare exact events/blobs for same-key proposals, MSN equal to proposal SN, snapshot from within callbacks, audience duplicate payload property order, and write join-signal ignored versus read join-signal accepted; expected branches are specified above, not assumed covered by those protocol tests.

## 8. Open questions

None.
