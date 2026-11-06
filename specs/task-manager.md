# task-manager (3.11.0)

## Role

Sequenced per-task FIFO lock queues. Quorum membership removes stale volunteers; optional subscriptions re-volunteer across disconnect. This is assignment coordination, not persisted user task content. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:87-128`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:218-250`.

## Surface used by other packages

`TaskManager` factory/kind, `TaskManagerClass`, `ITaskManager`: volunteerForTask→Promise<boolean>, subscribeToTask, abandon, assigned, queued, subscribed, complete, canVolunteer. Events assigned(taskId), lost(taskId), completed(taskId). `reference/fluidframework-3.11.0/packages/dds/task-manager/src/interfaces.ts:15-191`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:308-594`. Type `https://graph.microsoft.com/types/task-manager`, snapshot version `0.1`. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManagerFactory.ts:25-30`.

## Wire and persisted formats

Exactly three op contents; all members required, emitted type then taskId:

```json
{"type":"volunteer","taskId":"render"}
{"type":"abandon","taskId":"render"}
{"type":"complete","taskId":"render"}
```

String taskId is arbitrary; sender is envelope.clientId. Submission allocates monotonic numeric ID starting 0; local metadata is that number. Per-task local array holds `{type,messageId}`, append occurs **after submitLocalMessage**. No queue positions/owners are sent in content. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:37-60`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:253-305`.

Exactly one `header` blob, plain JSON array of [taskId,clientIdQueue] pairs, e.g. `[["render",["c1","c2"]],["upload",["c3"]]]`; empty `[]`. Preserve task Map insertion order and FIFO client arrays; omit tasks with empty queues. No blob splitting or alternate format. Before collecting content, summary removes `placeholder` from all queues if current clientId is placeholder; otherwise replaces placeholder with runtime.clientId, removing placeholder when the real ID already occurs. These operations mutate state and removal can emit queue/lost events. Load inserts pairs, then scrubs every client not currently in quorum; it does not restore local pending records/subscriptions. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:602-630`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:756-823`.

## Behavior

### State and queue transitions

1. Maintain taskQueues Map, latestPendingOps Map of per-task FIFO arrays, subscribedTasks Set, next ID 0. Current client is runtime.clientId or literal `placeholder`. Detached test is **runtime.attachState === Detached**, not inverse of isAttached (Attaching differs). `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:96-128`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:829-852`.
2. queuedOptimistically is `(queue includes own ID && latest pending type is neither abandon nor complete) || latest pending type is volunteer`. assigned/queued ignore pending operations and test actual queue, but return false if attached and disconnected. assigned requires own ID at index 0. canVolunteer returns connected only; it doesn't test permissions. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:548-594`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:829-842`.
3. Add client only if in quorum OR own clientId is placeholder. Create missing queue, suppress duplicate ID, capture old head, push, compare new head, emit internal queueChange only when head changes. Remove client: missing queue no-op; old head forcibly placeholder if removing placeholder, otherwise current head; splice ID if present, delete empty task, compare head and emit internal queueChange on difference. Even absent placeholder removal can generate queueChange because of forced old head. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:727-781`.
4. Internal queueChange listener registered in constructor: old head placeholder → public lost(taskId), return. Otherwise old≠own && new=own → assigned; old=own && new≠own → lost; no other public event. This listener runs before listeners installed by volunteerForTask. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:222-237`.
5. Process op-envelope members in order. Local volunteer/abandon/complete first retrieve pending array, shift and validate ID/type, delete pending Map entry if empty. Volunteer then adds sender. Local abandon emits internal abandon(taskId,ID) **before** removing sender. Complete (any sender) deletes entire task queue, emits internal completed(taskId,localID-or-undefined), then public completed(taskId). Complete does not emit lost or validate sender ownership. Remote volunteer/abandon apply queue changes directly. Unknown op throws Unknown operation. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:152-215`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:669-725`.

### One-shot volunteer

1. If optimistically queued AND assigned, resolve true immediately (before read-only check). Readonly=true throws either Attempted to volunteer with read-only permissions when permissions=true, otherwise Attempted to volunteer in read-only state. Detached adds own ID and resolves true. Otherwise disconnected throws Attempted to volunteer in disconnected state. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:308-332`.
2. Install listeners capturing current nextPendingMessageId before submitting: queueChange for matching task resolves true iff assigned(); abandon for matching task rejects Abandoned before acquiring task assignment except when provided messageId ≤ captured ID; completed resolves false with same old-ID filter; rollback resolves false for matching task; disconnect calls abandon(taskId), removes listeners and rejects Disconnected before acquiring task assignment. Settlement removes all five listeners. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:335-409`.
3. Submit volunteer only if not queuedOptimistically; otherwise wait using same listeners. No optimistic assigned event/queue mutation for attached volunteering. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:411-415`.

