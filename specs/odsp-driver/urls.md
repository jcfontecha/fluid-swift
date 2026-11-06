# ODSP internal and share-link URL resolution

## Role

Internal resolver translates the host's ODSP file locator into a loader URL and REST endpoint set; share-link resolver wraps that with a base64 nav locator, redeem metadata and stable file-link acquisition. Resolution is not token acquisition. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolver.ts:103-194`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolverForShareLink.ts:143-187`.

## Surface used by other packages

`OdspDriverUrlResolver.resolve/getAbsoluteUrl`, `decodeOdspUrl`, `createOdspUrl`, `getHashedDocumentId`, `OdspDriverUrlResolverForShareLink.resolve/getAbsoluteUrl/appendDataStorePath/appendLocatorParams/createDocumentUrl`, `encodeOdspFluidDataStoreLocator/getLocatorFromOdspUrl/storeLocatorInOdspUrl`, `getApiRoot/isSpoUrl/isOdcUrl/getOdspUrlParts`, `patchOdspResolvedUrl`. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolver.ts:103-283`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspFluidFileLink.ts:29-165`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolverForShareLink.ts:108-303`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUrlHelper.ts:15-128`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspLocationRedirection.ts:17-26`.

## Wire and persisted formats

createOdspUrl emits `${siteUrl}?driveId=${enc(driveId)}&itemId=${enc(itemId)}&path=${enc(dataStorePath)}`, then truthy containerPackageName and fileVersion in that order. `enc` is encodeURIComponent. Example `https://t.sharepoint.com/sites/a?driveId=d&itemId=i&path=%2Fstore%3Fx%3D1&containerPackageName=p&fileVersion=v`. No normalization of existing query/fragment in siteUrl. Decoder splits on `?` using only first two components, URLSearchParams decodes once, then explicitly decodeURIComponent values a **second** time. Required driveId/itemId/path reject only null, not empty. Optional empty package/version→undefined. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/createOdspUrl.ts:18-29`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolver.ts:244-283`.

Document hash=`encodeURIComponent(base64(SHA256(UTF8(driveId+"_"+itemId))))`. Source: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspPublicUtils.ts:19-21`. Let H be that hash; existing resolved object is emitted in order:

```text
{type:"fluid",odspResolvedUrl:true,
 endpoints:{snapshotStorageUrl:A+"/drives/d/items/i/[versions/v/]opStream/snapshots",
            attachmentPOSTStorageUrl:A+"/drives/d/items/i/[versions/v/]opStream/attachment",
            attachmentGETStorageUrl:A+"/drives/d/items/i/[versions/v/]opStream/attachments",
            deltaStorageUrl:A+"/drives/d/items/i/[versions/v/]opStream"},
 id:H,tokens:{},url:"https://placeholder/placeholder/"+H+"/"+stripOneLeadingSlash(path),
 hashedDocumentId:H,siteUrl,driveId,itemId,dataStorePath:path,fileName:"",
 summarizer:!!request.headers.summarizingClient,codeHint:{containerPackageName},fileVersion,
 isClpCompliantApp:request.headers["X-CLP-Compliant-App"],fileMetadata:{eTag:request.headers.eTag}}
```

Square-bracket versions segment included only for truthy version. IDs/version raw in REST paths, not component encoded. A is URL origin + `/_api/v2.1`, except ODC origin suffixes onedrive.com/storage.live.com/storage.live-int.com/onedrive-tst.com use `/v2.1`. Site pathname discarded in API root. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolver.ts:31-78`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolver.ts:156-193`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUrlHelper.ts:15-39`.

New request is distinguished by truthy headers[DriverHeader.createNew]; fileName read from its object. Site/query split as above; require truthy fileName/siteURL/driveID and **exactly one** folder selector: path defined (empty valid) with no parentFolderId, OR parentFolderId defined/nonempty with no path. Result endpoints all `""`, tokens={}, type fluid, odspResolvedUrl true, id odspCreateNew, url=`https://${siteURL}?${queryString}&version=null` (literal even if siteURL already scheme), siteUrl=siteURL, hashedDocumentId/itemId/fileName respectively `""`/`""`/supplied, summarizer=false, codeHint optional package, fileVersion/shareLinkInfo undefined, CLP copied. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolver.ts:106-154`.

Nav locator text field order is `s=<enc(site.pathname)>&d=<enc(driveId)>&f=<enc(itemId)>&c=<enc(dataStorePath)>&fluid=1`, append truthy appName as a, package as p, fileVersion as v, context as x. UTF8→**ordinary padded base64**, then URLSearchParams.set("nav",base64) performs URL encoding. Example site `https://t.sharepoint.com/`, d=`d`,i=`i`,path empty → decoded nav text `s=%2F&d=d&f=i&c=&fluid=1`. Text is not JSON and base64 is not base64url. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspFluidFileLink.ts:11-54`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspFluidFileLink.ts:120-134`.

## Behavior

Internal resolve builds endpoints/hash/document URL, asserts no `/` in hash. getAbsoluteUrl: empty relativeUrl reuses resolved.dataStorePath iff defined; strip one leading `/`; package priority source.name, recognized source.package{name,fluid}, source.package fallback, then resolved codeHint; emit internal URL. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolver.ts:156-240`.

Nav decode: absent/falsy nav→undefined; base64 decode→URLSearchParams; require fluid=1 unless requireFluidSignature=false; require nonempty s/d/f, c present but may empty; optional fields preserve empty strings. Resolve s against originating URL origin; malformed URL→undefined. Origin `https://1drv.ms` maps to `https://my.microsoftpersonalcontent.com`. Return href as siteUrl. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspFluidFileLink.ts:65-111`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspFluidFileLink.ts:145-165`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/constants.ts:10-16`.

