# Review: L1 (28062b6), L2 (b334791), L3 (144b6f7)

Read-only correctness review of the committed versions (`git show <sha>:<path>`), not the working
tree. The oracle is `reference/fluidframework-3.11.0`. Every finding below was checked against the
TS source. Line numbers refer to the file as it stands at the named commit.

Ranked by severity. "Harness gap" says why the current gates do not catch the finding.

---

## 1. High: outbound ops are sent one emit per message, and the send loop is reentrant (L1)

**Swift:** `Sources/FluidContainerLoader/Container.swift:552-558` (`sendMessages`), called from
`catchUp` (`:513`, `:529`) and `withEntryPoint` (`:622`).

**TS:** `loader/container-loader/src/connectionManager.ts:1117` `sendMessages` pushes the batch onto
the `_outbound` DeltaQueue, whose single worker calls `connection.submit(messages)`.
`drivers/driver-base/src/documentDeltaConnection.ts:362-364` then sends the whole batch in **one**
`submitOp` emit.

**Divergence:**

- `for message in messages { try await connection.submit([message]) }` sends a separate `submitOp`
  frame for each message.
- Each `await` is a suspension point on the `Container` actor. While `withEntryPoint` is partway
  through a multi-message flush, the reader task can run `receive(.op)`, which calls
  `catchUp`, `drain`, and `sendMessages`. That path prepares an `accept` or `noop` with a higher
  `clientSequenceNumber` and emits it between the batch's messages.

**Failure scenario:** a flush with two or more messages, for example a chunked large op, an
ungrouped batch, or `accept` plus `noop` from one `drain`, runs while an `op` event arrives. The
wire order then becomes csn 1, 4, 2, 3. TS cannot produce this order: one DeltaQueue worker and one
emit per batch. The server sees a batch split across frames, with another message from the same
client in the middle, so the batch is no longer contiguous and the csn order is broken. This
violates ARCHITECTURE decision 2 ("enqueue in FIFO order onto one ordered transport writer").

**Harness gap:** lockstep peers do not interleave socket events with a flush.

**Fix:**

- Emit each prepared batch as a single `connection.submit(messages)`.
- Route every outbound path (runtime flush, `accept`, `noop`, `summarize`) through one
  non-reentrant FIFO writer, such as a single drain task or an `AsyncStream` consumer, so no other
  send can start while a send is suspended. L6's migration should keep this invariant.

## 2. High: a nack is fatal, with no reconnect (L1)

**Swift:** `Container.swift:310-311` turns `.nack` into a thrown `DriverError`. The reader's catch
(`:178-186`) then records `failure`, calls `connectionFailed()`, and emits `disconnected`.
`ConnectionManager.swift:1-38` has no reconnect, mode switch, or nack handling at all.

**TS:** `connectionManager.ts:1230-1248` `nackHandler`:

- On read-only permissions, it closes with `writeOnReadOnlyDocument`.
- If `getNackReconnectInfo(...).canRetry` is false, it closes.
- Otherwise it calls `reconnectOnError("write", ...)`.

Disconnects and errors also reconnect (`:1250-1258`, `reconnectOnError` at `:993`).

**Failure scenario:** the service nacks with a retryable code, such as 429 throttling or a nack
after a token expiry. TS reconnects and resubmits pending ops. Swift leaves the container
permanently failed: `view()` and `withEntryPoint` throw, and `closed` is never emitted. The same
dead end happens on any transient socket drop. The class is named after `connectionManager.ts` but
covers only one connect, so it collapses the TS behavior and invents a fatal path.

**Harness gap:** the harness scenarios never nack or drop the socket.

**Fix:** port `nackHandler`, `getNackReconnectInfo`, and `reconnectOnError` (with the
read/write mode logic) into `ConnectionManager`, and replay pending ops through the runtime's
`reconnect`. Until that lands, call `close(error)` so the failure is at least observable.

## 3. Medium-high: the loader does not wrap storage in `RetriableDocumentStorageService` (L1)

**Swift:** `Container.swift:199` uses `service.connectToStorage()` directly for `getVersions`,
`getSnapshotTree`/`getSnapshot`, every `readBlob` during load, and `uploadSummaryWithContext`.

**TS:** `loader/container-loader/src/containerStorageAdapter.ts:132-140` always wraps it:

1. `new RetriableDocumentStorageService(storageServiceP, ...)`, which runs every call under
   driver-utils `runWithRetry`.
2. `ProtocolTreeStorageService` around that.

**Failure scenario:** a Routerlicious historian call returns 429 with `retryAfter`, a 503, or an
offline `fetchFailure` (`canRetry: true`). TS waits and retries. Swift fails the load or the
summary upload on the first error. ODSP has its own `RetryErrorsStorageAdapter`, but that retries
only 409 coherency errors and `serviceReadOnly` (`retryUtils.ts`). Generic retryable errors on
ODSP still go unretried, because the loader-level wrapper is missing.

