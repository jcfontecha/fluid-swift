# ODSP join-session, socket specialization and operations

## Role

Join-session discovers relay IDs/URLs and optionally a relay token; the delay-loaded stream maintains discovery freshness and connects an ODSP-specialized driver-base DocumentDeltaConnection. REST delta storage, opportunistic socket get_ops, initial snapshot operations and persisted batches jointly supply the operation stream. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDelayLoadedDeltaStream.ts:140-268`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDeltaStorageService.ts:138-263`.

## Surface used by other packages

`fetchJoinSession`, `OdspDocumentDeltaConnection.create`, `.requestOps(from,to)`, `.flush()`, `.submit`, `.submitSignal`; `OdspDeltaStorageService.get/buildUrl`, `OdspDeltaStorageWithCache.fetchMessages`, `OpsCache.addOps/get/flushOps/dispose`. Generic handshake/early queues/event listener ownership are the driver-base contract; ODSP differences are normative below. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/vroom.ts:46-59`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:251-264`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:444-535`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:808-825`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/opsCaching.ts:31-83`.

## Wire and persisted formats

Let A=API root (`origin/_api/v2.1`, consumer `origin/v2.1`). Join POST `A/drives/<driveId>/items/<itemId>/opStream/joinSession?ump=1`, IDs interpolated raw. Actual header `Content-Type:multipart/form-data;boundary=B`. Body lines, joined with CRLF:

```text
--B
[epoch/correlation/CLP lines inserted here]
Authorization: Bearer TOKEN
X-HTTP-Method-Override: POST
Content-Type: application/json
[Prefer: FluidRemoveCheckAccess]
Prefer: Return-Sensitivity-Labels
_post: 1

[{"requestSocketToken":true,"displayName":"Guest"}]

--B--
```

FluidRemoveCheckAccess is included unless disableJoinSessionRefresh truthy. requestSocketToken appears only when true; displayName only when truthy, after requestSocketToken. When neither, **no JSON body or its surrounding extra CRLF is emitted**, only `_post: 1\r\n\r\n--B--`. When present `_post: 1\r\n\r\nJSON\r\n\r\n--B--`. Response `{id:string,runtimeTenantId?:string,tenantId:string,snapshotStorageUrl:string,deltaStorageUrl:string,deltaStreamSocketUrl:string,socketToken?:string,refreshSessionDurationSeconds?:number,sensitivityLabelsInfo?:{timestamp:number,labels:[{sensitivityLabelId:string,tenantId:string,assignmentMethod:string,appliedByUserEmail:string}]}}`. If runtimeTenantId truthy and tenantId falsy, copy runtimeTenantId to tenantId. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/vroom.ts:60-145`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/sessionProvider.ts:12-74`.

Socket options `{multiplex:false,query:undefined|{documentId,tenantId},reconnection:false,transports:["websocket"],timeout:60000,extraHeaders?:hostHeaders}`. Multiplex **driver-managed**, enabled iff URL query has neither documentId nor tenantId (presence, even empty, disables). Ref key is prefix truthy ? `prefix,url` : url; nonmultiplex adds `,tenantId,documentId`. Exact connect_document insertion order:

```text
{client,id:documentId,mode:client.mode,tenantId,token,
 versions:["^0.4.0","^0.3.0","^0.2.0","^0.1.0"],driverVersion:"3.11.0",
 nonce:connectionIdUUID,epoch:knownEpochOrUndefined,
 relayUserAgent:[client.details.environment," driverVersion:3.11.0"].join(";"),
 supportedFeatures:{api_get_ops:true,submit_signals_v2:true}}
```

api_get_ops omitted only when `Fluid.Driver.Odsp.GetOpsEnabled===false`; submit_signals_v2 is appended by base initialization. Missing environment produces `; driverVersion:3.11.0`. JSON serialization omits undefined epoch. Base handshake timer is timeout+2000, hence **62000ms** for ODSP; it does not mean REST ops timeout (30000ms) or discovery refresh buffer (30000ms). Source: `reference/fluidframework-3.11.0/packages/drivers/driver-base/src/documentDeltaConnection.ts:523-527`. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:267-320`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:389-436`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDelayLoadedDeltaStream.ts:550-563`, `reference/fluidframework-3.11.0/packages/drivers/driver-base/src/documentDeltaConnection.ts:487-490`.

