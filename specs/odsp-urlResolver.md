# @fluidframework/odsp-urlresolver (3.11.0)

## Role

Adapts ODSP API links and Fluid Office/OneNote application URLs to the internal OdspDriverUrlResolver. It is distinct from odsp-driver's share-link/nav resolver. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-urlResolver/src/urlResolver.ts:32-108`.

## Surface used by other packages

`OdspUrlResolver` and `FluidAppOdspUrlResolver` implement resolve(request)->IResolvedUrl|undefined and getAbsoluteUrl. Both getAbsoluteUrl methods throw Error(`Not implemented`), not an unresolved deferred port feature. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-urlResolver/src/urlResolver.ts:32-108`.

## Wire and persisted formats

Accepted ODSP API shapes: SPO host regex `/\.sharepoint(?:-df)?\.com$/`, path `/^\/_api\/v2\.1\/drives\/[^/]+\/items\/[^/]+/` tested on lowercased host/path. ODC origin suffixes onedrive.com,storage.live.com,storage.live-int.com,onedrive-tst.com; paths `/v2.1/drive/items/ABC!123`, `/v2.1/drives/ABC/items/ABC!123`, `/v2.1/drives('ABC')/items('ABC!123')`. Path match is prefix, not full string validation. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUrlHelper.ts:15-74`.

Fluid app recognized hostname set exactly dev.fluidpreview.office.net,fluidpreview.office.net,www.onenote.com, or www.office.com. First group path regex `/\/(p|preview|meetingnotes|notes)\/([^/]*)\/([^/]*)\/([^/]*)/`; captures encoded site,drive,item. Site is percent-decoded then base64→UTF8 string `spo:<siteUrl>`. Example route `/p/c3BvOmh0dHBzOi8vdC5zaGFyZXBvaW50LmNvbQ==/d/i` has decoded site `spo:https://t.sharepoint.com`; office.com uses query `?drive=d&item=i&siteUrl=https%3A%2F%2Ft.sharepoint.com`. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-urlResolver/src/urlResolver.ts:23-27`, `reference/fluidframework-3.11.0/packages/drivers/odsp-urlResolver/src/urlResolver.ts:72-138`.

## Behavior

OdspUrlResolver: new URL(request.url) (invalid URL throws)→isSpoUrl||isOdcUrl→getOdspUrlParts→undefined if no parts→createOdspUrl({...parts,dataStorePath:""})→internal resolve, preserving headers only when request.headers!==undefined. Nonmatching URL returns undefined. getOdspUrlParts SPO regex extracts raw drive/item, siteUrl=`url.origin+url.pathname` (full original API path retained); ODC chooses normal regex then OData fallback and computes driveId=`match[3] || match[5]`,itemId=match[4] **with those fixed indices in either regex**. For `/v2.1/drives('ABC')/items('ABC!123')`, the fallback returns driveId=`ABC!123`, itemId=`ABC`, not driveId=`ABC`,itemId=`ABC!123`. Preserve that observed capture-index behavior. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-urlResolver/src/urlResolver.ts:33-48`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUrlHelper.ts:83-127`.

FluidAppOdspUrlResolver: lowercase hostname→first host group parser or office.com required params. Missing regex returns undefined. Base64 site prefix before first colon must be exactly spo else Error(`Unexpected storage type X, expected: spo`); siteUrl is decodedSite.slice(storageType.length+1), drive/item decodeURIComponent. Office requires truthy drive/item/siteUrl (0x097). Construct internal URL with empty path then resolve **without forwarding headers**, unlike OdspUrlResolver. Unknown host→undefined. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-urlResolver/src/urlResolver.ts:72-138`.

## Invariants and asserts

0x097 missing/falsy office.com required query. Wrong storage type throws, malformed percent/base64 may throw; no catch normalizes these to undefined. Both absolute URL calls always throw. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-urlResolver/src/urlResolver.ts:79-106`, `reference/fluidframework-3.11.0/packages/drivers/odsp-urlResolver/src/urlResolver.ts:120-138`.

## JS-semantics hazards

Preserve lowercasing only for validation, not extracted IDs. Host checks use URL.host for SPO (includes port), hostname for Fluid apps. ODC suffix check is on origin, not a strict DNS-label validator. Regex capture-index behavior is source-authoritative even for OData fallback. URLSearchParams already decodes office queries; Fluid app path explicitly decodes. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUrlHelper.ts:15-25`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUrlHelper.ts:47-127`, `reference/fluidframework-3.11.0/packages/drivers/odsp-urlResolver/src/urlResolver.ts:72-138`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/drivers/odsp-urlResolver/src/test/fluidAppUrlResolver.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-urlResolver/src/test/spoUrlResolver.spec.ts:1`; supporting `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/odspUrlHelper.spec.ts:1`. Add OData extraction characterization without assuming schema correctness.

## Open questions

None.
