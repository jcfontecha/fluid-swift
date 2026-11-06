# ODSP token, retry and error contracts

## Role

Host callbacks supply storage authorization and plain relay tokens. ODSP transport converts HTTP/socket failures to stable driver error categories; bounded refresh/retry wrappers decide whether to call again. Retryability is layered: classification, epoch coherence, token refresh, method-specific retry, and final snapshot failure override. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUtils.ts:103-130`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUtils.ts:400-496`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/retryUtils.ts:20-105`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/epochTracker.ts:467-515`.

## Surface used by other packages

`getWithRetryForTokenRefresh`, `toInstrumentedOdspStorageTokenFetcher`, `toInstrumentedOdspTokenFetcher`, `getHeadersWithAuth`, `runWithRetry`, `fetchHelper/fetchArray/fetchAndParseAsJSONHelper`, `errorObjectFromSocketError`; error mapping and claims parsers are exported by odsp-doclib-utils. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUtils.ts:103-301`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUtils.ts:400-496`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/getUrlAndHeadersWithAuth.ts:12-20`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspError.ts:23-53`.

## Wire and persisted formats

Token callback options `{refresh:boolean,claims?:string,tenantId?:string,request?:{url:string,method:"GET"|"POST"|"PATCH"|"DELETE"|"PUT"},siteUrl:string,driveId?:string,itemId?:string}`; callback returns string, `{token:string,authorizationHeader?:string,fromCache?:boolean}`, or null. Storage wrapper returns full Authorization value: custom authorizationHeader if defined, otherwise `Bearer ${token}`. Websocket wrapper returns token only, not custom auth header. Missing/undefined token response transforms to null; string empty transforms to `Bearer ` for storage. `getHeadersWithAuth` separately asserts returned auth string truthy. Source: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/tokenFetch.ts:11-164`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUtils.ts:400-454`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/getUrlAndHeadersWithAuth.ts:12-20`.

Example claims challenge:

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="tenant", error="insufficient_claims", claims="eyJhIjoxfQ=="
```

becomes AuthorizationError with claims=`{"a":1}`, tenantId=`tenant`; second callback `{refresh:true,previousError,claims:"{\"a\":1}",tenantId:"tenant",request:{url,method},siteUrl,driveId,itemId}`. previousError is internal extra context carried by spread even though public TokenFetchOptions omits it. Source: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUtils.ts:79-112`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUtils.ts:447-450`, `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/parseAuthErrorClaims.ts:20-46`, `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/parseAuthErrorTenant.ts:24-53`.

Service error body recognized if JSON object has `.error.message` string and optional `.error.code` string. Nested `.innerError` chain may contain code. Example `{"error":{"code":"outer","message":"denied","innerError":{"code":"serviceReadOnly"}}}` produces facetCodes `["serviceReadOnly","outer"]`; deepest code determines special mapping. Redirect payload can carry `error["@error.redirectLocation"]`. Sources: `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/odspErrorUtils.ts:120-199`, `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/odspErrorUtils.ts:215-227`, `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/odspErrorUtils.ts:288-306`.

## Behavior

### Token state machine

**Initial→Attempt(false)** calls get({refresh:false}). On rejection create `{refresh:true,previousError:error}`. authorizationError→second attempt with claims/tenantId copied; incorrectServerResponse or fetchTokenError→second attempt; other error only retries if `error.getWithRetryForTokenRefreshRepeat===true`. Second attempt is returned directly, not recaught: **at most two calls per wrapper**, no third refresh. All other errors propagate. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUtils.ts:103-130`.

Instrumented wrapper sends `{...options,...resolvedUrlParts}` (resource fields overwrite collisions). Resolve callback result to auth/plain token; null and throwOnNullToken→NonRetryable fetchTokenError, message `The Host-provided token fetcher returned null`. Rejected callback→wrapped NetworkErrorBasic(fetchTokenError), message `The Host-provided token fetcher threw an error`; preserves `.canRetry` only if actually boolean, otherwise false. This can still get one refresh despite canRetry=false because token-refresh wrapper selects by type. Success token event emitted only forced or duration>=32ms. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUtils.ts:422-495`.

Claims parser gets www-authenticate; absent/falsy→undefined. Split by commas, split section by `=`. First matching error key (case-fold trimmed) JSON.parses lowercased first RHS, detects insufficient_claims; first truthy claims string is JSON.parse of **whole substring after first `=`** (preserving base64 padding), then base64→UTF8. Return claims only when insufficient_claims detected (order independent). Tenant parser requires case-sensitive substring `Bearer`, slices after it, splits commas, finds first truthy realm via JSON.parse(first RHS only). Malformed JSON/base64 may throw; these functions do not catch. Sources: `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/parseAuthErrorClaims.ts:20-46`, `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/parseAuthErrorTenant.ts:24-53`.

### HTTP mapping (all exact branches)

Mapping below uses deepest facet and returns canRetry as listed, before epoch/socket overrides. `retry-after` header uses JS Number, not HTTP-date parsing: null→undefined, NaN→undefined, empty→0. For generic/default only, convert seconds to retryAfterMs by *1000 and use createGenericNetworkError. Sources: `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/odspErrorUtils.ts:206-412`, `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/odspErrorUtils.ts:448-478`.

