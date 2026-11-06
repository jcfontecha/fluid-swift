# tinylicious-driver — Swift port contract (3.11.0)

## Role

Tinylicious is a configuration/identity/resolution layer over RouterliciousDocumentServiceFactory, not a separate transport. It supplies localhost endpoint defaults, permissive locally-signed tokens and a service client/container facade. All document REST and socket calls run through Routerlicious with its default policies (shredded summaries, RestLess, prefetch, no discovery). Source: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/tinyliciousService.ts:106-131`.

## Surface used by other packages

`InsecureTinyliciousTokenProvider(scopes?:ScopeType[])` implements both token fetch methods; test helper constructs it. `InsecureTinyliciousUrlResolver(options?:{port?:number,endpoint?:string})` also accepts legacy `(port?,endpoint?)`; resolve/getAbsoluteUrl. `defaultTinyliciousPort=7070`, `defaultTinyliciousEndpoint="http://localhost"`; createInsecureTinyliciousTestUrlResolver; createTinyliciousCreateNewRequest(documentId?); test alias of same function. `createTinyliciousServiceClient(options)` returns ServiceClientImplementation(options,TinyliciousServiceContainer). `TinyliciousServiceOptions` extends ServiceOptions with port/endpoint; container exposes createDetached(registry,options,root), load(registry,options,id), inherited service container API and attach request. Sources: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousTokenProvider.ts:16-90`, `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:19-56`, `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:146-165`, `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/tinyliciousService.ts:47-78`, `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/tinyliciousService.ts:138-213`.

## Wire and persisted formats

### Identity

JWT protected header JSON emitted in order `{"alg":"HS256","typ":"JWT"}`. HS256 key is UTF-8 literal **12345**, not a tenant-provided key. Each token fetch constructs a new UUID v4 lowercase user id; name is first two UUID segments using `/^([\da-f]{8})-([\da-f]{4})/`, falling back entire id. `now=Math.round(Date.now()/1000)` (not floor). Claims insertion order:

```text
documentId:string = argument ?? ""
scopes:string[] = supplied scopes ?? ["doc:read","doc:write","summary:write"]
tenantId:string
user:{id:string,name:string}  // id then name
iat:number = now
exp:number = now + 3600
ver:string = "1.0"
```

No jti. Sign with jsrsasign.JWS.sign(null,JSON.stringify(header),claims,{utf8:"12345"}); standard compact JWT base64url(header).base64url(payload).base64url(HMAC-SHA256(signingInput)). Both fetch methods return object in order `{fromCache:true,jwt:generatedToken}` even though token was freshly generated. Refresh argument is not implemented/consulted. Sources: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousTokenProvider.ts:29-81`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/protocol/scopes.ts:10-25`.

Concrete claims for injected UUID `01234567-89ab-4cde-8fab-0123456789ab`, Date.now=1700000000500, tenant tinylicious and absent document:

```json
{"documentId":"","scopes":["doc:read","doc:write","summary:write"],"tenantId":"tinylicious","user":{"id":"01234567-89ab-4cde-8fab-0123456789ab","name":"01234567-89ab"},"iat":1700000001,"exp":1700003601,"ver":"1.0"}
```

Source producer: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousTokenProvider.ts:55-80`. Empty supplied scopes [] stays empty; UUID and clock must be injected for byte-exact token fixtures.

### Request/resolved URL records

Create-new request field order `{url:documentId??"",headers:{createNew:true}}`; DriverHeader.createNew string value is createNew. Resolver output field order `endpoints`, `id`, `tokens`, `type`, `url`; endpoints order deltaStorageUrl, ordererUrl, storageUrl; tokens always `{}`, type always fluid, tenant hardcoded tinylicious, **no deltaStreamUrl**. Source: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:59-96`, `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:155-160`, `reference/fluidframework-3.11.0/packages/common/driver-definitions/src/urlResolver.ts:12-35`.

```json
{"url":"","headers":{"createNew":true}}
{"endpoints":{"deltaStorageUrl":"http://localhost:7070/deltas/tinylicious/new","ordererUrl":"http://localhost:7070","storageUrl":"http://localhost:7070/repos/tinylicious"},"id":"new","tokens":{},"type":"fluid","url":"http://localhost:7070/tinylicious/new"}
```

