# Reconnect implementation handoff

Automatic reconnect and loader-level storage retry are implemented. No git writes were performed.
The parallel `Sources/Fluid`, `Tests/FluidTests`, `Examples/FluidNotes`, and design-doc changes
belong to the other lane and were not edited here.

## Changed files

- `Package.swift`: FluidDriverUtils product/target/test target, driver/loader dependencies, and
  FluidReconnectPeer executable target rooted inside this harness directory. Other lane's manifest
  changes remain intact.
- `Sources/FluidContainerDefinitions/ReconnectMode.swift`.
- `Sources/FluidContainerLoader/ConnectionManager.swift`, `ConnectionStateHandler.swift`,
  `Container.swift`, `CreateAndLoadContainerUtils.swift`, `DeltaManager.swift`,
  `RetriableDocumentStorageService.swift`.
- `Sources/FluidDriverUtils/{Network,RunWithRetry,ParallelRequests}.swift`.
- `Sources/FluidContainerRuntime/DatastoreIntegration.swift`: TS's content-before-type construction
  at the channel-collection boundary, required for byte-exact pending-op replay. No PSM algorithm change.
- `Sources/FluidRouterliciousDriver/ParallelRequests.swift`: typed boundary over the shared worker.
- `Sources/FluidOdspDriver/{ParallelRequests,OdspDeltaStorageWithCache}.swift`: shared worker import,
  retained driver-base message validation, ODSP error conformance.
- `Tests/FluidContainerLoaderTests/{LoadExistingContainerTests,ReconnectTests,StorageRetryTests}.swift`.
- `Tests/FluidDriverUtilsTests/RetryTests.swift`.
- `Tests/FluidOdspDriverTests/OdspNetworkTests.swift` and
  `Tests/FluidRouterliciousDriverTests/RemoteServiceTests.swift`: import the moved helpers.
- `harness/src/reconnect/{fuzz,oracle,live}.ts`, `swift/{Peer,LiveHost}.swift`, `scratch.mjs`, this report.
- `harness/package.json`: only the `fuzz:reconnect` script.
- `harness/PROTOCOL.md`: append-only Reconnect section.

## Public API

- New `FluidDriverUtils` library exports `RetryableError`, `NetworkError`,
  `canRetryOnError`, `getRetryDelayFromError`, `calculateMaxWaitTime`, `runWithRetry`,
  `RetrySleep`, `retrySleep`, `ParallelRequests`, and the shared `requestOps` worker.
- `RetriableDocumentStorageService(storage, maxRetries:, sleep:)` implements storage and exposes
  `dispose()`/`disposed`. Disposal prevents retry, not the first attempt, matching TS.
- `ReconnectMode` and `ConnectionStateHandler` are public port types.
- `ILoadExistingContainerProps` and `ICreateDetachedContainerProps` add `canReconnect: Bool = true`.
  False gives Never behavior; established-session loss closes instead of reconnecting.
- `ConnectionManager` gains reconnect policy, requested mode, permission state and injected delay.
  Its former public `receivedJoin` primitive is replaced by the connection-state handler.
- `DeltaManager.init(active:readonly:)` adds a defaulted readonly provider.
- Existing app connect/disconnect/submit calls are unchanged. Manual disconnect disables automatic
  reconnect; connect re-enables it. Never-policy connect/disconnect controls are programmer errors.
- Routerlicious's typed public `requestOps` signature is retained; its duplicated algorithm is gone.

## Executed gates

Commands below run from repository root unless explicitly labeled harness cwd.
All Swift builds used `--scratch-path .build/reconnect`.

