# Container-loader: delta delivery and acknowledgements

## 1. Role

DeltaManager tracks queued, observed and processed global sequence numbers independently; routes three queues (inbound ops, inbound signals, outbound batches); fetches missing ops; validates stream integrity. ConnectionManager owns the outbound queue. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:180-224`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:292-294`.)

## 2. Surface used by other packages

`attachOpHandler(MSN,snapshotSN,handler,prefetchType="none",lastProcessedSN=snapshotSN)` installs `{process,processSignal}`. Public counters: initialSequenceNumber=snapshot SN, lastSequenceNumber=processed SN, lastKnownSeqNumber=observed SN, minimumSequenceNumber=last processed MSN, lastMessage=last attempted processing message. Queue interface includes paused,length,idle,pause/resume,peek,toArray,waitTillProcessingDone and push/op/idle/error events. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:244-270`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:587-645`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaQueue.ts:19-110`.)

## 3. Wire and persisted formats

Outgoing message construction order is `contents,metadata,referenceSequenceNumber,type,compression`, then `clientSequenceNumber` is appended by connection manager. contents?:string; metadata?:unknown; refSN:number defaults to last processed SN using nullish coalescing; type:string; compression?:string; CSN:number starts at 1 for each newly submitted connection identity. Undefined properties disappear under JSON.stringify. Examples: proposal `{"contents":"{\"key\":\"theme\",\"value\":\"dark\"}","referenceSequenceNumber":9,"type":"propose","clientSequenceNumber":1}`; heuristic noop `{"referenceSequenceNumber":9,"type":"noop","clientSequenceNumber":2}`; immediate proposal response `{"referenceSequenceNumber":10,"type":"accept","clientSequenceNumber":3}`. The loader does **not** author a null contents field for these two acknowledgements. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:302-345`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionManager.ts:1068-1106`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2373-2387`.)

Outbound queue items are arrays of document messages, not single messages. Runtime prepareSend listeners must provide metadata batch=true on first and batch=false on last of a multiple-message batch; a single message must have metadata.batch undefined. Submit-signal passes a JSON string and optional targetClientId separately to driver. Sequenced messages and raw signal envelopes are defined literally in [protocol](protocol.md). (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:348-381`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionManager.ts:374-380`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2395-2396`.)

## 4. Behavior

### DeltaQueue state machine

State variables: FIFO deque initially empty; pauseCount=1; error undefined; processingPromise undefined. paused means pauseCount!=0; idle means no processingPromise **and** queue empty, not merely paused. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaQueue.ts:23-63`.)

- push: append → emit push(task) → ensureProcessing; exceptions here emit error but are not installed as sticky worker error by this catch. clear removes queued tasks only; peek/toArray preserve FIFO.
- pause: increment synchronously, then await current processingPromise (or resolved zero count/duration). It does not interrupt the current worker.
- resume: assert pauseCount>0 (0x0f4), decrement, ensureProcessing. Nested pauses require matching resumes.
- ensureProcessing: iff queue nonempty, pauseCount==0, no sticky error, and no existing processingPromise, schedule resolved-promise continuation. Assert promise exists before/after processDeltas (0x37f/0x380). In that same continuation clear processingPromise **before returning**, never in finally. Creation asserts processing is async (0x381).
- processDeltas: start monotonic time; while runnable shift item, increment count, synchronously worker(item), emit op(item). Reentrant pushes join this same drain; a reentrant pause stops the next iteration. When deque empty emit idle(count,duration); return result even if paused with remaining items (no idle then).
- worker/event exception inside drain: the rejected drain continuation schedules the chained catch in a later promise microtask; catch sets sticky error, clears processingPromise, emits error and resolves processingPromise as `{count:0,duration:0}`. Further processing cannot resume while sticky error remains. Queue.dispose throws `Not implemented.` before setting disposed.

(`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaQueue.ts:73-176`.)

