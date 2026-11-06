# L8 detached creation

Oracle: installed @fluidframework 3.11.0. `oracle.mjs` creates real TS OdspClient
containers and captures the **actual argument to the driver's createContainer**.
Ten scripts (seeds 0–9) each make 12 detached SharedString inserts and SharedMap
sets, with 0–9 compressor allocations. The Swift test takes the same creation
clock, telemetry UUID and compressor session ID as inputs **before** edits. It
compares the entire uploaded JSON text: no summary/blob normalization.

From the repository root:

```sh
node harness/src/create/oracle.mjs
node harness/src/create/check.mjs
node harness/src/create/check.mjs --plant-divergence
node harness/src/create/check.mjs --cross-load
```

`check.mjs` builds only the relevant test target with `--scratch-path .build/create`
and invokes Swift 6.4's bundled Swift Testing runner. This isolates test discovery
from concurrently authored test targets. `--skip-build` uses a previously built
bundle. `--odsp` runs only the priority ODSP cross-load test.

The planted divergence adds `map.set("planted", true)` on the Swift subject only.
Expected result: exit 1, byte-exact comparison failure on seed 0 (and all 10 seeds).
Without the flag: 10/10 fixture comparisons pass.

Cross-load uses real service clients and local services. It checks Swift-created
and TS-created documents, detached text/map state, concurrent live co-edits, and a
fresh Swift reload. ODSP additionally uploads binary bytes `[0,1,127,128,255]`
while detached and reads the persisted blob through its handle in fresh TS.
Azure local mode uses TS AzureClient, not TinyliciousClient: their tenant IDs differ.
Services use 7083 (Tinylicious/Azure) and 7085 (ODSP) and are stopped by their owned
process handles. No simulator is created.

Existing regression gates, using this lane's reserved ports and scratch path:

```sh
node harness/src/create/regression.mjs service --seeds 0..9
node harness/src/create/regression.mjs service:m2 --seeds 0..9
node harness/src/create/regression.mjs service:m3 --seeds 0..9
node harness/src/create/regression.mjs service:presence --seeds 0..4
node harness/src/create/regression.mjs fuzz:odsp-service --seeds=300
```

The wrapper copies the live existing harness module into this directory, adjusts
only relative imports/root location, reserved port (7084 or 7086), and scratch
path, then removes the copy. Original harness sources/package scripts are untouched.

Confirmed 2026-11-06: base/M2/M3 10/10 each, presence 5/5, ODSP driver 300/300.
The pre-implementation test run was attempted but stopped in concurrent L10 code
before reaching the new tests; do not count it as an observed runtime red test.

Checkpoint regression results (2026-11-06):

- Attach summary: 10/10; planted mode exits 1 with 10 mismatches, first seed 0.
- Cross-load: ODSP, Tinylicious and Azure local all pass both creation directions
  and live co-editing. ODSP's detached binary-blob read-back passes.
- `swift test --scratch-path .build/create`: exit 1. 803 Swift Testing tests ran;
  only `FluidTreeTests.matchesTypeScriptFixture`, `EditManagerTests.swift:135`,
  failed (`trimmedSummary` mismatch in the concurrently owned SharedTree lane).
- `xcodebuild -project Examples/FluidNotes/FluidNotes.xcodeproj -scheme FluidNotes
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/create/FluidNotes
  CODE_SIGNING_ALLOWED=NO build`: failed. `NoteEditor.swift:46` assigns a closure
  to the new `let EventEmitter` sequenceDelta. FluidNotes belongs to L11 and was
  not edited by L8.

Limits: attachment errors follow TS's default close-on-failure path; the opt-in
retry-attachment configuration and detached serialization/rehydration are not
implemented here. Detached binary uploads are exposed on loader `Container`;
fluid-static's broader `create`/`uploadBlob` API remains unported. Routerlicious,
like its TS driver, rejects the empty-create path needed for detached blobs.

L8-authored files:

- `Package.swift` (FluidCreationTests target; FluidStaticTests ID-compressor dependency)
- `Sources/FluidContainerDefinitions/Loader.swift`
- `Sources/FluidContainerLoader/Container.swift`
- `Sources/FluidContainerLoader/CreateAndLoadContainerUtils.swift`
- `Sources/FluidContainerLoader/MemoryBlobStorage.swift`
- `Sources/FluidContainerRuntime/ContainerSummary.swift`
- `Sources/FluidContainerRuntime/SummaryMetadata.swift`
- `Sources/FluidContainerRuntime/DetachedContainerRuntime.swift`
- `Sources/FluidDatastore/FluidDataStoreRuntime.swift`
- `Sources/FluidStatic/FluidContainer.swift`
- `Sources/FluidStatic/RootDataObject.swift`
- `Sources/FluidOdspClient/OdspClient.swift`
- `Sources/FluidAzureClient/AzureClient.swift`
- `Sources/FluidTinyliciousClient/TinyliciousClient.swift`
- `Tests/FluidStaticTests/DetachedCreationTests.swift`
- `Tests/FluidStaticTests/Fixtures/create.json`
- `Tests/FluidCreationTests/CrossLoadTests.swift`
- `harness/src/create/{oracle.mjs,check.mjs,cross-load.mjs,regression.mjs,README.md,planted-divergence.txt}`

No git writes, simulator creation, FluidNotes edits, FluidStatic/Types.swift edits,
or Routerlicious-driver edits were performed by L8. All task-created services stopped.
