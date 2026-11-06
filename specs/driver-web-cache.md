# @fluidframework/driver-web-cache (3.11.0)

## Role

FluidCache implements host-provided IPersistedCache over browser IndexedDB. It stores opaque structured-clone values with partition/creation metadata, performs bounded-age reads and best-effort deletion, and exposes atomic conditional update. This is not the ODSP epoch wrapper; envelopes stored inside cachedObject belong to the driver. Sources: `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:43-88`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:264-363`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:428-541`.

## Surface used by other packages

`FluidCache(config)`, `.get(entry)`, `.put(entry,value)`, `.removeEntries(file)`, `.removeEntry(entry)`, `.update(entry,updater)->Promise<boolean>`; `FluidCacheConfig={partitionKey:string|null,logger?:ITelemetryBaseLogger,maxCacheItemAge:number,closeDbAfterMs?:number}`; `deleteFluidCacheIndexDbInstance(callbacks?)`. Sources: `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:43-88`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:219-264`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:332-363`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:428-541`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCacheIndexedDb.ts:77-80`.

## Wire and persisted formats

No network format. Database name `fluidDriverCache`, IndexedDB version **3**, object store `driverStorage.V3` with out-of-line string key. Key `${docId}${fileVersion===undefined?"":"_"+fileVersion}_${entry.type}_${entry.key}`. Thus version empty string is a real extra underscore. Indices created (order): createdTimeMs, lastAccessTimeMs, partitionKey, fileId. Row emitted in order:

```text
{cachedObject:opaqueStructuredCloneValue,fileId:entry.file.docId,type:entry.type,
 cacheItemId:entry.key,partitionKey:configuredStringOrNull,
 createdTimeMs:Date.now(),lastAccessTimeMs:sameNow}
```

Concrete entry `{file:{docId:"D",fileVersion:"v",resolvedUrl:...},type:"snapshot",key:""}` gives key `D_v_snapshot_`, row `{"cachedObject":{"version":3,"fluidEpoch":"E","value":{}},"fileId":"D","type":"snapshot","cacheItemId":"","partitionKey":"user","createdTimeMs":1000,"lastAccessTimeMs":1000}`. Opaque values may include Maps/ArrayBuffers; example uses empty object only for readability, not JSON-only constraints. Sources: `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCacheIndexedDb.ts:13-59`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCacheIndexedDb.ts:86-143`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:332-351`, `reference/fluidframework-3.11.0/packages/loader/driver-utils/src/cacheUtils.ts:24-27`.

Upgrade oldVersion 1 attempts deleting `diverStorage`, 2→`diverStorage.V2` (intentional misspellings), catches/logs deletion error and still creates V3. Older store values are **not migrated/read**. Blocked open rejects `Could not open DB since it is blocked by an older client that has the DB open`. Sources: `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCacheIndexedDb.ts:19-67`.

## Behavior

### Initialization and maintenance

Set partitionKey exactly supplied; if maxCacheItemAge>432000000 log maxCacheItemAgeTooLarge but do not throw; effective age=Math.min(configured,432000000). closeDbAfterMs defaults0; >0 selects reuse, otherwise immediate close. Schedule two idle tasks: optional navigator.storage.estimate telemetry, then open standalone DB, get createdTimeMs index keys <=Date.now−effectiveAge, delete all concurrently in readwrite transaction, await transaction.done, always close; failures log FluidCacheDeleteOldEntriesError. Cleanup is across **all partitions**. Source: `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:88-170`; maximum `reference/fluidframework-3.11.0/packages/loader/driver-utils/src/cacheUtils.ts:16`.

### DB lifetime transitions

Immediate mode open→return new DB, operation closes via closeDb. Reuse mode starts db undefined/reuseCount−1; await open; if still no db adopt and reset reuseCount−1, else another opener won: close redundant connection, increment count and return winner. First adoption installs versionchange handler (close, clear db/timer) and close event handler (clear timer/db); assert no timer, schedule single close at closeDbAfterMs. Subsequent accesses increment reuseCount but **do not extend timer**. Timer closes and clears. Sources: `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:173-217`.