For normal request `a b/inner?x=1`, id is literal `a b`, url `http://localhost:7070/tinylicious/a%20b/inner?x=1`, delta URL `http://localhost:7070/deltas/tinylicious/a%20b`. Create-new `a b/inner` instead emits unencoded id segment `a b` and discards /inner. Source: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:59-96`.

### REST and socket binding

This package itself has no fetch/socket event listeners. It binds the Routerlicious inventory to `O=http://localhost:7070`, `S=O/repos/tinylicious`, `L=O/deltas/tinylicious/<enc(document)>`. Methods below are logical; defaults send actual POST RestLess to the same path/query, actual header `Content-Type: application/x-www-form-urlencoded;restless`, form `method`, repeated `header`, optional JSON `body`. Logical orderer auth Basic JWT, storage auth Basic base64(UTF8("tinylicious:"+JWT)); logical x-driver-version; no generated correlation request header; read response x-correlation-id. Source: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/tinyliciousService.ts:116-121`, `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:77-95`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/restWrapper.ts:290-301`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/restWrapper.ts:353-360`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/restWrapper.ts:409-413`, `reference/fluidframework-3.11.0/server/routerlicious/packages/services-client/src/restLessClient.ts:38-67`.

| Logical endpoint | Query/body/response |
|---|---|
| POST O/documents/tinylicious | Body ordered summary (converted .app tree), sequenceNumber, values (parsed quorumValues), enableDiscovery=false, generateToken=false, isEphemeralContainer=false, enableAnyBinaryBlobOnFirstSummary=true. Response string id or object `{id:string,token?:string,session?:Session}`; id replaces final document/delta URL path segment. |
| GET L | from=inclusiveStart-1, to=exclusiveEnd, fetchReason=reason or empty string. Response SequencedMessage[]; batch2000, concurrency1. |
| GET S/commits | count,sha; response Git CommitDetails[]; 400/404→empty array. |
| GET S/git/trees/enc(treeId) | recursive=1; response `{sha,url,tree:[{path,mode,type,size,sha,url}]}`. |
| GET S/git/blobs/enc(blobId) | No query; response `{content:string,encoding:string,url:string,sha:string,size:number}`. |
| POST S/git/blobs | `{content:string,encoding:"utf-8"|"base64"}`; response `{sha:string,url:string}`. |
| POST S/git/trees | `{tree:[{mode:"100644"|"040000",path:encodedKey,sha:string,type:"blob"|"tree"}]}`; response GitTree. |
| POST S/git/summaries | Not selected by this package's service factory defaults; inherited Routerlicious whole-summary policy emits entries,message="",sequenceNumber=0,type="channel", query initial=false; response `{id:string}`. |
| GET S/git/summaries/version | Whole-summary mode only, version unescaped, response `{id,trees:[{entries,id,sequenceNumber}],blobs?}`. |
| GET O/documents/tinylicious/session/id | Discovery mode only, disabled by this package's factory defaults; response Session URL/boolean record. |

Authoritative endpoint producers: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/documentServiceFactory.ts:191-202`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/historian.ts:54-115`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/deltaStorageService.ts:146-183`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/sessionInfoManager.ts:123-145`. The full nested Git, whole summary and SequencedMessage contracts are in the sibling Routerlicious spec; there is no Tinylicious-specific transformation of these bodies (`reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/tinyliciousService.ts:116-121`).

Concrete default creation RestLess body decodes to:

```json
{"summary":{"type":"tree","entries":[]},"sequenceNumber":0,"values":[],"enableDiscovery":false,"generateToken":false,"isEphemeralContainer":false,"enableAnyBinaryBlobOnFirstSummary":true}
```