### Subscription, abandon, complete

1. subscribeToTask returns if already subscribed. Throws only for readonly && permissions; transient readonly alone doesn't reject. Install abandon, disconnect, complete and rollback listeners; track volunteer message ID and abandoned flag. Matching abandon/complete ignore numeric message IDs ≤ that volunteer ID when both defined; otherwise remove listeners, remove subscribed Set member, set abandoned=true. Matching rollback does the same without ID filter. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:418-504`.
2. Subscription's disconnect listener submits a fresh volunteer if not queuedOptimistically. Detached subscription immediately adds own ID and installs one-shot attached listener: scrub nonquorum clients first, then submit volunteer if not abandoned. Attached subscription submits if not already optimistic queue member. Finally add subscribedTasks member. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:430-453`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:506-526`.
3. abandon returns if neither optimistic queue member nor subscribed. Detached removes own ID then internal abandon(taskId,undefined). Attached submits abandon then emits internal abandon(taskId,undefined) immediately, ending active subscription/waits before ACK; actual queue/assignment remains until sequence processing (or disconnect). `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:529-546`.
4. complete requires assigned or throws Attempted to mark task as complete while not being assigned. Detached deletes queue, internal completed then public completed. Attached requires connected then submits complete; no immediate mutation/event. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:569-587`.

### Disconnect, quorum, reconnect, rollback, stash

1. Quorum removeMember removes ID from all tasks in Map order. On disconnect internal constructor listener first emits lost for every task held by own ID if attached; then removes own ID from all queues. Queue removal can emit a second lost via queueChange. Other disconnect listeners then run in registration order (one-shot volunteers abandon/reject; subscriptions can submit replacement volunteer). onConnect emits internal connect only. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:218-250`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:636-642`.
2. Scrub on load/attach filters queue entries by quorum.getMember; changed empty queues deleted, others replaced; emit internal queueChange(taskId) **without old/new heads**. Consequently normal assigned/lost listener comparisons see undefined heads rather than deriving them from new state. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:808-823`.
3. ReSubmit validates recognized op/taskId and finds exact metadata ID/type in pending array; removes it. Only volunteer is reissued, and only if remaining last pending type isn't abandon. Fresh volunteer gets fresh ID and appends through standard submitVolunteerOp. Abandon and complete are dropped. Then delete task's pending Map entry if that array is empty (including mutations from fresh append). No public event from this method. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:649-666`.
4. Rollback requires numeric metadata and valid op; pop per-task last pending, assert ID matches, delete empty pending array, emit internal rollback(taskId), settling outstanding volunteer false and ending subscription. Does not restore queue because pending attached ops did not mutate it. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:862-879`.
5. applyStashedOp intentionally does nothing for **all content**: lost assignments and in-memory subscriptions aren't recoverable from stashed operations. didAttach emits internal attached. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:855-883`.

## Invariants and asserts

`0xc3b` valid nonnull op object with string taskId and one of three types. Local volunteer `0xc3c` pending exists, `0xc3d` shifted ID matches, `0x07c` volunteer type; abandon `0xc3e`, `0xc3f`, `0x07e`; complete `0xc40`, `0xc41`, `0x401`. ReSubmit `0xc42` pending task and `0xc43` matching ID/type. Placeholder replacement `0x475` defined runtime.clientId. Rollback `0xc45` numeric metadata, `0xc46` pending exists, `0xc47` last ID matches. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:62-71`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:152-210`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:649-656`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:788-792`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:862-875`.

## JS-semantics hazards

FIFO sequencing is the arbitration rule, not local call time. Task strings (including `__proto__`) are safe Map/tuple keys. Promise resolution schedules continuation rather than immediately reentering public callback code, while EventEmitter listeners run synchronously in registration order. Undefined watcher IDs differ from numeric zero in old-request filters. Summary and quorum scrub are state-mutating. Preserve placeholder handling and detached-vs-attaching distinction. `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:335-415`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:602-630`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/taskManager.ts:727-852`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/dds/task-manager/src/test/taskManager.spec.ts:1-20`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/test/taskManager.rollback.spec.ts:1-20`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/test/taskManager.fuzz.spec.ts:1-20`, `reference/fluidframework-3.11.0/packages/dds/task-manager/src/test/fuzzUtils.ts:1-20` are behavior, rollback and reconnect/quorum fuzz entry points. Differential traces must retain assigned/lost/completed ordering and Promise outcomes, not only final queues.

## Open questions

None.