| Socket event | Literal arguments |
|---|---|
| get_ops | `(clientId,{nonce:UUIDprefix+counter,from:inclusive,to:exclusive-1})` |
| get_ops_response | `{nonce:string,code:number,retryAfter?:number,messages?:SequencedMessage[]}` |
| flush_ops | `(clientId,{nonce:UUIDprefix+counter})` |
| flush_ops_response | `{nonce:string,code:number,retryAfter?:number,lastPersistedSequenceNumber?:number}` |
| submitOp | `(clientId,[messages])`, messages=DocumentMessage[] |
| submitSignal | `(clientId,[{content:string,targetClientId?:string}])` (always new format) |
| disconnect_document | `(clientId,documentId)` |
| server_disconnect | `(socketError:{code:number,message:string,retryAfter?:number,error?:unknown},clientId?:string)` |
| op | `(documentId,SequencedMessage[])` |
| signal | `(Signal|Signal[],documentId?:string)` |
| nack | `(clientIdOrDocumentId,INack[])` |

Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/contracts.ts:18-42`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/contracts.ts:212-230`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:138-159`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:493-534`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:674-759`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:797-879`.

REST ops POST `<deltaFeedUrl>?ump=1&filter=<encodeURIComponent("sequenceNumber ge F and sequenceNumber le T-1")>`, e.g. `?ump=1&filter=sequenceNumber%20ge%2010%20and%20sequenceNumber%20le%2019`. UMP body is `--B\r\nAuthorization: Bearer TOKEN\r\nX-HTTP-Method-Override: GET\r\n_post: 1\r\n\r\n--B--`, with epoch/correlation inserted. Response `{value:SequencedMessage[]}` or `{value:[{op:SequencedMessage,sequenceNumber:number}]}`. Determine variant solely by nonempty array and `"op" in value[0]`; unwrap entire array if so. Return `{messages,partialResult:false}`. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDeltaStorageService.ts:48-135`.

Ops batch persisted key is `<batchSize>_<floor(seq/batchSize)>`, entry type ops, value **JSON string** of length=batchSize array; holes/undefined encode as null. Example size=3, only seq=4 present: key `3_1`, value `[null,{"sequenceNumber":4},null]`. EpochTracker wraps that string as `{value:"[null,...]",version:3,fluidEpoch:"E"}`. Slot is seq%batchSize (sequence 0 is slot 0). Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/opsCaching.ts:139-175`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/opsCaching.ts:202-232`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentService.ts:329-350`.

Common protocol payloads used above: DocumentMessage has required `{clientSequenceNumber:number,referenceSequenceNumber:number,type:string,contents:unknown}` and optional metadata/serverMetadata, traces `{service:string,action:string,timestamp:number}[]`,compression:string. SequencedMessage adds required `{clientId:string|null,sequenceNumber:number,minimumSequenceNumber:number,timestamp:number}`, optional origin `{id:string,sequenceNumber:number,minimumSequenceNumber:number}`,data:string,expHash1:string. Signal requires `{clientId:string|null,content:unknown}`, optional type,targetClientId strings and clientConnectionNumber/referenceSequenceNumber numbers. Nack requires `{operation:DocumentMessage|undefined,sequenceNumber:number,content:{code:number,type:"ThrottlingError"|"InvalidScopeError"|"BadRequestError"|"LimitExceededError",message:string,retryAfter?:number}}`. These received JSON objects have no client-imposed property order; JSON-encoded op strings preserve whatever input object order producer owns. Sources: `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/protocol.ts:100-300`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/protocol.ts:339-386`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/protocol.ts:504-554`.

## Behavior

### Discovery and connection transitions

**Disconnected→Connecting** requires currentConnection undefined (0x4ad). Inside one-refresh wrapper, concurrently start host websocket token (if supplied) and cached join-session. If no callback, requestSocketToken=true. Final token is host token ?? join.socketToken ?? null; null throws nonretryable fetchTokenError. Apply labels from endpoint; create UUID; first-attempt telemetry once; initialize socket and then validate socket epoch. On success register op→opsReceived, signal handler, process initialSignals, install once-disconnect, assign currentConnection, return. On failure from connect_document_error or missing scenarioName clear timer/cache; other socket failure keeps discovery cache. Annotate failedConnectionStep and separateTokenRequest. Socket create changes status 400/404 errors to canRetry=true; 406/409 remain fatal. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDelayLoadedDeltaStream.ts:140-268`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:318-346`.