Derived from empty combined protocol/app summary; strings use UTF-8, binary blobs base64 in nested summary. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/documentServiceFactory.ts:150-202`, `reference/fluidframework-3.11.0/server/routerlicious/packages/services-client/src/storageUtils.ts:59-148`.

Socket connects to O, query `{documentId,tenantId:"tinylicious"}`, websocket only, reconnection false, timeout20000; handshake22000. Sends connect_document fields client,id,mode,tenantId,token,versions priority ^0.4/^0.3/^0.2/^0.1, relayUserAgent, supportedFeatures.submit_signals_v2=true. Receives connect_document_success/error, op(documentId,messages), signal(single|array), nack(documentId,nacks), disconnect(reason,details), error, connect_error, connect_timeout. Sends submitOp(clientId,[messages]), submitSignal(clientId,[{content,targetClientId?}]) iff v2 supported else [[content]], ping(ack) for local pong latency; sends client_disconnect(clientId,documentId,message) on nonclean connected teardown. No additional Tinylicious event. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/documentDeltaConnection.ts:22-70`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/documentDeltaConnection.ts:110-118`, `reference/fluidframework-3.11.0/packages/drivers/driver-base/src/documentDeltaConnection.ts:162-209`, `reference/fluidframework-3.11.0/packages/drivers/driver-base/src/documentDeltaConnection.ts:348-389`, `reference/fluidframework-3.11.0/packages/drivers/driver-base/src/documentDeltaConnection.ts:482-694`.

## Behavior

### Resolver transitions (stateless)

1. Constructor: if optionsOrPort typeof object use it; else form {port:optionsOrPort,endpoint:legacyEndpoint}. Parse endpoint or http://localhost. If port explicitly given OR parsed endpoint.port empty, set port to explicit or7070. Store URL.origin, discarding credentials/path/query/fragment. Explicit standard ports canonicalize away. Source: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:44-56`.
2. resolve: string.replace first occurrence of `${origin}/` with empty (not an anchored URL parser). Split first slash component as documentId. If header exists and createNew===true, empty id→new, interpolate raw id into URL/delta path; no relative suffix. Otherwise encodeURIComponent(id), retain original relativeUrl.slice(rawId.length) as suffix in document URL only. Emit record in order above. No network, token acquisition, cache or events. Source: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:59-96`.
3. getAbsoluteUrl: replace first `${origin}/tinylicious/` in resolvedUrl.url with empty, decodeURIComponent **entire remainder**, return `${decoded}/${relativeUrl}` with no leading-slash normalization. Thus `getAbsoluteUrl(resolved(doc),"/x")`→`doc//x`; existing relative paths in resolvedUrl are retained as part of decoded remainder. Source: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:99-113`.
4. Test endpoint helper: browser hostname regex /^(.+)-\d+\.(.+)$/ match→https://<group1>-7070.<group2>, port443; otherwise localhost/7070. This is generic regex matching, not a github-only suffix allowlist. Source: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:122-148`.

### Container state/order

