# core-utils — 3.11.0

## 1. Role

Synchronous collection/assertion primitives and asynchronous I/O-edge scheduling used by loader, runtime and DDS code. These are behavioral dependencies, not substitute implementations of the JS standard library. This spec covers the exported runtime primitives; type-only mapped utilities have no execution or wire behavior. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/index.ts:6-41`)

## 2. Surface used by other packages

`assert`, `fail`, debug assertion configuration and first-chance hooks; `Deferred`; `Lazy`/`LazyPromise`; `Heap`, `IComparer`, `NumberComparer`; `Timer`, `PromiseTimer`, `setLongTimeout`; `PromiseCache`; `DoublyLinkedList`, `walkList`, `iterateListValuesWhile`; `compareArrays`, `transformMapValues`, `shallowCloneObject`, `clamp`, `delay`, `isObject`, `isPromiseLike`, `unreachableCase`, `oob`, `validateAllOrNone`. Their exact execution contracts follow below. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/index.ts:6-41`)

## 3. Wire and persisted formats

None. No utility serializes a document. `PromiseTimer` resolves an in-memory tagged object, literally `{timerResult:"timeout"}` or `{timerResult:"cancel"}`, one string property in that order; these are not summary versions. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/timer.ts:238-295`)

## 4. Behavior

### Assertions and diagnostics

1. `assert(condition,message,debugMessageBuilder?)` returns immediately for a truthy condition. On false, call the common failure path. `fail` always calls it.
2. Convert a numeric message to lowercase hexadecimal with `0x` prefix and minimum three digits, not fixed width: `10` becomes `0x00a`, `0x1234` remains `0x1234`. String messages pass through.
3. In non-production code, evaluate the optional builder and append `\nDebug Message: <result>`, then log `Bug in Fluid Framework: Failed Assertion: <message>`.
4. Construct `Error(messageString)`, invoke first-chance handlers synchronously in Set insertion order, then throw that same error. A handler throwing interrupts this sequence and its exception escapes instead.
5. `onAssertionFailure` wraps each registration in a fresh closure, so registering the same function twice produces two callbacks. Its returned unregister closure removes only that registration. Iteration is over the live Set, not a snapshot. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/assert.ts:29-145`)

`appendDebugMessage(message,builder)` appends one space and builder output only through the non-production conditional. `prefixPredicate(prefix,true)` returns true; otherwise it calls `.toString()` and returns `prefix + ": " + result`. `debugAssert` executes its predicate only when non-production conditionals are included and debug assertions are enabled (initially true); anything other than literal true triggers debugger, constructs `Error("Debug assert failed: " + result.toString())`, calls assertion handlers, throws. `configureDebugAsserts` returns the previous enabled flag. Production emulation is a nesting count; enable increments, disable decrements, and a negative count asserts. `skipInProduction` runs its callback only when count is zero and the bundler has not stripped the annotated callback invocation. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/assert.ts:86-101`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/assert.ts:162-357`)

### Deferred and lazy evaluation

`Deferred` constructs exactly one Promise, capturing its resolve/reject functions synchronously in the executor. `promise` always returns that object. `resolve(value)` sets `completed=true` before calling the captured resolve, including when value is a still-pending thenable; `reject(error)` similarly sets the flag first. Neither clears the functions. Repeated calls still reach Promise resolve/reject, whose first-settlement/adoption rules decide the result; completion is not proof of successful fulfillment. Promise reactions run later as microtasks. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/promises.ts:10-63`)

`Lazy.value`: if not evaluated, set evaluated **before** invoking the generator, then store its result. Return the stored result. If generation throws, evaluated stays true and subsequent reads return undefined rather than retrying; recursive reads during generation likewise observe undefined. An undefined result is cached normally because evaluated is separate from value. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/lazy.ts:10-37`)

`LazyPromise` does not execute at construction. First `then`, `catch`, or `finally` calls async `getPromise`; if result is undefined, call execute and assign its Promise. Subsequent calls reuse that result; each public async method itself returns an adopting wrapper Promise. A synchronously throwing execute never assigns result, so a later call retries; a returned rejecting Promise is retained. Forward all supplied arguments to the underlying Promise method; finally preserves result/rejection unless its callback fails. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/lazy.ts:46-90`)

### Binary heap

Storage starts with a sentinel node `{value:comp.min,position:0}`. Real nodes begin at 1. `count=L.length-1`; `peek=L[1]`, undefined if empty. `add(x)` creates one mutable-position node at the array end, pushes, then fixes upward while parent compares greater than child. Equal elements do not swap upward. Every swap updates both nodes' positions. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/heap.ts:54-102`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/heap.ts:139-180`)

`get`: checks **L.length===0**, then swaps root with `count`, pops, fixes downward, and returns popped value. The initialized empty heap has length 1, so calling get on it reaches an invalid swap and throws; do not silently turn this into a normal empty pop. `update(node)` fixes up when parent is greater, otherwise down. `remove(node)` swaps with last, splices last, and updates the moved node unless the removed position is now the array length. Removed nodes retain their last position; no membership validation exists. Downward repair chooses right child only when left compares greater than right (ties choose left), stops when parent <= chosen child, otherwise swaps and repeats. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/heap.ts:79-180`)

