# @fluidframework/odsp-driver-definitions (3.11.0)

## Role

Shared ODSP host contracts: resource/token callbacks, resolved file URLs, host storage policies, discovery/label payloads and error categories. This package supplies types/constants and token conversion helpers, not HTTP/OAuth or socket implementations. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/index.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/tokenFetch.ts:96-164`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/errors.ts:18-111`.

## Surface used by other packages

IOdspUrlParts, IOdspResolvedUrl, ShareLinkInfoType, ISharingLinkKind/ISharingLink, SharingLinkScope/Role; TokenFetchOptions/OdspResourceTokenFetchOptions/TokenResponse/TokenFetcher, tokenFromResponse/authHeaderFromTokenResponse/isTokenFromCache, instrumented token fetchers; ISnapshotOptions, IOpsCachingPolicy, ICollabSessionOptions, HostStoragePolicy; ISocketStorageDiscovery/ISensitivityLabelsInfo/ISensitivityLabel; IRelaySessionAwareDriverFactory and provider; OdspErrorTypes/IOdspError/OdspError/IOdspErrorAugmentations; snapshotKey/snapshotWithLoadingGroupIdKey. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/resolvedUrl.ts:12-181`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/tokenFetch.ts:11-164`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/factory.ts:10-160`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/sessionProvider.ts:12-94`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/errors.ts:18-111`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/odspCache.ts:12-23`.

## Wire and persisted formats

Literal resolved URL fields:

```text
{type:"fluid",odspResolvedUrl:true,id:string,url:string,
 siteUrl:string,driveId:string,itemId:string,hashedDocumentId:string,
 endpoints:{snapshotStorageUrl:string,attachmentPOSTStorageUrl:string,
            attachmentGETStorageUrl:string,deltaStorageUrl:string},
 tokens:{},fileName:string,summarizer:boolean,fileVersion:string|undefined,
 pendingRename?:string,codeHint?:{containerPackageName?:string},dataStorePath?:string,
 shareLinkInfo?:{createLink?:{link?:{scope:Scope,role?:Role,webUrl:string},error?:any,shareId?:string},
                sharingLinkToRedeem?:string,isRedemptionNonDurable?:boolean},
 isClpCompliantApp?:boolean,context?:string,appName?:string,fileMetadata?:{eTag?:string}}
```

Scope is organization/users/anonymous/default; Role view/edit. fileVersion is explicitly string|undefined rather than optional in interface; JSON omits undefined. tokens is empty; resolution never obtains credentials. Example locator portion `{siteUrl:"https://t.sharepoint.com",driveId:"d",itemId:"i",fileVersion:undefined}`; share shape `{"sharingLinkToRedeem":"https://t.sharepoint.com/:f:/s/link","isRedemptionNonDurable":true}`. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/resolvedUrl.ts:12-181`.

Token options `{refresh:boolean,claims?:string,tenantId?:string,request?:{url:string,method:"GET"|"POST"|"PATCH"|"DELETE"|"PUT"}}`; ODSP resource adds required siteUrl and optional driveId/itemId. Callback returns `string|{token:string,authorizationHeader?:string,fromCache?:boolean}|null`. IdentityType is Consumer|Enterprise. Example `{"token":"abc","authorizationHeader":"PoP signed","fromCache":false}` gives storage Authorization `PoP signed`, relay token `abc`. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/tokenFetch.ts:11-164`.

Discovery JSON `{id,tenantId,snapshotStorageUrl,deltaStorageUrl,deltaStreamSocketUrl}` all strings, optional runtimeTenantId/socketToken strings, refreshSessionDurationSeconds number, sensitivityLabelsInfo `{timestamp:number,labels:[{sensitivityLabelId:string,tenantId:string,assignmentMethod:string,appliedByUserEmail:string}]}`. Example `{"id":"s","tenantId":"t","snapshotStorageUrl":"https://host/snapshots","deltaStorageUrl":"https://host/ops","deltaStreamSocketUrl":"https://relay/socket","refreshSessionDurationSeconds":3600,"sensitivityLabelsInfo":{"timestamp":1,"labels":[]}}`. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/sessionProvider.ts:12-74`.

Cache type literals snapshot/ops/snapshotWithLoadingGroupId; snapshot singleton key empty string. Current canonical IEntry/IFileEntry/IPersistedCache types moved to driver-definitions, while this package retains deprecated duplicates. Error augmentations serverEpoch?:string, redirectLocation?:string, facetCodes?:string[]. OdspErrorTypes spreads all DriverErrorTypes then adds invalidFileNameError, snapshotTooBig, fetchTimeout, fluidNotEnabled, cannotCatchUp, serviceReadOnly, blockedIPAddress (values equal names). Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/odspCache.ts:12-118`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/errors.ts:18-111`.

## Behavior

Token conversion transitions: string/null pass through tokenFromResponse; undefined→null; object→.token. authHeaderFromTokenResponse selects object.authorizationHeader when !==undefined, else token null→null, other token→`Bearer ${token}`. isTokenFromCache string/null→undefined, object→fromCache. No expiry check/refresh happens in helpers. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/tokenFetch.ts:96-136`.

ISnapshotOptions optional numeric blobs/deltas/channels/mds/timeout. mds is bytes; timeout comment says seconds but actual driver passes to setTimeout in ms. OpsCachingPolicy optional batchSize (default implementation100, <1 disables), timerGranularity (ms default5000, <=0 no timer), totalOpsToCache(default5000). Session options displayName optional string; deprecated forceAccessTokenViaAuthorizationHeader/unauthenticatedUserDisplayName are not a reason to use query auth. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/factory.ts:10-93`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/fetchSnapshot.ts:361-364`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentService.ts:323-349`.

Host policy includes snapshotOptions, immutable hostProvidedRequestHeaders, concurrentSnapshotFetch, opsBatchSize/concurrentOpsBatches, opsCaching, sessionOptions, enableRedeemFallback, cacheCreateNewSummary, fetchBinarySnapshotFormat, isolateSocketCache, enableShareLinkWithCreate, enableSingleRequestForShareLinkWithCreate, avoidPrefetchSnapshotCache. concurrentSnapshotFetch chooses race versus serial cache-first; host headers cannot override driver-owned auth/protocol. Session factory's getRelayServiceSessionInfo returns cached discovery or undefined, not a fresh join request. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/factory.ts:99-189`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/sessionProvider.ts:81-94`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentServiceFactoryCore.ts:168-175`.

## Invariants and asserts

None in token converters. Callers enforce nonnull storage tokens and resolvedURL discriminant. Scope default role when omitted is edit per server-facing contract; helper does not insert role into supplied object. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/tokenFetch.ts:96-136`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/resolvedUrl.ts:46-53`.

## JS-semantics hazards

Do not merge null, undefined and empty string; authHeader empty explicitly wins. Unknown fromCache is not false. Optional metadata must not appear as JSON null. Cache interface comments claiming two-day expiry are stale; actual driver constant is 432000000ms (five days). Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/tokenFetch.ts:96-136`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/odspCache.ts:89-94`, `reference/fluidframework-3.11.0/packages/loader/driver-utils/src/cacheUtils.ts:16`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/tokenFetch.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/buildOdspShareLinkReqParams.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/odspDriverResolverTest.spec.ts:1`; type compatibility fixtures under `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/test/types/validateOdspDriverDefinitionsPrevious.generated.ts:1`.

## Open questions

None.