**Fix:** port `RetriableDocumentStorageService`, which is driver-utils `runWithRetry` with its
`canRetryOnError` and `getRetryDelayFromError` backoff. Have the container's storage adapter wrap
the driver storage with it, as TS does.

## 4. Medium: a socket-epoch mismatch does not clear the persisted cache (L2)

**Swift:**

- `Sources/FluidOdspDriver/OdspDelayLoadedDeltaStream.swift:133` and
  `OdspSocketIOFactory.swift:315` call `EpochTracker.validateEpoch`.
- On a mismatch, `EpochTracker.swift:97-112` only bumps `cacheClearCount` and throws. It never
  calls `cacheRemove`.
- The prefetch path in `OdspDocumentStorageManager.swift:226` behaves the same way.
- Only `EpochTracker.fetch(type:)` (`:89-95`), which wraps HTTP calls, removes entries.

**TS:** `epochTracker.ts:234-242`. The public `validateEpoch` catches the mismatch and calls
`checkForEpochError` (`:467-499`), which runs `await this.removeEntries()` before rethrowing.
It is called for the socket in `odspDocumentDeltaConnection.ts:320`
(`validateEpoch(details.epoch, "push")`) and for the prefetch in
`odspDocumentStorageManager.ts:603`.

**Failure scenario:**

1. A file is overwritten (version restore), so its epoch changes.
2. A client loads from the factory's `LocalPersistentCache`. The tracker learns the old epoch from
   the cached entry.
3. The socket handshake returns the new epoch. Swift throws `fileOverwrittenInStorage` but keeps
   the stale snapshot cached.
4. Every reload served from that cache repeats the failure until an HTTP call happens to return
   the new epoch header, or the 5-day expiry passes. TS clears the cache on the first mismatch, so
   the next load goes to the network.

**Fix:** make the mismatch path of `validateEpoch` (or a TS-named async `validateEpoch(_:fetchType:)`)
`await removeEntries()` before throwing, as `checkForEpochError` does. Keep the synchronous core
for `fetchOnce`.

## 5. Medium: `X-CLP-Compliant-App` is never sent on requests (L2)

**Swift:** `Sources/FluidOdspDriver/OdspNetwork.swift:171-189` (`fetchOnce`) adds `X-RequestStats`
and `x-fluid-epoch`, in the header or in the ump body, but never the CLP header. L2 does carry
`isClpCompliantApp` onto the resolved URL:

- `OdspDriverUrlResolver.swift:152`, `:187`, `:228`;
- `CreateFile.swift`, the `X-CLP-Compliant-App` resolve headers.

Nothing reads it.

**TS:** `epochTracker.ts:385-419` `addEpochInRequest` appends
`X-CLP-Compliant-App: true`, after `x-fluid-epoch`, to every tracked request when
`resolvedUrl.isClpCompliantApp` is truthy. It goes in the multipart body for ump calls and in the
headers otherwise. `fetchSnapshot.ts:793-795` adds it to the untracked prefetch request as well.

**Failure scenario:** a host resolves with `X-CLP-Compliant-App: true`, for example a
sensitivity-label-compliant app. SharePoint never sees the flag on trees/latest, joinSession, ops,
blob, or summary upload, so CLP-gated behavior differs from TS.

**Harness gap:** the service fuzz never sets the header, so the byte-compare cannot see it.

**Fix:** in `fetchOnce`, append the line, or set the header, when
`fileEntry.resolvedUrl.isClpCompliantApp == true`, in TS order after `x-fluid-epoch`. Do the same
in `fetchSnapshotCore` when it runs `untracked`. Add a fuzz seed with the header set.

## 6. Medium: ODSP op fetches cannot be cancelled (L2)

**Swift:**

- `Sources/FluidOdspDriver/OdspDeltaStorageWithCache.swift:37-58` starts an unstructured
  `Task { ... }` with no `continuation.onTermination`.
- `Sources/FluidOdspDriver/ParallelRequests.swift:241-263` (`requestOps`) and `:142-145`
  (`addRequest`) do the same.
- `getSingleOpBatch` (`:214-238`) loops `while true` with no cancellation check.

**TS:** `loader/driver-utils/src/parallelRequests.ts:434` (`while (signal?.aborted !== true)`) and
`:617` (faster cancellation) honor the `abortSignal` that the loader passes and cancels.

The Routerlicious port in the same codebase does wire
`continuation.onTermination = { _ in task.cancel() }`
(`FluidRouterliciousDriver/ParallelRequests.swift:249`).

