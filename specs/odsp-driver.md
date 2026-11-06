# @fluidframework/odsp-driver (3.11.0) — porting index

## Role

ODSP driver supplies native client storage and relay transport for SharePoint/OneDrive: internal/share-link resolution, snapshot download/cache, attachments, summary/file upload, join-session discovery, Socket.IO events and operation retrieval. This index partitions its normative contract; the companion package specs cover host types and browser persistence. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/index.ts:6-87`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentService.ts:174-218`.

## Surface used by other packages

| Contract area | Normative spec |
|---|---|
| Full compact binary codec, version gates, worked hex | [compact-snapshot.md](odsp-driver/compact-snapshot.md) |
| Trees-latest JSON/binary, individual versions/blobs, prefetch, caches, epoch/redemption state machines | [snapshots-cache.md](odsp-driver/snapshots-cache.md) |
| Join-session, shared Socket.IO ownership, multiplex routing, delta reads and sparse ops cache | [session-ops.md](odsp-driver/session-ops.md) |
| Runtime summary proposal, handle resolution and relay flush | [summaries.md](odsp-driver/summaries.md) |
| Tokens, 401/403 challenge handling, status mapping, retry constants, host headers | [auth-errors.md](odsp-driver/auth-errors.md) |
| Internal URLs, resolved objects, nav locators and share links | [urls.md](odsp-driver/urls.md) |
| Factory, attach/file creation, sealed-version selection, historical replay | [lifecycle-history.md](odsp-driver/lifecycle-history.md) |
| Offline snapshot-only factory | [local-snapshot.md](odsp-driver/local-snapshot.md) |
| Shared host/token/discovery types | [odsp-driver-definitions.md](odsp-driver-definitions.md) |
| ODSP/Office/OneNote URL adapters | [odsp-urlResolver.md](odsp-urlResolver.md) |
| OAuth/challenge/error helpers | [odsp-doclib-utils.md](odsp-doclib-utils.md) |
| IndexedDB cache and atomic conditional update | [driver-web-cache.md](driver-web-cache.md) |

The public barrel exports both class factory and createOdspDocumentServiceFactory(options), local factory, create-container request builders, URL/locator helpers, prefetch, binary parser, cache/epoch response types, SnapshotFormatSupportType and layer-compat details. Writer/internal transport classes are implementation dependencies rather than public barrel exports. Optional historical implementation is exported from dedicated pointInTime entrypoint and injected through factory options; ordinary constructor does not enable it automatically. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/index.ts:6-87`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentServiceFactory.ts:30-119`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/pointInTime.ts:13-30`.

## Wire and persisted formats

Three noninterchangeable formats: ODSP recursive JSON summary upload; flat JSON or typed compact snapshot download; version-3 epoch cache envelope wrapping native Map/binary values. Socket transport is Socket.IO named-event framing, not raw WebSocket JSON. Each area above contains literal field order, optionality, variants and examples. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/contracts.ts:71-167`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/contracts.ts:201-247`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:406-413`.

## Behavior

Loader resolves a file→factory creates per-file cache/epoch tracker→service opens storage→first snapshot chooses cache/prefetch/network→tree/blob/op initialization→delta storage bridges missing ops→joinSession discovers relay and connects socket. These async edges can overlap; epoch learning and redemption synchronization prevent mixing old/new file lineages. Clean disposal flushes ops then disposes cache/stream; disposal with error removes persisted file entries first. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentServiceFactoryCore.ts:385-445`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentStorageManager.ts:263-467`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/epochTracker.ts:523-646`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentService.ts:303-315`.

Layer compatibility details expose pkgVersion, shared generation=11, empty supportedFeatures Set; requirements minSupportedGeneration=max(0,generation−LayerCompatibilityPolicyWindowMonths.NewDriverOldLoader), requiredFeatures=[]; NewDriverOldLoader=12, hence minSupportedGeneration=0 in this checkout. Constants: `reference/fluidframework-3.11.0/packages/common/client-utils/src/layerGenerationState.ts:12`, `reference/fluidframework-3.11.0/packages/common/client-utils/src/layerCompat.ts:28`. These are loader/driver capability declarations, not compact-snapshot version negotiation. Source: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspLayerCompatState.ts:19-55`.

## Invariants and asserts

A document's epoch is learned once; genuine mismatch invalidates file cache and fails nonretryably. A snapshot sequence must line up with its first op before persistence. Connection callbacks and disconnect disposal ordering are synchronous within one container executor. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/epochTracker.ts:133-166`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/epochTracker.ts:467-515`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/fetchSnapshot.ts:546-575`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:169-210`.

## JS-semantics hazards

Do not fix oracle quirks while porting: signed-looking binary markers decode unsigned; parent-level unreferenced metadata, NUL-string failure, URL double decoding, sparse-array nulls and mutable retryability all have observable consequences. Async I/O must re-enter the container's serial executor; a thread-safe dictionary does not reproduce synchronous event order. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/zipItDataRepresentationUtils.ts:428-571`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotParser.ts:173-227`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolver.ts:244-283`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/opsCaching.ts:147-166`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:169-210`.

## Test assets to reuse

Area specs name concrete upstream unit assets; the key cross-format assets are `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/snapshotFormatTests.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/jsonSnapshotFormatTests.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/zipItDataRepresentationTests.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/localSnapshots/localSnapshot1.json:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/localSnapshots/localSnapshot2.json:1`. Use differential JSON/byte comparison for codecs and deterministic clocks/event traces for storage/connection state.

## Open questions

None for the documented source behavior. These are source-derived porting specs, not claims that a Swift implementation or live ODSP interoperability has been tested.