An `idle` listener runs while processingPromise still exists. If it reentrantly pushes an item, ensureProcessing sees the old promise and does not schedule a second drain; after idle returns, the original continuation clears the promise without rechecking the deque. That item waits for another push/resume to kick processing. Preserve this edge behavior rather than silently fixing it in the port. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaQueue.ts:93-100`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaQueue.ts:118-142`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaQueue.ts:172-175`.)

### Initialization and queue ownership

Construct inbound worker=processInboundMessage; error wraps unrecognized error as DataProcessingError with codepath `deltaManagerInboundErrorHandler` and lastMessage, then close. Signal worker requires handler else throws; creates a spread-copy with content=JSON.parse(message.content) then handler.processSignal; signal errors normalize and close. Outbound worker synchronously calls connection.submit(batch), throwing `Attempted to submit an outbound message without connection` if no socket; its error listener normalizes and closes. All queues start paused. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionManager.ts:374-385`.) Container adds another pause to both inbound queues before loading. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:475-509`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2058-2062`.)

attachOpHandler executes: assign initial snapshot SN, processed SN, MSN, queued SN=processed SN, observed SN=processed SN; assert no old handler 0x0e2; set handler, assert truthy 0x0e3; assert no fetch 0x268; if closed return; resume inbound then signals, removing **only** delta manager's initial pause. If prefetch!=none await fetchMissingDeltasCore with cacheOnly=(cached); after cached fetch launch unbounded non-cache PostDocumentOpen fetch without waiting. Finally assert fetch in progress or pending empty (0x269). Pending socket ops are incorporated through fetch finalization/processPendingOps; a later connection checkpoint can advance observed SN again. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:594-644`.)

### Enqueue, gaps, duplicates and fetch

Use Q=lastQueuedSequenceNumber, O=lastObservedSeqNumber, P=lastProcessedSequenceNumber. `previouslyProcessedMessage` is actually the **last queued** message, not necessarily applied yet. Before handler installation append all input to pending and return without fetching or advancing counters. With handler require pending empty OR fetch in progress (0x1e9), empty input returns. Diagnostics count duplicate/gap ranges; allowGaps suppresses gap telemetry, not gap recovery. Advance O to max(O,input's **last** SN), assert previous message absent or SN==Q (0x0ec). Iterate input in given order:

1. SN<=Q: skip. Only if SN equals previouslyProcessedMessage.SN, compare the string `clientId-type-minimumSequenceNumber-referenceSequenceNumber-timestamp` of both messages. Different strings close with NonRetryableError, type DriverErrorTypes.fileOverwrittenInStorage; contents, CSN and serverMetadata are **not** compared. Timestamp **is** compared despite the surrounding comment's caveat.
2. SN==Q+1: validate per-client increasing CSN; set Q=SN; set previouslyProcessedMessage=message; inbound.push(message).
3. SN>Q+1: append pending; request fetchMissingDeltas(reason,to=SN), where to is exclusive (the held message need not be fetched).

(`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:876-933`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:935-1039`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:1042-1087`.)

Per-client enqueue validation: on leave parse `data` and delete leaving ID's history first; null-sender returns. Otherwise if previous sender message exists and new CSN<=old CSN, close with DataCorruptionError created at `DeltaManager.validateClientSequenceNumberConsistency`; then update sender's last-observed entry. Gaps are allowed for other clients for old-file compatibility; strict monotonicity is not contiguity. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:891-933`.)

FetchMissingDeltasCore returns immediately if fetch already active or closed. Without handler assert Q==0 (0x26b) and return. Otherwise from=Q+1; if previous message exists assert its SN==Q (0x0f2), from>1 (0x0f3), then **decrement from by one to deliberately refetch Q**. Set fetchReason=`reason_fetch`; getDeltas(from inclusive,to exclusive,cacheOnly), forwarding batches into enqueue after refreshing delay state. Failure logs GetDeltas_Exception and closes normalized error. Finally refresh delay, clear fetchReason, processPendingOps(reason). (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:1192-1260`.)