`NumberComparer.compare(a,b)=a-b`; its sentinel is **Number.MIN_VALUE**, the smallest positive subnormal (5e-324), not negative infinity. The parent check protects index 0 by requiring k>1; sentinel is not compared in ordinary upward repair. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/heap.ts:28-38`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/heap.ts:153-156`)

### Timers

`setLongTimeout(fn,ms,setId?)`: when ms>2147483647, schedule a timeout of 2147483647 whose callback recursively schedules ms-2147483647; otherwise schedule fn at max(ms,0). Invoke setId with every newly allocated ID, including recursive chunks, then return the current ID. Clearing only the original ID after a chunk fired cannot cancel a later chunk. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/timer.ts:63-95`)

`Timer.start(ms=defaultTimeout,handler=defaultHandler)` clears the previous timer, records Date.now as startTick, duration/intendedDuration=ms, handler, and the long-timeout ID. `hasTimer` tests presence of runningState. `clear` cancels current timeout then removes state; repeated clear does nothing. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/timer.ts:104-141`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/timer.ts:184-201`)

`restart(ms?,handler?)`:

1. If no running state, call start with supplied/default arguments.
2. Otherwise choose duration=ms ?? running.intendedDuration; choose handler=argument ?? pendingRestart.handler ?? running.handler. Compute remaining=running.duration-(Date.now()-running.startTick), ignoring a previously pending restart for this comparison.
3. If duration<remaining, call start(duration,chosenHandler), replacing the timeout immediately.
4. If equal, replace running.handler, clear pending restart, set intendedDuration=duration, retaining timer/start tick.
5. If greater, retain the current timeout but overwrite pending restart with `{startTick:Date.now(),duration,handler}`. This branch does not immediately change intendedDuration.
6. At timeout firing, assert running state. If a restart is pending, calculate its remaining duration and startCore(remaining,wrapperCallingRestartHandler,restart.duration); negative remaining becomes zero through setLongTimeout. Otherwise capture handler, clear state **before** calling it, catch its exception and pass it to exceptionHandler if supplied, else rethrow. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/timer.ts:153-232`)

`PromiseTimer.start` first clear/cancels any previous pending result, allocates a new Deferred, starts the wrapped handler and returns its Promise through an async method. `clear`: clear timer, resolve current deferred with cancel, clear deferred. Timeout: Timer has already cleared running state; call user handler **first**, assert deferred still exists, resolve timeout, clear deferred. If user handler throws, the promise is not resolved. If user handler reenters clear/start it can cancel the original and make the following assertion fail or target the replacement deferred; preserve ordering, do not resolve timeout before callback. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/timer.ts:263-295`)

### PromiseCache

Default expiry is indefinite, default removeOnError always true. `has` does not refresh expiry. `get` refreshes only sliding expiry: cancel its ID then schedule new durationMs; absolute expiry starts at insertion, not fulfillment. `remove` cancels GC then deletes entry, returning boolean. Expiry callback removes the key and cancels its GC bookkeeping. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/promiseCache.ts:13-136`)

`addOrGet`: get existing promise (refreshing sliding expiry). If absent, call an async wrapper around asyncFn so synchronous throws become rejected promises; store promise immediately; attach a catch which calls remove(key) iff removeOnError(error); schedule expiry; return/adopt promise. There is **no identity check** in that catch: an old rejected operation can remove a newer value inserted under the same key after expiry/removal. `add` records prior presence, calls addOrGet with rejection swallowed on the returned wrapper, returns !priorPresence; it still refreshes sliding expiry on an existing key. `addValueOrGet`/`addValue` use async functions returning the provided value. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/promiseCache.ts:145-204`)

### Linked list and small helpers

`DoublyLinkedList` uses a circular head sentinel, exposed next/prev omit sentinel as undefined. Nodes carry their owner via headNode. `push`, `unshift`, `insertAfter` increment length by items count then link new nodes in argument order; empty item lists throw `items must not be empty` even from a constructor with an empty iterable. insertAfter rejects a foreign node before changing length. pop/shift remove last/first. Remove of absent/foreign/dead node returns undefined; valid removal relinks neighbors, changes all removed links/owner to DeadHead, decrements count, returns the node. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/list.ts:49-132`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/list.ts:180-287`)

`splice(start,countOrEnd?)` walks forward from start and moves existing nodes (identity preserved) to a fresh list. Stop after moving the specified end node (inclusive) or when moved count equals numeric argument; undefined runs to end. The equality check is after moving, so numeric zero/negative is not an empty-splice fast path. `walkList` validates explicit start membership; caches next/prev **before** visiting current, permitting removal of current; literal false stops and returns false, exhaustion true. Ordinary iterator caches its next before handing current to caller; `map` calls callback before reading node.next. `iterateListValuesWhile` advances next before predicate, returns current.data only for true; a false predicate returns done for that call but leaves the advanced next pointer, so an explicit later next can resume. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/list.ts:139-172`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/list.ts:231-253`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/list.ts:290-410`)