**Failure scenario:** the container closes, or stops iterating, during a bounded catch-up while
offline. `getSingleOpBatch` keeps retrying the retryable `fetchFailure` forever: one request every
8 s, holding the network, epoch tracker, and token fetcher alive. A strong-`to` range that the
service lags on also keeps polling past the consumer's lifetime.

**Fix:** set `continuation.onTermination` to cancel the outer task. Make the inner `requestOps` and
`ParallelRequests` tasks children of it, or cancel them explicitly. Check `Task.isCancelled` in
`getSingleOpBatch`, as the Routerlicious port does.

## 7. Low-medium: the redemption deferral is never completed by a cache hit (L2)

**Swift:** the snapshot cache read bypasses the epoch tracker:

- `OdspDocumentService.swift:67-72` (`cacheRead`) reads `LocalPersistentCache` directly.
- `OdspDocumentStorageManager.swift:190-212` (`readCachedSnapshot`) does the same.

So `EpochTrackerWithRedemption.get` (`EpochTrackerWithRedemption.swift`), the only cache path
that completes `treesLatestDeferral` on a hit, is never used.

**TS:** `epochTracker.ts:553-571`. `get` of a snapshot entry with a value resolves the deferral.
`fetchAndParseAsJSON` (`:585-610`) then rethrows a 401-404 joinSession failure immediately when
`completed`: the file was redeemed in a prior session.

**Failure scenario:** a load is served from the cached snapshot, then joinSession fails with 403,
for example after revoked access. TS fails at once. Swift waits on the deferral for up to 15 s,
until some other HTTP success or the timeout. It then sends a second joinSession: one extra
request and a 15 s stall on a doomed connect.

**Fix:** read the snapshot through the tracker, which matches TS's
`epochTracker.get(createCacheSnapshotKey(...))`. Or have `readCachedSnapshot` complete the
redemption deferral on a hit.

## 8. Low: Routerlicious op-fetch backoff is capped at 8 s for HTTP errors (L1)

**Swift:** `Sources/FluidRouterliciousDriver/ParallelRequests.swift:10` and `:196-198` cap
`waitTime` at `maxReconnectDelayInMs = 8000`. The comment there says R11s errors never carry
`endpointReached`.

**TS:** that premise is false. `routerlicious-driver/src/errorUtils.ts:151`
(`createR11sNetworkError`, used by `restWrapper.ts:277`) sets `endpointReached: true`.
`driver-utils/src/runWithRetry.ts:193-203` then caps at
`MaxReconnectDelayInMsWhenEndpointIsReachable` (60 s).

**Failure scenario:** delta storage answers 429 with `retryAfter: 30`. TS waits 30 s. Swift waits
8 s and re-hits the throttled endpoint about four times as often.

**Fix:** use the 60 s cap when the error came from an HTTP response (`statusCode != nil`), as the
ODSP port's `calculateMaxWaitTime` already does. Better, share one port (see finding 10).

## 9. Low: create-new drops `context` and `appName` from the host's resolved URL (L2)

**Swift:** `Sources/FluidOdspDriver/CreateFile.swift:45-54` copies only `codeHint` (and
`pendingRename`) from the create-new resolved URL.

**TS:** `createFile.ts:115-116` sets `odspResolvedUrl.context = resolvedUrl?.context` and
`odspResolvedUrl.appName = resolvedUrl?.appName` before `codeHint`.

**Failure scenario:** a host puts `context` or `appName` on the create-new request's resolved URL.
After attach, the TS container's resolved URL still carries them. The Swift one loses them, along
with anything downstream that reads them, such as the share-link nav param and host telemetry.

**Fix:** set both keys, in TS order (`context`, `appName`, `codeHint`), with `setting(_:_:)`.

## 10. Low (maintainability): duplicated driver-utils ports with divergent behavior (L1, L2)

Both drivers port the same driver-utils and driver-base code, and the two copies differ:

| What | Copy 1 | Copy 2 |
|---|---|---|
| `ParallelRequests`, `requestOps`, `getSingleOpBatch` | `FluidRouterliciousDriver/ParallelRequests.swift`: class, concurrency 1, cancellable, 8 s cap | `FluidOdspDriver/ParallelRequests.swift`: actor, N workers, not cancellable, statusCode-based cap |
| `validateMessages` | `FluidDriverBase/DriverUtils.swift`: with `strict` | `FluidOdspDriver/ParallelRequests.swift:11`: strict only, `throws` |
| `isCombinedAppAndProtocolSummary` | `FluidContainerLoader/Utils.swift:66` | `FluidOdspDriver/CreateNewUtils.swift:179` |
| JS truthiness helpers | `OdspDriverUrlResolver.swift` `isTruthy` | `RouterliciousDriver/DocumentService.swift` `isTruthy` |

Findings 6 and 8 already come from the drift between the two copies.