| Status | Condition → category / retryability |
|---|---|
| 301,302,303,307,308 | Location header defined→OdspRedirectError(fileNotFoundOrAccessDeniedError,false,redirectLocation); absent→same logic as 400 |
| 400 | deepest fluidInvalidSchema→FluidInvalidSchemaError; fluidEpochNotProvided→usageError,true; else genericNetworkError,false |
| 401,403 | deepest serviceReadOnly→serviceReadOnly,true; blockedIPAddress or conditionalAccessPolicyEnforced→blockedIPAddress,false,message `IP Address is blocked`; else AuthorizationError with claims/tenant,false |
| 404 | valid body + defined @error.redirectLocation→OdspRedirectError; else fileNotFoundOrAccessDeniedError,false |
| 406 | unsupportedClientProtocolVersion,false |
| 410 | cannotCatchUp,false |
| 409 | fileOverwrittenInStorage,false; epoch wrapper later distinguishes same/missing epoch |
| 412 | genericNetworkError,false |
| 413 | snapshotTooBig,false |
| 414 | invalidFileNameError,false |
| 423 | deepest resourceLocked/resourceCheckedOut→fileIsLocked,false; otherwise falls through 500 |
| 500 | genericNetworkError,true |
| 501 | fluidNotEnabled,false |
| 507 | outOfStorageError,false |
| 712 (internal fetchIncorrectResponse) | incorrectServerResponse,false (one-refresh wrapper retries once) |
| all others (including 429,502,503,504) | genericNetworkError,true, or throttlingError if defined retryAfterMs through generic helper |

All mapped service errors get endpointReached=true, online=`OnlineStatus[isOnline()]`, facetCodes when parsed, serverEpoch from x-fluid-epoch, responseType and safe header telemetry; thrown REST errors additionally odspError=true/storageServiceError=true. Socket maps same status/retryAfter and serializes nested socketError.error into `{error:...}` with circular replacer; marks odspError/relayServiceError/scenarioName. If mapper itself throws, socket fallback is nonretryable fileNotFoundOrAccessDeniedError with message Internal error: errorObjectFromSocketError. Server_disconnect forces canRetry=true; connection creation forces 400/404 retryable. Sources: `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/odspErrorUtils.ts:409-466`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspError.ts:23-53`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:138-146`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentDeltaConnection.ts:318-340`.

### Fetch failure rules

fetchHelper checks response exists, then requires response.ok AND 200<=status<300; failures consume response.text before map. Success wraps content, lowercased Headers→Map, telemetry, elapsed performance time. Fetch promise rejection: error.name===AbortError or redacted message containing ETIMEDOUT→retryable fetchTimeout; browser offline→retryable offlineError; otherwise retryable fetchFailure. Only first URL matching `/((http|https):\/\/(\S*))/i` redacted; raw text tagged UserData. fetchArray catches body-read failure→712; fetchAndParseAsJSONHelper catches **text read only**, JSON.parse is outside catch and syntax failure propagates unchanged. Trees-latest has its own parsing wrapper. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUtils.ts:133-301`.

### Bounded coherency/read-only retry

runWithRetry starts retryAfter=1000ms, attempts=1; calls optional checkDisposed **outside** try every attempt. Only retries `(error.Odsp409Error===true OR error.errorType===serviceReadOnly) AND canRetryOnError(error)`. First error logs `<callName>_firstFailed` even if not retryable. Fifth failed attempt logs CoherencyErrorTooManyRetries or ServiceReadonlyErrorTooManyRetries, sets canRetry=false, throws; maximum **5 API calls / 4 waits**. Before wait choose getRetryDelayFromError(error) ?? previous retryAfter; delay floor(milliseconds); then update retryAfter += retryAfter/4*(1+Math.random()), i.e. multiplier [1.25,1.5). A defined server delay overrides next time again. Success after retry emits MultipleRetries. Other retryable generic 429/5xx errors are **not** retried by this function. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/retryUtils.ts:20-105`.

Epoch same/missing-epoch 409 wraps ThrottlingError with **1 second**, Odsp409Error=true; true mismatch clears cache and remains nonretryable. Snapshot network final catch sets canRetry=false even for offline. Snapshot core marks fetchFailure/fetchTimeout for one repeat. These are independent wrappers; never collapse into a global retry counter. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/epochTracker.ts:467-515`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/fetchSnapshot.ts:615-627`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentStorageManager.ts:555-577`.

Host headers: snapshot-copy strips authorization, content-type, x-fluid-epoch, x-http-method-override, x-requeststats case-insensitively; absent/empty result→undefined, else freeze. Merge starts safe host Headers then sets request Headers (driver wins case-insensitively), converts to object. Sanitized nonempty headers also force isolated socket cache prefix per factory. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/requestHeaders.ts:6-55`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentServiceFactoryCore.ts:311-333`.

## Invariants and asserts

Authorization header truthy 0x936. Storage wrapper's type promises nonnull but runtime null explicitly becomes fetchTokenError. No token/JWT signature validation is implemented in this wrapper; authority/expiry/refresh belong to host callback. Source: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/getUrlAndHeadersWithAuth.ts:12-20`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspUtils.ts:400-495`.

## JS-semantics hazards

Preserve nil vs empty token/header; a provided empty custom authorizationHeader is selected then fails header assertion, not replaced by Bearer token. Claims JSON parser may throw rather than safely return nil; comma splitting is not RFC challenge parsing. Error canRetry is mutable across layers, not an immutable category property. Number(" ")=0; retry-after date strings become NaN and are ignored. Timer random backoff must be injectable in Swift tests. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver-definitions/src/tokenFetch.ts:111-122`, `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/parseAuthErrorClaims.ts:28-46`, `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/odspErrorUtils.ts:470-478`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/retryUtils.ts:81-102`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/tokenFetch.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/odspError.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/getUrlAndHeadersWithAuth.spec.ts:1`; `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/test/parseAuthErrorClaims.spec.ts:1`, `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/test/parseAuthErrorTenant.spec.ts:1`, `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/test/facetCode.spec.ts:1`. Golden matrix must cover both special 403 branches, claims padding, malformed challenge, retry-after 0/empty/date and nested facet priority.

## Open questions

None.
