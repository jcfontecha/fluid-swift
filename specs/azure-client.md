# azure-client

## 1. Role

Service facade for remote Azure Fluid Relay or local Routerlicious-compatible service; combines driver, URL resolver, optional summary storage compression, fluid-static directory-root runtime and service audience. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:107-130, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:307-355.)

## 2. Surface used by other packages

Props `{connection,logger?,configProvider?,summaryCompression?:boolean|ICompressionStorageConfig}`. Connection is `{type:"remote",endpoint:string,tokenProvider:ITokenProvider,tenantId:string}` or `{type:"local",endpoint:string,tokenProvider:ITokenProvider}`; local tenant literal `local`. Internal props optionally replace `createContainerRuntimeFactory({schema,oldestSupportedClient})`. API: createContainer(schema,oldestSupportedClient), getContainer(id,schema,oldestSupportedClient) → `{container,services:{audience}}`; viewContainerVersion(id,schema,{id,date?},oldestSupportedClient) → `{container}`; getContainerVersions(id,{maxCount}?) → `{id:string,date?:string}[]`, default maxCount=5. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/interfaces.ts:21-157, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:56-80, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:144-304.)

Azure supplies no built-in token issuer. Host supplies `fetchOrdererToken(tenantId,documentId?,refresh?)`, `fetchStorageToken(tenantId,documentId,refresh?)` returning `{jwt:string,fromCache?:boolean}`; refresh means bypass local cache, default false. Optional post-create callback receives documentId and creationToken and can reject document creation. AzureUser is `{id:string,name:string,additionalDetails?:T}`, projected member adds `connections`. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/interfaces.ts:170-211, reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/tokens.ts:23-97.)

## 3. Wire and persisted formats

Create and code-loader details `{"package":"no-dynamic-package","config":{}}`; client literal `{"details":{"capabilities":{"interactive":true}},"permission":[],"scopes":[],"user":{"id":""},"mode":"write"}`. Actual user comes through driver token/auth path. Default registry uses `rootDO`, alias `rootDOId`, root directory `root`, subdirectory `initial-objects-key`; no Azure-specific schema blob. `Fluid.Container.ForceWriteConnection=true` is a default, overridden by non-nullish user provider config. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:69-80, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:160-166, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:316-355, reference/fluidframework-3.11.0/packages/framework/fluid-static/src/rootDataObject.ts:76-112, reference/fluidframework-3.11.0/packages/framework/fluid-static/src/rootDataObject.ts:158-159.)

### URL request encoding

Mutate connection endpoint by removing **one trailing slash**. For create, make URL(endpoint); append storage=encodeURIComponent(endpoint), then tenantId=encodeURIComponent(tenant); headers `{"createNew":true}`. For existing append containerId=encodeURIComponent(id). URLSearchParams applies a second encoding layer; resolver first URL-parses (implicitly decoding query once), then decodeURIComponent each query value. Resolver orderer URL is **origin**, not full endpoint. Required storage and tenantId query keys missing → Errors; containerId required only for non-create. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:111-120, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:204-216, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureUrlResolver.ts:71-120.)

Example endpoint `https://relay.example`, tenant `t`, document `d`: request URL `https://relay.example/?storage=https%253A%252F%252Frelay.example&tenantId=t&containerId=d`. Existing result (property order literal): `{"endpoints":{"deltaStorageUrl":"https://relay.example/deltas/t/d","ordererUrl":"https://relay.example","storageUrl":"https://relay.example/repos/t"},"id":"d","tokens":{},"type":"fluid","url":"https://relay.example/t/d"}`. Create result uses delta suffix `/t/new`, id empty string, url `https://relay.example/t/new`, same storage endpoint. Path components after decode are interpolated without re-encoding. getAbsoluteUrl requires type fluid and returns `${resolvedUrl.url}/${relativeUrl}` without slash normalization. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureUrlResolver.ts:23-98.)

Version requests use same document URL with loader header key `version` set to version.id; use paused loading, not a live getContainer. Version-list storage call is `getVersions(null,options?.maxCount ?? 5)` and projected results retain id/date only. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:253-304, reference/fluidframework-3.11.0/packages/common/container-definitions/src/loader.ts:708-715.)

## 4. Behavior

Constructor stores connection object and logger; trims endpoint **in caller's object**; constructs resolver; driver options `enableWholeSummaryUpload` and `enableDiscovery` both equal `connection.type === "remote"`; wraps service factory with applyStorageCompression; wraps config defaults; records optional internal factory replacement. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:107-130.)

New transition: loader props → createDetachedContainer → create attach request once → await createFluidContainer and replace attach → create audience → return. Attach requires Detached, else Error `Cannot attach container. Container is not in detached state` (no trailing period); awaits underlying attach, requires resolvedUrl else `Resolved Url not available on attached container`, returns resolvedUrl.id. Existing loads URL then wraps and creates audience, leaving default attach rejection. Version view loads paused at version ID and wraps only; no audience service returned. Creation/get do not await later connected/saved events. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:158-221, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:253-268, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:358-384.)

Version-list transition: resolve URL; absent resolution throws `Unable to resolved URL`; await createDocumentService → connectToStorage → getVersions → map `{id,date}`. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:278-304.)

Audience converter first checks user.id !== undefined then user.name !== undefined; missing values throw distinct TypeErrors beginning `Provided user data was not an "AzureUser".` and ending `Missing required "id" property.` or `Missing required "name" property.` It **does not typecheck string at runtime**. Constructs `{id,name,connections:[],additionalDetails}` (undefined additionalDetails omitted by JSON.stringify). fluid-static excludes noninteractive members and groups by user.id, takes first connection's name/details, and emits memberAdded/Removed before membersChanged. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureAudience.ts:16-39, reference/fluidframework-3.11.0/packages/framework/fluid-static/src/serviceAudience.ts:82-165.)

## 5. Invariants and asserts

Absent storage/tenant/container query errors are `Azure URL did not contain a storage URL`, `Azure URL did not contain a tenant ID`, `Azure URL did not contain containerId`. Non-fluid absolute URL errors `Invalid Resolved Url`. Attach and user validation errors above are not swallowed. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureUrlResolver.ts:43-65, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureUrlResolver.ts:80-92, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureAudience.ts:31-39, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:370-378.)

## 6. JS-semantics hazards

Preserve double query encoding/decoding, single trailing-slash removal, origin vs full storage endpoint, and undefined vs absent date/additionalDetails. Do not conflate user's stable id with audience connection id. A paused version view is not a connected container; do not automatically connect it as a side effect of wrapping. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:111-120, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureClient.ts:253-304, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/AzureUrlResolver.ts:71-98, reference/fluidframework-3.11.0/packages/framework/fluid-static/src/serviceAudience.ts:100-136.)

## 7. Test assets to reuse

AzureClient integration tests and TestConstants provide service creation/loading, version and audience scenarios. Reuse with local endpoint and host token provider; differential URL fixtures should include percent, slash and non-ASCII IDs. (reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/test/AzureClient.spec.ts:1-50, reference/fluidframework-3.11.0/packages/service-clients/azure-client/src/test/TestConstants.ts:6-18.)

## 8. Open questions

None.