| Gate | Command | Result | Evidence |
|---|---|---|---|
| All Swift suites | `swift test --scratch-path .build/reconnect` | Exit 0; 824 tests in 107 suites across 31 reported target runs | `/tmp/reconnect-final-swift.log` |
| Final loader tests, including subsequently added read-to-write regression | `swift test --scratch-path .build/reconnect --filter 'LoadExistingContainerTests\|ConnectionAttemptTests\|ConnectionStateHandlerTests\|ReconnectTests\|StorageRetryTests'` (literal regex pipes, no backslashes in actual argv) | Exit 0; 27 tests in 7 suites | `/tmp/reconnect-read-upgrade-final.log` |
| Loader differential | harness: `npm run fuzz:reconnect -- --seeds=300` | Exit 0; 300 seeds, shared TS ordering service, raw op bytes/events/delays/state | `/tmp/reconnect-final-fuzz.log` |
| Live recovery | harness: `./node_modules/.bin/tsx src/reconnect/live.ts` | Exit 0; tinylicious and ODSP each recovered 3 service drops and converged on 12 edits | `/tmp/reconnect-final-live.log` |
| M1 | harness: `npm run service -- --seeds 0..9 --scratch-path=.build/reconnect` | Exit 0; 10 seeds | `/tmp/reconnect-m1.log` |
| M2 | harness: `npm run service:m2 -- --seeds 0..9 --scratch-path=.build/reconnect` | Exit 0; 10 seeds | `/tmp/reconnect-m2.log` |
| M3 | harness: `npm run service:m3 -- --seeds 0..9 --scratch-path=.build/reconnect` | Exit 0; 10 seeds | `/tmp/reconnect-m3.log` |
| Presence | harness: `npm run service:presence -- --seeds 0..4 --scratch-path=.build/reconnect` | Exit 0; 5 seeds | `/tmp/reconnect-presence.log` |
| ODSP driver/service | harness: `NODE_OPTIONS=--import=/tmp/reconnect-scratch.mjs npm run fuzz:odsp-service` | Exit 0; 300 seeds | `/tmp/reconnect-odsp-regression.log` |
| R11s driver/service | harness: `NODE_OPTIONS=--import=/tmp/reconnect-scratch.mjs npm run fuzz:r11s-service` | Exit 0; 300 seeds | `/tmp/reconnect-r11s-regression.log` |
| M4 | harness: `npm run service:m4 -- --clients ts,ts --seeds 0..9 --port 7097` | Exit 0; 10 seeds | `/tmp/reconnect-m4.log` |
| TS compile | `./harness/node_modules/.bin/tsc --noEmit -p harness` | Exit 0 | `/tmp/reconnect-final-tsc.log` |
| Whitespace | `git diff --check` | Exit 0 | tool output |

The driver-service runners hardcode their own scratch paths. `scratch.mjs` is the exact temporary
preload used for those two commands: it rewrites only Swift build scratch arguments and the peer
executable paths, leaving scenario generation and comparison untouched. To reproduce, replace
`/tmp/reconnect-scratch.mjs` with the absolute path to this directory's `scratch.mjs`.
The root `npx tsc` initially found the unrelated npm `tsc` package because this workspace has no
root node_modules; the recorded passing command explicitly uses harness's installed TypeScript.

## Behavioral details and hazards

- 400/401/404/429/500/503 nacks retry. 403 nacks close. A read-only-permission nack closes.
  Live disconnect reasons reconnect even when `canRetry` is false; fatal connection-attempt errors close.
- Backoff is TS's 1000/2000/4000/8000/... ms offline sequence; reached endpoints cap at 60000 ms.
  An explicit live-disconnect retryAfter is not capped by the connect-attempt backoff.
- The runtime keeps its previous client ID until leave/join/checkpoint gates pass. Tests cover both
  a lost unsequenced op and an already-sequenced op with a withheld old-session ack.
- Storage ordinary summary uploads intentionally do not retry; creation summaries do. The wrapper
  preserves the referenceSequenceNumber/ackHandle invariant.
- The final read-to-write regression exposed a fake-service error (read clients were being joined
  into the writer quorum), which was corrected. It now proves exactly one initial connected event,
  disconnect/reconnect for upgrade, and no op sent on the read connection.
- The TS 3.11.0 targeted server_disconnect/multiplexed-handshake crash is deliberately not mirrored.
  ODSP live injection uses the existing handshake-quiescence guard. Recovery during that known TS
  crash window is not claimed; established-session recovery is proven.
- Native retry uses TS's default behavior without a browser navigator.onLine signal. Swift task
  cancellation is the I/O cancellation mechanism. Browser online listeners and TS telemetry event
  objects are not new native API surfaces in this lane.
- The fuzz service resets between oracle/subject runs. It is one TS sequencing implementation,
  accessed directly by TS and over HTTP by Swift, not a separately ported Swift fake. Mixed live
  co-editing is covered by the two live services, rather than claimed from lockstep final state alone.

## Planted divergence and final state

- Harness cwd: `npm run fuzz:reconnect -- --seeds=1 --plant-divergence` exited **1**, with
  `AssertionError [ERR_ASSERTION]` showing the extra `planted` event missing from Swift's observation.
  Evidence: `/tmp/reconnect-final-planted.log`, and `harness/traces/reconnect/0.json` (both raw observations).
- Immediately reran `npm run fuzz:reconnect -- --seeds=300` without the flag: **exit 0, 300/300**.
  Evidence: `/tmp/reconnect-restored.log`. The normal run does not overwrite the planted failure trace.
- The added read-to-write test and all 27 selected loader tests passed after correcting the fake
  service's read-client membership. No production code was changed for that fixture correction.
- No requested functional item or gate is left queued. The known TS crash window and the native
  browser/telemetry boundaries above remain explicit limitations, not claims of tested parity.
- No task-created service/peer process remains running. No commit, staging, branch, or other git
  mutation was performed; the parent owns integration and commits.