**Discovery cache miss→Fresh**: cache key hashedDocumentId+`/joinsession`; network fetch inside runWithRetry then emits labels before returning `{entryTime:Date.now(),joinSessionResponse}`. Missing refresh duration becomes 3600 seconds. `delta=entryTime+duration*1000-30000-Date.now()`. delta<=0 removes cache and refetches once. Unless refresh disabled, positive delta schedules refresh; duplicate timer cleared/logged; callback clears its timer then does refresh under token-refresh retry. Refresher must still have a currentConnection and matching scheduled clientId (when defined), else throw JoinSessionRefreshTimerNotCancelled. Refresh failure logs only; later reconnect can recover. Disconnect always clears timer; authorization disconnect clears discovery cache, asserts connection already disposed (0x4ae), clears currentConnection. Dispose clears timer then disposes connection and deletes pointer. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUtils.ts:560-562`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDelayLoadedDeltaStream.ts:225-239`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDelayLoadedDeltaStream.ts:293-505`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDelayLoadedDeltaStream.ts:524-581`.

Join facets sessionForbidden, sessionForbiddenOnPreservedFiles, sessionForbiddenOnModerationEnabledLibrary, sessionForbiddenOnRequireCheckout, sessionForbiddenOnCheckoutFile, sessionForbiddenOnInvisibleMinorVersion → policies.storageOnly=true then DeltaStreamConnectionForbiddenError(reason=facet). Relay identity after successful join is `tenantId/id`. Labels with timestamp number>0 (0x8e0) update only strictly newer than last timestamp (initial −1); update timestamp **before** metadataUpdateHandler `{sensitivityLabelsInfo:JSON.stringify(info)}`. Server signal accepted only clientId===null; parse content as JSON, ignore syntax errors, require envelope.contents.type=`PolicyLabelsUpdate`; pass envelope.contents.content into same label handler. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDelayLoadedDeltaStream.ts:271-291`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDelayLoadedDeltaStream.ts:373-407`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDelayLoadedDeltaStream.ts:508-530`.

### Shared socket ownership and event order

Reference starts refs=1/pendingInitial=true. find: if unhealthy, close and return none; else cancel deletion and increment refs. Connected socket healthy; never-connected socket healthy only while pendingInitial=true. Release decrements refs, sets pendingInitial=false; disconnected closes immediately; healthy refs=0 schedules close in **2000ms**. Close sequence: remove server_disconnect listener→clear timer→assert map identity→delete global key→clear socket pointer→emit disconnect(error,undefined) synchronously→assert refs==0→socket.disconnect. Thus reentrant reconnect cannot reuse closing socket. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:57-228`.

server_disconnect error mapped then forced canRetry=true. Missing clientId closes shared socket; present ID emits reference disconnect for matching connection only. Multiplex early ops require document ID match; early signals accept missing ID or matching ID. Live multiplex ops require matching document; signals require documentId defined (0xa65), match document, filter targetClientId falsy or own clientId; singleton forwarded as Signal, multiple as array, none dropped. Nack handles first ID empty/own document/own client, logs ServerNack then emits only if handles. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:138-159`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:537-619`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:674-759`.

Submit only if !disposed and socket.connected; otherwise silently drops. ODSP always emits new signal array format regardless server feature. DisconnectCore sequence: clear flush nonce→reject pending flush with disconnect error→clear flush deferred/start→log FlushCancelledOnDisconnect iff pending→capture/clear socketReference→remove reference-disconnect listener→emit disconnect_document iff details exist→release ref→reject pending initialization. Base disconnect event occurs after disposal. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:788-881`, `reference/fluidframework-3.11.0/packages/drivers/driver-base/src/documentDeltaConnection.ts:450-471`.

### Socket operation fetch / flush

requestOps asserts active socket and to>from, returns without emission unless server supportedFeatures.api_get_ops===true. Increment shared push counter, derive UUIDprefix-counter nonce; if 5 tracked requests, remove earliest-start entry (ties choose later iteration), log GetOpsTooMany; track before emit. get_ops_response processed if tracked nonce **or** nonce starts own UUID prefix (accept delayed response after eviction); remove tracked entry, log GetOps, emit op(documentId,messages) iff nonempty messages, **regardless response code**. Other clients' nonce ignored. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:444-498`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:584-619`.