Factory sets interactive capability=true and Fluid.Container.ForceWriteConnection=true. Runtime loadRuntime2 gets context,registry,provideEntryPoint,existing,oldestSupportedClient, runtimeOptions.enableRuntimeIdCompressor="on". New runtime requires newContainerRootType, creates data store then awaits trySetAlias(rootDataStoreId), asserts Success, returns runtime. createDetached builds codeDetails `{package:"no-dynamic-package",config:{}}`, codeLoader, loader options; awaits container then getEntryPoint, wraps container with id undefined. load uses request `{url:id}`, same code loader without new-root type, awaits entry point, wraps with supplied id, asserts id defined. attach request uses createTinyliciousCreateNewRequest() (empty request url). Source: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/tinyliciousService.ts:80-131`, `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/tinyliciousService.ts:142-211`.

### Required attach path: REST creation precedes socket handshake

New documents transition detached -> creating -> service-created -> connecting -> connected. The resolver's id `new` is a placeholder, **not** a server document. createContainer first requires the combined summary's `.app` and `.protocol` trees, JSON-parses `.protocol/attributes` (`sequenceNumber`, `minimumSequenceNumber`) and `.protocol/quorumValues`, then sends POST O/documents/tinylicious with a tenant-level orderer token (documentId omitted, JWT claim documentId=""). It sends **no id field** even if createTinyliciousCreateNewRequest supplied a name. Tinylicious server selects request.body.id||uuid(), persists via createDocument, and only after success returns201 with JSON string actual id. Failure returns400. Client awaits creation, rewrites both resolved document URL and deltaStorageUrl's final path component, then creates the document service with storage/orderer tokens scoped to **actual id**. Only after that may connectToDeltaStream emit connect_document(id:actualId). connect_document does not replace creation; existing-document load skips the POST and uses the given existing id. `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/documentServiceFactory.ts:140-272`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/documentServiceFactory.ts:285-340`, `reference/fluidframework-3.11.0/server/routerlicious/packages/tinylicious/src/routes/ordering/documents.ts:35-70`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/documentService.ts:199-255`.

Example: resolve create request -> /tinylicious/new and /deltas/tinylicious/new; POST response JSON `"d123"` -> /tinylicious/d123 and /deltas/tinylicious/d123; socket query documentId=d123,tenantId=tinylicious; connect_document id=d123, tenantId=tinylicious, token with documentId=d123. Creation cannot be retried blindly by adding a new POST after a later socket failure: the REST creation has already persisted the document. `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:65-95`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/documentServiceFactory.ts:191-272`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/documentDeltaConnection.ts:39-60`.

### Inherited connection/retry behavior

Early ops/signals queue before handshake and continue until loader reads initial arrays after attaching listeners. Op drain removes early listener, appends/sorts by sequenceNumber only if queued nonempty, no dedup; signal drain appends arrival order. Success checks doc:write permission and requested/actual mode; disconnect sets disposed, removes socket listeners, closes socket then emits local disconnect. Source: `reference/fluidframework-3.11.0/packages/drivers/driver-base/src/documentDeltaConnection.ts:280-318`, `reference/fluidframework-3.11.0/packages/drivers/driver-base/src/documentDeltaConnection.ts:442-471`, `reference/fluidframework-3.11.0/packages/drivers/driver-base/src/documentDeltaConnection.ts:599-656`.

401 refreshes provider(true) once until a429 retry resets the budget; this provider ignores refresh and generates a new UUID identity. Positive429 retryAfter waits seconds*1000, retries indefinitely; terminal mapping passes retryAfter as milliseconds. Socket authorization errors retry once with refreshed provider token. Status401/403 nonretryable authorization,404 fileNotFoundOrAccessDenied,500/502 retryable generic; remaining status retryability requires provided delay except429 always retryable. Shredded summary upload wraps Git calls with runWithRetry, initial wait1000ms then double, cap8000 or60000 when endpointReached=true; no default max retries. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/restWrapper.ts:250-287`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/errorUtils.ts:104-151`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-driver/src/documentService.ts:263-285`, `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousTokenProvider.ts:29-46`, `reference/fluidframework-3.11.0/packages/loader/driver-utils/src/runWithRetry.ts:63-203`.

## Invariants and asserts

0xd4c new root type required; 0xd4d alias result Success; 0xd4e loaded container id defined. Resolver has no explicit assert; invalid URL or malformed percent decoding throws platform JS error. Signing/transport errors propagate. Sources: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/tinyliciousService.ts:91-101`, `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/tinyliciousService.ts:193-196`, `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:52-56`, `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:103-105`.

## JS-semantics hazards

Math.round seconds (positive half ties up), not epoch floor. Empty [] scope override stays empty; nullish checks not truthiness. Preserve claim/header key order for deterministic JWT bytes. Fresh UUID per storage/orderer fetch means identity is not stable across methods. String.replace is first literal occurrence, not URL-origin comparison. URI encode preserves JS encodeURIComponent's punctuation and throws for lone surrogates. URL.origin canonicalization matters for explicit ports. Double slash in absolute URL is intentional output, not path-normalized. Sources: `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousTokenProvider.ts:55-80`, `reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousUrlResolver.ts:44-112`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/test/insecureTinyliciousUrlResolverTest.spec.ts:1-35` starts URL behavior fixtures, including port/endpoint forms. Reuse R11s socket/rest/cache tests because the facade delegates directly (`reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/tinyliciousService.ts:116-121`). Deterministic JWT fixture should inject clock and UUID matching the literal claims example, preserving actual HS256 signing bytes (`reference/fluidframework-3.11.0/packages/drivers/tinylicious-driver/src/insecureTinyliciousTokenProvider.ts:55-80`).

## Open questions

None. Server availability is external; no build or service execution is needed to derive these client contracts.