Share resolve tries new URL + nav decode, catches any failure and retains original URL; valid nav→internal createOdspUrl; internal resolve receives original headers. Await optional getContext(resolved,dataStorePath??""); set appName; keep truthy existing code hint else constructor package. If isSharingLinkToRedeem header truthy, set shareLinkInfo.sharingLinkToRedeem to original URL with **nav removed**, set isRedemptionNonDurable=header??false. If itemId truthy start getShareLinkPromise in background, swallowing failure. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolverForShareLink.ts:143-195`.

Share link promise requires fetcher props and truthy site/drive/item or throws; key `${siteUrl},${driveId},${itemId}`; cache pending/successful promise. Failure logs FluidFileUrlError, removes key, rethrows. getAbsoluteUrl awaits share link then appends nav. appendLocatorParams uses dataStorePath OR resolved path (empty falls back), mutates resolved.context/appName; package priority call argument→resolved.codeHint→constructor. createDocumentUrl modifies base URL's nav directly. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolverForShareLink.ts:198-303`.

appendDataStorePath returns undefined without valid nav. Parse locator dataStorePath against request protocol+hostname (port discarded). For append starting `/?` or `?`, construct URLSearchParams(pathToAppend), append each pair and set pathname+search. Otherwise concatenate pathname + optional separating slash (unless either side supplies it) + pathToAppend + `/` + search. Store modified locator/nav, return href. The extra trailing slash and `/?` URLSearchParams treatment are literal, not path-normalization advice. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolverForShareLink.ts:108-133`.

patchOdspResolvedUrl shallow-copies resolved object, replaces only siteUrl with redirect origin+old site pathname. It does **not** regenerate nested endpoints/hash/url. Higher-level redirect handling receives a new resolved URL error for host re-resolution. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspLocationRedirection.ts:17-26`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/epochTracker.ts:325-347`.

Stable file-link acquisition has its own module-global Promise Map key `siteUrl_driveId_itemId`; hit returns same pending/success promise, failure deletes. Get file metadata with GET `<siteUrl>/_api/v2.0/drives/d/items/i?select=webUrl,webDavUrl,sharepointIds`, response `{webUrl:string,webDavUrl:string,sharepointIds:{listId:string,listItemId:string,listItemUniqueId:string,siteId:string,siteUrl:string,webId:string}}`; validation checks webUrl/webDavUrl strings and only typeof sharepointIds==object. Then GET `<siteUrl>/_api/web/GetFileById(@a1)/ListItemAllFields/GetSharingInformation?@a1=guid<encodeURIComponent("'"+listItemUniqueId+"'")>`, Content-Type and Accept `application/json;odata=verbose`, response `{d:{directUrl:string}}`; missing/nonstring directUrl→incorrectServerResponse. Both calls use token-refresh wrapper and sanitized host headers. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/getFileLink.ts:47-112`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/getFileLink.ts:188-240`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/getFileLink.ts:248-325`.

File metadata's sharepointIds.siteUrl origin differing from resolved origin mutates siteUrl and all nonempty endpoint origins while retaining each pathname; unlike patchOdspResolvedUrl, this helper updates nested endpoints too (drops endpoint query/fragment). Location loop permits five iterations; after a rename, authorization/file-not-found failures repeat metadata discovery; other errors throw immediately. Module's outer driver-utils retry has onRetry counter: fifth retry notification sets canRetry=false and throws; each attempt wraps ODSP runWithRetry for coherency/service-readonly. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/getFileLink.ts:61-99`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/getFileLink.ts:128-171`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/getFileLink.ts:333-351`.

checkUrl reads nav locator; absent→undefined; otherwise tries siteUrl.origin (catches URL failure) and returns `{codeDetailsHint:containerPackageName,criticalBootDomains:siteOrigin?[siteOrigin]:undefined}`. This is a precheck hint, not resolution/authentication. Source: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/checkUrl.ts:18-39`.

getOdspResolvedUrl asserts odspResolvedUrl===true (0x1de); isOdspResolvedUrl checks property existence plus exact true, without validating any endpoints or IDs. Source: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUtils.ts:367-382`.

## Invariants and asserts

0x0a8 hash slash absence. Invalid new parameters → NonRetryable genericError `Proper new file params should be there`. Missing required internal query values throw distinct Error messages for drive id/item id/path. Required nav signature failure returns undefined, not throwing; base64 parsing errors may propagate to callers outside share resolver's catch. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolver.ts:117-159`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolver.ts:262-272`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspFluidFileLink.ts:65-99`.

## JS-semantics hazards

WHATWG URLSearchParams is form-decoding, so `+`→space; decoder then applies decodeURIComponent again and malformed `%` can throw. Foundation URL normalization/percent-decoding once is not equivalent. Preserve case of IDs/path, truthy optional omission, and one-leading-slash removal. New-create result's literal `https://` prefix is observable despite odd-looking output. Hash uses UTF8+underscore, not concatenated bytes without separator. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolver.ts:130-154`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDriverUrlResolver.ts:244-283`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspPublicUtils.ts:19-21`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/odspDriverResolverTest.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/odspDriverUrlResolverForShareLink.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/odspUrlHelper.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/getFileLink.spec.ts:1`. Include percent signs, plus, query in store path, empty path versus missing, consumer origins and redirects retaining endpoints.

## Open questions

None for resolution and locator encoding.