getDeltas requires document service, lazily connects to delta storage. For bounded range, after that await, if Q>=to-1 return without issuing fetch. Install inbound.push cancellation listener: non-fetch-origin op cancels when SN>=to-1 (bounded) or SN>=current O (unbounded); fetch's own pushes never cancel it. Assert pushed SN==Q (0x23a). Link close abort, then read fetchMessages(from,to,signal,cacheOnly,reason) until done, setting opsFromFetch true only around synchronous callback. Finally remove push listener and assert !opsFromFetch (0x289); close abort's onabort property must initially be null (0x1e8). (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:672-778`.)

processPendingOps returns if closed, asserts handler 0x26c, stable numeric-sorts pending by SN, replaces pending with [], enqueues sorted with allowGaps=true and reason `reason_pending`. If no fetch remains and Q<O, launch OpsBehind fetch. Stable duplicate order matters because only the first copy enters inbound. Fetch close clears pending so this cannot loop forever on closed container. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:1266-1302`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:828-840`.)

The two enqueue-time corruption checks call close rather than throw. In the decreasing-CSN case the function still assigns the sender-history entry; the caller still advances Q and pushes that message after close cleared/paused the inbound queue. A duplicate-payload mismatch likewise does not break the input loop. Closed state prevents subsequent application; do not interpret these paths as successful processing or add a different visible thrown error. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:919-932`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:1042-1081`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:828-840`.)

### Apply validation: exact order and failures

1. Start Date.now; assert !currentlyProcessingOps (0x3af), set true; assign lastProcessedMessage.
2. Assert clientId===null OR typeof string (0x41a). Classify client types as op/propose/reject/noop/accept/summarize. Null sender on those except noop throws DataCorruptionError `Mismatch in clientId`. Legacy attach/chunkedOp are not in this classification, so bypass that rejection.
3. If sender equals current connectionManager.clientId and that ID defined: noop decrements noOpCount; compute gap=CSN-lastClientSequenceNumber-1; subtract gap from noOpCount; negative throws plain Error `gap in client sequence number: G`; set lastClientSequenceNumber=CSN. This allows omitted/coalesced noops only up to the counted debt.
4. connectionManager.beforeProcessingIncomingOp runs before MSN/global-SN validation (including own-leave reconnect side effects).
5. Old MSN>new MSN throws DataProcessingError `Invalid MinimumSequenceNumber from service - document may have been restored to previous state`, codepath DeltaManager.processInboundMessage.
6. diff=SN-MSN; diff<0 OR diff==0 with non-null sender throws DataCorruptionError `MSN has to be lower than sequence #`. Assign MSN.
7. Require SN==P+1 else DataCorruptionError `Found a non-Sequential sequenceNumber`. Set P=SN. Assert P<=O (0x267).
8. Missing handler throws `Attempted to process an inbound message without a handler attached`. Call handler.process; clear currentlyProcessingOps; emit manager op(message,Date.now-start). Failure does not execute the success tail or clear currentlyProcessingOps; error closes instead.

(`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:1090-1186`.)

### Connect, submit, disconnect and terminal cleanup

On transport connect refresh delay; store checkpoint; max into observed when present; assert messageBuffer empty 0x0e9; reset opsSize and noOpCount (not lastClientSequenceNumber here); emit connect(details,checkpoint absent ? undefined : O-P). Then fetch if checkpoint>Q; without checkpoint fetch for read mode, but write mode waits for own join as gap signal. `connect(args)` first fetches unless fetchOpsFromStorage=false, then starts connection manager. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:520-567`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:647-669`.)

submit creates partial message; nonbatch flushes existing buffer first; prepareMessageToSend failure returns -1. Assert client-message type 0x419; add contents.length (UTF-16 units) to opsSize if present; append message; noop increments noOpCount; emit submitOp; nonbatch flush again; return CSN. flush no-op for empty buffer, otherwise detach it before prepareSend; validate batch markers (0x3c9/0x3ca/0x3cb), sendMessages, assert new buffer empty 0x3cc. Disconnect clears messageBuffer then emits disconnect(reason.text,reason.error); it does not clear inbound. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:302-381`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:850-853`.)