### Read/write/delete transitions

getItemFromCache computes key→opens→reads row. Missing row→undefined; partition mismatch (strict equality) logs FluidCachePartitionKeyMismatch→undefined; age `Date.now()-createdTimeMs > maxCacheItemAge`→undefined; else closes and returns row plus dbOpenPerf. Does **not** update lastAccessTimeMs or delete expired row. Catch logs FluidCacheGetError→undefined; get emits FluidCacheAccess then returns cachedObject, not row. Exact-age equality is a hit (maintenance's <= cleanup boundary differs). Sources: `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:264-329`.

put opens DB, obtains single now, unconditional put row/key (overwrites cross-partition row), closes; all errors swallowed/logged FluidCachePutError and finally close. removeEntry deletes computed key with no partition check; removeEntries selects **fileId index by docId only**, deletes all matching keys, awaits transaction.done (includes other versions/partitions), swallows/logs failures. Source: `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:219-262`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:332-363`.

### Atomic update state machine

**Opened→Read**: one readwrite transaction, read key. Visible iff existing.partitionKey===configured and Date.now−createdTimeMs<=maxAge, else pass undefined. **Read→Callback**: invoke synchronous updater(existingValue,set); set captures last value and called flag; late call after return throws UsageError. Set(undefined) is distinguishable from no set. **Callback→Abort** if throws or returns thenable: mark returned, transaction.abort, await done rejection swallowed, log FluidCacheUpdateCallbackError, return false preserving old row even if set happened. **Callback→NoWrite** if no set: await transaction.done→false, no telemetry. **Callback→Commit** if set: undefined→delete key; otherwise fresh metadata row as put; await transaction.done→true. Any open/read/write failure logs FluidCachePutError→false; finally close. Hidden stale/foreign partition row can be overwritten/deleted after updater saw undefined. Sources: `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:428-541`.

Idle scheduler has module-global queue and scheduled flag. enqueue task→ensureIdleCallback(2000); requestIdleCallback if supported **without timeout options**. Fallback computes deadline=Date.now+50 **before scheduling**, setTimeout(timeout), callback timeRemaining=max(deadline−Date.now,0). Run sequential tasks only while timeRemaining>10; retain remaining queue, reset scheduled flag, reschedule with default timeout0 if nonempty. Async functions are invoked without awaiting, so idle budget measures invocation not asynchronous work. Sources: `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/scheduleIdleTask.ts:11-98`.

## Invariants and asserts

0x6c6 no DB-close timer before adoption; 0x6c7 DB must exist before reuse return. maxAge upper-bound violation logs instead of throws; no lower-bound or NaN validation. Late update set throws `FluidCache.update: set called after updater returned`; thenable updater rejected as `FluidCache.update: updater must be synchronous (returned a thenable)`. Sources: `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:88-115`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:201-209`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:458-499`.

## JS-semantics hazards

Structured clone is not JSON: retain Map, typed buffers, undefined semantics. null partition is deliberate no partition, not missing; partition is **not included in primary key**, only checked on reads. Reads never refresh age. Update atomicity cannot be replaced by separate read/await/write; native store needs an actual transaction and synchronous callback boundary. set(undefined) deletes, no-set leaves row. Fallback idle deadline can already be exhausted after 2000ms scheduling; do not mistake it for 50ms *after* callback begins. Sources: `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:298-319`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/FluidCache.ts:428-541`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/scheduleIdleTask.ts:30-48`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/test/FluidCache.test.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/test/FluidCacheTimer.test.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/driver-web-cache/src/test/FluidCacheIndexedDb.test.ts:1`. Include creation-age equality versus cleanup boundary, partitions colliding on same key, transactional race/throw/thenable/late-set, set(undefined), concurrent open adoption, and expiration of fixed—not sliding—DB timer.

## Open questions

None. Native storage technology is a Swift implementation choice; the transaction, key, visibility and opaque-value contracts above are fixed.