Also, `OdspDelayLoadedDeltaStream.swift:93` keeps the pre-L2 `connectToDeltaStream(client:factory:...)`
next to the new contract method at `:119`. It is used only by `FluidOdspNetPeer/main.swift:321`, so
the net-peer harness exercises a path production does not take: no token-refresh retry and no
`getWebsocketToken`.

**Fix:**

- Add a `FluidDriverUtils` target, matching the TS package, holding the single `ParallelRequests`,
  `requestOps`, `runWithRetry`, and summary-for-create-new helpers.
- Delete the legacy `connectToDeltaStream`, and point the net peer at the contract path.

## 11. Low: `IDocumentStorageService` has no `policies` (L1, L2)

**Swift:** `FluidDriverDefinitions/DocumentService.swift:55-64` (the protocol), plus
`RetryErrorsStorageAdapter.swift` and `OdspDocumentStorageService`.

**TS:**

- `retryErrorsStorageAdapter.ts` forwards `policies`.
- `odspDocumentStorageServiceBase.ts:140-144` sets `{ caching: NoCaching, maximumCacheDurationMs: 5 days }`.
- `containerRuntime.ts:2132-2141` reads `storage.policies.maximumCacheDurationMs` and fails
  attached loads whose driver policy is over 5 days.

**Failure scenario:** none today for ODSP or R11s, which both use 5 days. The runtime-side guard
and the loader's `LoaderCachingPolicy` checks have nothing to read, so a future driver with a
longer cache would load where TS throws.

**Fix:** add `var policies: IDocumentStorageServicePolicies? { get }` to the protocol, and
implement it in both drivers and in the adapter.

## 12. Low: `createOdspAudienceMember` rejects non-string user fields that TS passes through (L3)

**Swift:** `Sources/FluidOdspClient/OdspAudience.swift:6-15` calls `asString()` on
`oid`, `name`, and `email`, which throws on `null` or a number.

**TS:** `odsp-client/src/odspAudience.ts` casts and copies the fields unchecked. Its assert
(`0x836`) only requires one of the three to be `!== undefined`.

**Failure scenario:** a join-session user arrives with `"email": null`, which happens for app-only
or guest identities. TS builds the member. Swift throws and the audience member is lost.

**Fix:** treat a non-string as present but nil. Or keep the raw `JSONValue` so the field stays as
loose as TS's cast.

---

## Checked, no finding

**Commit 144b6f7 (L3):**

- `RootDataObjectFactory` registry order and dedupe (`dataObjectFactory.ts:76-84`, `new Map`
  semantics).
- `parseDataObjectsFromSharedObjects` dedupe and empty check.
- `defaultRuntimeOptionsForMinVersion` and the runtime-options spread order.
- `DOProviderContainerRuntimeFactory`'s `@unchecked Sendable`, which its comment justifies.

**Commit b334791 (L2):**

- `getVersions`, `getSnapshotTree`, and `readBlob` against `odspDocumentStorageManager.ts` and
  `odspDocumentStorageServiceBase.ts`. This includes the `fetchFullSnapshot` URL (TS passes
  `true`), `combineProtocolAndAppSnapshotTree`, `initializeFromSnapshot`, and `BlobCache`.
- The concurrent cache/network race and the summarizer cache expiry.
- The snapshot seq-number check and `canCache` (`fetchSnapshot.ts:543-576`), and the 401/403/404
  cache clear.
- The `mds`/`timeout` limits and the blobless retry.
- The flush loop and the `pendingRename` rename (0xa88).
- `OdspDriverUrlResolver.resolve` (both branches), `getAbsoluteUrl`, `createOdspUrl`, and the hash.
- The `createContainer` branches and the seq-0 check.
- `OdspDeltaStorageWithCache.requestCallback` against `odspDeltaStorageService.ts`.
- `RetryErrorsStorageAdapter` against TS, including `getSnapshotTree` dropping `scenarioName`.
- `EpochTrackerWithRedemption.fetch`: the 401-404 window, and a nil status counting as redeemable.

**Commit 28062b6 (L1):**

- Routerlicious factory URL parsing and endpoints.
- `DocumentService` policy update from `enable_single_commit_summary` and the auth retry.
- Shredded storage `getVersions`, `getSnapshotTree`, `readBlob`, the caches, and
  `getPreviousFullSnapshot`.
- `DocumentStorageService.logTailSha`, and the log-tail serving in `DocumentDeltaStorageService`.
- The `DeltaStorageService` query `from - 1`.
- `tryParseCompatibleResolvedUrl` against the TS regex.
- `fetchISnapshot` and `fetchISnapshotTree`.
- `getBlobContentsFromTree`, including the `.blobs` redirect table.
- The driver-base `DocumentDeltaConnection` handshake: nonce filter, mode/scope check, and the
  timeout of `timeoutMs + 2000`.