flush requires server api_flush_ops=true or logs FlushOpsNotSupported and throws Error. New flush while pending logs FlushOpsTooMany and rejects old Deferred with a string; emits flush_ops **before** assigning new nonce/deferred/start. Matching response logs FlushResult, resolves with whole result even non-200/undefined sequence, then clears fields. Unmatched response ignored. No per-flush timeout exists here. Disconnect rejects pending flush. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:500-535`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:621-657`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:844-861`.

### Ordered delta sourcing

Default REST batchSize=5000, concurrency=1. cachedOnly with finite to asserts 0x1e3. Once per fetchMessages, AND useCacheForOps with storageManager.isFirstSnapshotFromNetwork===false (network/unknown permanently disables). For each [from,to): (1) filter initial snapshot ops; validate; if starts at from, keep only initial ops>=to and return partial=true; otherwise discard snapshot ops. (2) requestFromSocket opportunistically without awaiting. (3) If cache enabled, read+validate; set useCacheForOps=(from+count>=to); if nonempty return partial=true. (4) cachedOnly→empty nonpartial; else REST fetch→validate→opsReceived→return. Outer requestOps stream uses batch/concurrency and validates again. REST timer aborts at **30000ms**, cleared on successful response (not finally); token refresh logic wraps fetch. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentService.ts:218-224`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDeltaStorageService.ts:91-126`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDeltaStorageService.ts:161-263`.

### OpsCache transitions

Initialize first batch with slots remaining after startingSequenceNumber inclusive, never expect prior operations. Defaults cache batch=100,timer=5000ms,total=5000; no sequence or batchSize<1 disables creation. Summarizer/empty input does not add ops. For each op: absent batch creates sparse array with remaining=size−1, dirty=true; existing nonnull empty slot inserts/decrements; duplicate slot or null (already completed batch) **returns from entire addOps**, skipping later input ops. Full batch write then map entry=null; incomplete schedules one timer if granularity>0. Decrement quota per inserted op; exactly zero logs CacheOpsLimitHit→remove all file cache entries→dispose batches/timer→break. Write rejection sets totalOpsToCache=0 but does not delete previously persisted batches. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/opsCaching.ts:35-131`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/opsCaching.ts:202-232`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentService.ts:318-362`.

flushOps skips null, clean, empty, or batches whose **both** first and last slots undefined; otherwise clears dirty before nonawaited write. Timer resets pointer before flush. Read starting batch sequentially: absent batch→return; JSON.parse; ignore null before first match, reject first op>from, skip op<from, stop before op>=to; after first match any null stops; no additions from a whole batch stops; else increment batch and read again. Disposal clears in-memory batches/timer, not persisted cache. DocumentService clean dispose flushes then disposes; dispose(error) removes all file entries then disposes, without flushing. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/opsCaching.ts:58-81`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/opsCaching.ts:139-199`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentService.ts:303-315`.

## Invariants and asserts

0x09f positive refs before release, 0x0a0 refs zero on deletion timeout, 0x220 key unique, 0x0a1 map identity, 0x412 no users after synchronous disconnect; 0x413/414/415 active socket request/flush/init; 0x272 nonempty get_ops; 0x416/417 close reentrancy/completion, 0x0a2 disconnect reentrancy. Explicit socket epoch validation rejects missing epoch (0x584). Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:94-210`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:444-557`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:831-879`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/epochTracker.ts:234-241`.

## JS-semantics hazards

A single raw WebSocket is not the Socket.IO protocol and does not supply its named-event/ack framing. Preserve synchronous disconnect reentrancy, deferred resolution order, and listener removal before notifying consumers. Sparse array JSON holes become null; arrays cannot be compacted. Both discovery and ops callbacks can arrive after reconnect; nonce/client ID filtering is mandatory. Labels timestamp equality is ignored, not latest-arrival-wins. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:169-210`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:584-657`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/opsCaching.ts:147-166`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDelayLoadedDeltaStream.ts:508-521`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/socketTests/socketTests.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/socketTests/deltaConnectionUpdateTests.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/joinSessionPeriodicCall.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/joinSessionCacheTests.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/vroom.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/opsCaching.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/deltaStorageService.spec.ts:1`.

## Open questions

None.
