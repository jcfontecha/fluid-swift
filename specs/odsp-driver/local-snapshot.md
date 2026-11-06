# ODSP local snapshot service

## Role

Offline storage-only implementation consumes caller-supplied snapshot bytes/string; never contacts ODSP/relay. It reuses ordinary snapshot parser and storage tree/blob caches. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/localOdspDriver/localOdspDocumentServiceFactory.ts:20-69`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/localOdspDriver/localOdspDocumentService.ts:25-63`.

## Surface used by other packages

createLocalOdspDocumentServiceFactory(localSnapshot:Uint8Array|string) returns IDocumentServiceFactory. LocalOdspDocumentServiceFactory extends core factory with callbacks that throw UsageError if storage/websocket tokens requested. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentServiceFactory.ts:115-119`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/localOdspDriver/localOdspDocumentServiceFactory.ts:25-39`.

## Wire and persisted formats

No emitted network/persisted format. Input string is JSON IOdspSnapshot (flat trees/blobs/ops), bytes are application/ms-fluid compact snapshot. Local version response `[{id:snapshotTreeId,treeId:undefined}]` when id truthy, otherwise []; treeId omitted by JSON serialization. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/localOdspDriver/localOdspDocumentStorageManager.ts:55-74`.

## Behavior

Factory rejects createContainer with UnsupportedUsage telemetry and UsageError; createDocumentServiceCore rejects supplied cacheAndTracker or truthy clientIsSummarizer, otherwise validates ODSP resolvedURL and creates local service. Service policies={storageOnly:true}; each connectToStorage creates a fresh manager; delta storage captures current manager.ops or [] at call time; delta stream logs UnsupportedUsage then throws; dispose no-op. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/localOdspDriver/localOdspDocumentServiceFactory.ts:41-69`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/localOdspDriver/localOdspDocumentService.ts:29-63`.

Manager first getVersions requires blobid null,count1 (0x342/343), flips calledGetVersions=true **before parsing**, parses string JSON or compact bytes, initializeFromSnapshot sets root/blob/ops and captures snapshotTreeId; subsequent calls return version without reparse, even if first parsing threw. getSnapshot, fetchTreeFromSnapshot, fetchBlobFromStorage, uploadSummaryWithContext,createBlob log UnsupportedUsage then throw UsageError. Inherited readBlob works only for already cached bytes; inherited getSnapshotTree works through cached commit. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/localOdspDriver/localOdspDocumentStorageManager.ts:38-98`.

Local delta fetch: if no snapshotOps return emptyMessageStream. Otherwise filter seq>=from and (to undefined OR seq<to), validateMessages; if no messages or first.seq!=from clear remaining ops, then retain only ops where to!==undefined AND seq>=to; push filtered messages (even empty) then done onto queue. Thus unbounded request consumes everything, abort/cachedOnly/reason ignored. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/localOdspDriver/localOdspDeltaStorageService.ts:24-50`.

## Invariants and asserts

0x342 blobid===null,0x343 count===1; external fetch/write paths unsupported. Source: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/localOdspDriver/localOdspDocumentStorageManager.ts:40-47`.

## JS-semantics hazards

Connection ordering matters: delta storage before snapshot parse sees [], not a live reference to future ops. First-parse failure leaves calledGetVersions=true and prevents retry. Queue yields one empty array then done when filtered result empty, unlike no-ops input returning emptyMessageStream. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/localOdspDriver/localOdspDocumentService.ts:44-50`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/localOdspDriver/localOdspDocumentStorageManager.ts:49-65`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/localOdspDriver/localOdspDeltaStorageService.ts:31-50`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/localOdspDriver.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/localSnapshots/localSnapshot1.json:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/localSnapshots/localSnapshot2.json:1`.

## Open questions

None.