- `compareArrays`: same reference => true without comparator; unequal lengths => false; otherwise left.every(comparator(value,right[index],index)), short-circuit false. Default Object.is: NaN equals itself, -0 differs from +0, objects compare by identity; sparse left holes are skipped. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/compare.ts:16-33`)
- `transformMapValues` snapshots entries, transforms in insertion order, returns new Map with same keys. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/map.ts:14-19`)
- `shallowCloneObject` spreads arrays into new arrays (holes become undefined); objects spread own enumerable properties into plain object; nested values retain identity. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/shallowClone.ts:13-18`)
- `clamp` asserts min<=max then Math.min(Math.max(value,min),max); NaN value propagates. `delay` resolves after a setTimeout task, never inline. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/math.ts:12-15`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/delay.ts:11-12`)
- `isObject` accepts non-null typeof object including arrays, excludes functions. `isPromiseLike` additionally requires a then property (inherited allowed) whose value is a function. `unreachableCase` throws Error(message), default `Unreachable Case`; `oob` throws `Array index is out of bounds`. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/typesGuards.ts:13-24`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/unreachable.ts:22-24`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/oob.ts:15-17`)

`validateAllOrNone(obj,keys)` starts definedCount=0, visits keys in supplied order and counts `obj[key] !== undefined`; returns "none" if zero, else "all" if count===keys.length, else "mixed". Empty keys returns "none", duplicate keys count repeatedly, inherited values count, null/false/0/empty string count as defined. No throws/asserts except those from property accessors. Loader uses this at the driver-wiring boundary to reject partial driver configuration, so omitting it as type-only loses a runtime precondition. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/allOrNone.ts:40-57`, `reference/fluidframework-3.11.0/packages/loader/container-loader/src/createAndLoadContainerUtils.ts:413-425`)

## 5. Invariants and asserts

`clamp`: 0xd18 for inverted or NaN bounds. Timer callback: 0x764 for missing running state. PromiseTimer after callback: 0x765 for missing deferred. These throw ordinary Error through the common assert path; Swift fatalError would prevent caller recovery and first-chance telemetry. configureDebugAsserts asserts 0xab1 if non-production conditionals have been removed or production is being emulated; emulateProductionBuild updates its counter first then asserts 0xc70 if negative (failure leaves the counter negative). (`reference/fluidframework-3.11.0/packages/common/core-utils/src/math.ts:13`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/timer.ts:204`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/timer.ts:292`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/assert.ts:243-250`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/assert.ts:304-309`)

## 6. JS-semantics hazards

Container actor isolation does not replace Promise reaction timing: Deferred completion flag is synchronous, reactions are microtasks. Preserve wall-clock Date.now for Timer restart arithmetic (not a monotonic clock substitution), Set/Map insertion order and object identity, IEEE-754 NaN/signed-zero behavior, and lazy throw poisoning. Heap malformed/empty calls are not checked optionals. Cache public async functions adopt stored promises rather than promising reference identity. No utility emits application events. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/promises.ts:43-61`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/timer.ts:229-232`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/lazy.ts:29-35`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/compare.ts:16-33`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/promiseCache.ts:145-168`)

## 7. Test assets to reuse

Port assertion hook/debug/production cases in `assert.spec.ts`, timer fake-clock restart/cancel cases in `timer.spec.ts`, expiry and rejection cases in `promiseCache.spec.ts`, node-identity/mutation cases in `list.spec.ts`, Object.is comparator cases in `compareArrays.spec.ts`, and numeric range cases in `math.spec.ts`. These are package-local executable fixtures, not wire goldens. (`reference/fluidframework-3.11.0/packages/common/core-utils/src/test/assert.spec.ts:1-40`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/test/timer.spec.ts:1-40`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/test/promiseCache.spec.ts:1-40`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/test/list.spec.ts:1-40`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/test/compareArrays.spec.ts:1-40`, `reference/fluidframework-3.11.0/packages/common/core-utils/src/test/math.spec.ts:1-31`)

## 8. Open questions

None.
