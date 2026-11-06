# aqueduct (fluid-static dependency slice)

## 1. Role

Aqueduct constructs datastore runtimes and their application entry-point objects. fluid-static uses its directory-root DataObject factories and BaseContainerRuntimeFactory; the separate tree-root helper uses TreeDataObject. It does not define a new op transport. (reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/pureDataObjectFactory.ts:58-139, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/container-runtime-factories/baseContainerRuntimeFactory.ts:145-187.)

## 2. Surface used by other packages

`PureDataObject` supplies runtime/context/providers, id, handle, request, finishInitialization and four overridable hooks. `DataObject` adds protected `root`. `PureDataObjectFactory` supplies registryEntry, datastore instantiation and detached/root/child/peer creation. `DataObjectFactory` adds built-in directory/map channel factories. `BaseContainerRuntimeFactory` installs registry, runtime options and entry point. (reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-objects/pureDataObject.ts:36-179, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/pureDataObjectFactory.ts:202-455, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/dataObjectFactory.ts:74-87, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/container-runtime-factories/baseContainerRuntimeFactory.ts:118-187.)

## 3. Wire and persisted formats

Factory `type` is the literal registry wire name; registryEntry is `[type,Promise.resolve(this)]`, factory self-provider returns `this`. Channel registry is `Map(sharedObjects.map(ext => [ext.type,ext]))`; duplicate type uses last value while keeping first key position. Child package paths append factory.type to parent's path, peers reuse the full peer path, top-level createInstance uses `[type]`. These are package path **arrays**, encoded by datastore `.component` as a JSON **string** under `pkg`, e.g. `{"pkg":"[\"rootDO\",\"example\"]","summaryFormatVersion":2,"isRootDataStore":false}`. (reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/pureDataObjectFactory.ts:248-284, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/pureDataObjectFactory.ts:308-361, reference/fluidframework-3.11.0/packages/runtime/container-runtime/src/dataStoreContext.ts:109-125.)

DataObject always owns channel ID `root`, normally factory `https://graph.microsoft.com/types/directory` / snapshot `0.1`; DataObjectFactory also registers legacy `https://graph.microsoft.com/types/map` / snapshot `0.2`, unless already registered by type. Existing documents may have SharedMap masquerading as root; this logs `MapDataObject` but is not rejected at load. No extra Aqueduct lifecycle blob or schema is written. TreeDataObject instead owns `root-tree`, factory SharedTree; it binds the new channel and rejects non-SharedTree channels when loading. (reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-objects/dataObject.ts:31-77, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/dataObjectFactory.ts:74-87, reference/fluidframework-3.11.0/packages/dds/map/src/directoryFactory.ts:32-40, reference/fluidframework-3.11.0/packages/dds/map/src/mapFactory.ts:32-40, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-objects/treeDataObject.ts:17-110, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/treeDataObjectFactory.ts:27-42.)

## 4. Behavior

### Object lifecycle transitions (execution order)

- Unconstructed → constructed: create request-handler-mixed runtime with context, channel registry, existing flag, entry point callback and policies; synthesize optional providers from scope or `{}`; instantiate `new ctor({runtime,context,providers,initProps})`.
- New constructed → initializing: factory immediately awaits `finishInitialization(false)` **before attaching runtime**. Existing constructed → uninitialized: factory returns runtime without running hooks; entry point callback later awaits `finishInitialization(true)` then returns instance. This avoids deadlock resolving handles through a runtime not yet registered in the container.
- First `finishInitialization(existing)` stores `initializeInternal(existing)` Promise via `??=`; later calls reuse that same fulfillment or rejection, regardless of supplied existing flag. No retry on rejection.
- DataObject initialization first loads root channel when existing, or creates/binds SharedDirectory `root` when new, then calls PureDataObject initialization. Thus root exists before `preInitialize`.
- Pure initialization awaits `preInitialize`; if existing, asserts `initProps===undefined`, awaits `initializingFromExisting`; else awaits `initializingFirstTime(context.createProps ?? initProps)`; finally awaits `hasInitialized`. An error stops subsequent hooks and remains cached.

(reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/pureDataObjectFactory.ts:75-139, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-objects/pureDataObject.ts:99-179, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-objects/dataObject.ts:50-77.)

### Creation / alias transitions

Nonroot creation: `createDetachedDataStore(packagePath,loadingGroupId)` → create and initialize object with existing=false → `attachRuntime(factory,runtime)` → return instance. Attaching runtime is not attaching the object to document handle graph. `createInstanceWithDataStore` additionally returns the datastore for aliasing. Root creation: detached `[type]` → initialize → attachRuntime → await `trySetAlias(rootDataStoreId)`; Success returns candidate, otherwise resolve existing aliased handle, assert it exists and return its object. This fallback is actual upstream behavior, not a Swift design choice. (reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/pureDataObjectFactory.ts:376-455.)

### Container factory

Constructor creates FluidDataStoreRegistry and defaults requestHandlers to []; rejects simultaneously supplied `oldestSupportedClient` and deprecated `minVersionForCollab`; resolved value is the former `??` latter. `preInitialize` optionally layers dependency container over scope then calls loadContainerRuntime with context, existing, options, registry entries, scope, composed request handler, provideEntryPoint and oldestSupportedClient. First-time runtime initialization awaits containerInitializingFirstTime then containerHasInitialized; existing awaits only containerHasInitialized. (reference/fluidframework-3.11.0/packages/framework/aqueduct/src/container-runtime-factories/baseContainerRuntimeFactory.ts:118-202.)

Pure object `id` is runtime.id; `handle` is runtime.entryPoint. Requests `""`, `"/"`, or any string starting `"/?"` return `{mimeType:"fluid/object",status:200,value:this}`, everything else returns 404. Accessing DataObject.root before set throws `root must be initialized before being accessed.` (reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-objects/pureDataObject.ts:71-118, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-objects/dataObject.ts:38-44, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-objects/dataObject.ts:84-85.)

## 5. Invariants and asserts

`0x46a`: runtime entry-point callback has a constructed instance; `0x795`: request delegate entry point has request; `0x46b`: handle getter has runtime entryPoint; `0x0be`: loading existing with initProps forbidden; `0x8e1`: non-Success root alias result must resolve handle. Empty factory type throws `undefined type member`. Tree root access before initialized throws UsageError; loading wrong channel type throws an Error naming channel ID. (reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/pureDataObjectFactory.ts:78-105, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/pureDataObjectFactory.ts:248-250, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/pureDataObjectFactory.ts:423-427, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-objects/pureDataObject.ts:86-91, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-objects/pureDataObject.ts:140-153, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-objects/treeDataObject.ts:75-92.)

## 6. JS-semantics hazards

Retain initialization Promise identity including failures. Do not eagerly initialize existing objects during runtime construction: handles may route back into an incompletely registered datastore. `??` treats null and undefined alike, not falsy values. Runtime attachment, graph attachment and alias assignment are separate transitions. (reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/pureDataObjectFactory.ts:124-139, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-object-factories/pureDataObjectFactory.ts:382-429, reference/fluidframework-3.11.0/packages/framework/aqueduct/src/data-objects/pureDataObject.ts:128-153.)

## 7. Test assets to reuse

The package-local `aqueduct.spec.ts` is only `describe("aqueduct-placeholder", () => {})`, not lifecycle coverage. There are no executable behavioral tests to reuse from that file. Reuse fluid-static type fixtures for API shape and service-client integration fixtures for factories, and add differential cases for existing-object lazy initialization, cached failed initialization, alias collision and legacy map root. (reference/fluidframework-3.11.0/packages/framework/aqueduct/src/test/aqueduct.spec.ts:6-7, reference/fluidframework-3.11.0/packages/framework/fluid-static/src/test/fluidContainer.spec.ts:1-40, reference/fluidframework-3.11.0/packages/service-clients/tinylicious-client/src/test/TinyliciousClient.spec.ts:1-50.)

## 8. Open questions

None.