close is idempotent: set closed → connectionManager.dispose(error,true) (disconnect then readonly notification) → abort fetch, clear inbound/signal, pause each, clear pending → emit closed. dispose independently idempotent: reject non-Fluid error via UsageError, set disposed and closed, CM.dispose(error,false), clear queues, emit disposed, remove all listeners. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:789-840`.)

### Noop heuristic

Only type `op` is a runtime message. Defaults time=2000ms, count=50. Infinity disables time timer. On runtime processed increment debt; exactly reaching count threshold queues one microtask. At microtask if debt>=threshold emit wantsNoop synchronously and assert debt==0 afterward (0x243). A whole synchronous queue drain may overshoot many multiples but sends once at its end; another sent message may cancel debt before the microtask. If debt==1 restart timer to full duration; assert timer running (0x242). Timer expiry emits wantsNoop iff debt!=0. Any sent message and disconnect set debt=0; timer is allowed to expire, not cleared. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/noopHeuristic.ts:12-13`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/noopHeuristic.ts:42-106`, `reference/fluidframework-3.11.0/packages/loader/driver-utils/src/messageRecognition.ts:18-19`.)

Container creates the heuristic lazily on first processed op while state Connected and mode write, using first connection's service settings for its whole lifetime. wantsNoop requires activeConnection (0x241) and submits noop with omitted contents. After notifyMessageProcessed, immediateNoOp from protocol submits **accept**, not noop. Every Container.submitMessage only succeeds in Connected; before manager submission it resets heuristic debt. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2328-2341`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2358-2388`.)

The heuristic constructor also requires serviceConfiguration for an active connection (0x2e4); undefined frequencies invoke JS default parameter values, but explicit 0 is retained. It counts own and remote runtime ops equally. It never counts proposal/accept/system messages. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/container.ts:2365-2372`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/noopHeuristic.ts:42-75`.)

### CatchUpMonitor

Construction captures fixed target=lastKnownSeqNumber, asserts target>=lastSequenceNumber (0x37c), registers manager op listener, but performs no synchronous evaluation. Owner stores reference then calls start(), which evaluates current processed SN. First SN>=target marks caughtUp=true before calling listener; subsequent ops silent. Dispose idempotently marks disposed and removes listener. Do not move start into constructor: the listener can disconnect reentrantly and must find/clear the stored monitor. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/catchUpMonitor.ts:31-92`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/connectionStateHandler.ts:279-290`.)

## 5. Invariants and asserts

All processing and fetch codes are listed beside their exact predicates above. Additional manager getter guard: hasCheckpointSequenceNumber requires active transport (0x0df); logConnectionIssue requires connected transport (0x238). Throttling tracks per-source IDs; delay emits only if delayMs>0 and Date.now()+delay exceeds recorded deadline, as ThrottlingWarning with retryAfterSeconds=delayMs/1000; clearing final ID resets deadline to zero. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:276-279`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:399-400`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:843-873`.)

## 6. JS-semantics hazards

Queue drain begins on a promise continuation and runs synchronously to pause/empty/error. A Swift Task per item or asynchronous event emitter changes batch/noop timing. Clear processingPromise in the drain's continuation, not a later cleanup continuation. Use stable numeric sorting and retain message identity: protocol mutates proposal contents and processedOps stores the same message object. (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaQueue.ts:118-176`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/deltaManager.ts:1273-1277`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/protocol/protocol.ts:129-130`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/serializedStateManager.ts:247-250`.)

## 7. Test assets to reuse

Existing deltaManager tests encode noop debt/gaps, readonly notifications, fetch abort reason propagation and per-client increasing CSN (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/test/deltaManager.spec.ts:338-461`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/test/deltaManager.spec.ts:462-647`). CatchUpMonitor tests cover incoherent counters, target fixed at construction, explicit start, one-shot and dispose (`reference/fluidframework-3.11.0/packages/loader/container-loader/src/test/catchUpMonitor.spec.ts:58-135`). Add queue-level differential traces for nested pauses, worker reentrant push, idle reentrant push, and thrown listener microtask ordering; add storage/stream race and refetched prior-op timestamp mismatch using the algorithms above.

## 8. Open questions

None.
