# routerlicious-urlResolver — Swift port contract (3.11.0)

## Role

Converts example-host/request URLs into Routerlicious Fluid document URLs and service endpoints, with optional nconf configuration overriding tenant/document and service routing. Produces resolver records only; neither HTTP nor socket.io is called. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:22-139`.

## Surface used by other packages

`RouterliciousUrlResolver(config:{provider:Provider,tenantId:string,documentId:string}|undefined,getToken:()=>Promise<string>,hostUrl:string)`; `resolve(request:IRequest):Promise<IResolvedUrl|undefined>` and `getAbsoluteUrl(resolvedUrl,relativeUrl):Promise<string>`. `IAlfredUser` extends IUser.id:string with displayName:string,name:string. `IConfig={serverUrl:string,blobStorageUrl:string,tenantId:string,documentId:string}` is an exported configuration type but constructor uses provider, not IConfig. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:22-34`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:142-179`.

## Wire and persisted formats

No persisted data, REST calls, token refresh policy or socket events in this package. It awaits getToken once per accepted resolution and places the returned string in resolved.tokens.jwt. There is no memoization. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:34-139`.

Output object insertion order (required by the TS type; malformed short paths can produce undefined id at runtime, as described under Behavior):

```text
{
 endpoints:{storageUrl:string,deltaStorageUrl:string,ordererUrl:string},
 id:string,
 tokens:{jwt:string},
 type:"fluid",
 url:string
}
```

No deltaStreamUrl is emitted. Optional config does not add a field to output. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:128-138`.

Concrete no-config localhost example: request.url=`http://localhost:3000/documents/t/doc?x=1`, getToken→abc:

```json
{"endpoints":{"storageUrl":"http://localhost:3001/repos/t","deltaStorageUrl":"http://localhost:3003/deltas/t/doc","ordererUrl":"http://localhost:3003"},"id":"doc","tokens":{"jwt":"abc"},"type":"fluid","url":"https://localhost:3003/t/doc?x=1"}
```

Notice Fluid URL is HTTPS although local service URLs HTTP. getAbsoluteUrl of that record, relative `/a`, hostUrl=`http://localhost:3000/documents`, returns `http://localhost:3000/documents/t/doc/a`. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:74-93`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:114-138`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:142-159`.

No-config hosted example request `https://www.wu2.prague.office-int.com/documents/t/doc` gives storage `https://historian.wu2.prague.office-int.com/repos/t`, orderer `https://alfred.wu2.prague.office-int.com`, delta `https://alfred.wu2.prague.office-int.com/deltas/t/doc`, Fluid URL `https://wu2.prague.office-int.com/t/doc`. `tokens={jwt:returnedToken}`, id doc. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:13-17`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:77-85`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:119-138`.

## Behavior

### Resolve state transitions and execution order

Stateless states: input→URL-parsed→accepted/rejected→token-pending→resolved (or thrown). No event emissions. Every step below follows TS execution order (`reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:34-139`).

1. requestedUrl=request.url. If config truthy AND request.url.startsWith("/"), prepend literal http://dummy:3000. Otherwise leave request unchanged. Parse WHATWG new URL; malformed/relative without config throws, not undefined. Lowercase parsed hostname (`reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:35-43`).
2. Accept iff hostname in exact set `www.wu2-ppe.prague.office-int.com`, `www.wu2.prague.office-int.com`, `www.eu.prague.office-int.com`, OR hostname localhost AND port exactly3000, OR config truthy. Rejected parsed URL returns undefined **without calling getToken** (`reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:13-17`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:45-54`).
3. path=pathname.split("/"). With config use its tenantId,documentId,provider verbatim; else if path.length>=4 use path[2] tenant and path[3] document; else tenant="fluid", document=path[2]. No decoding/empty-id validation; extra trailing segments ignored. Missing path[2] can become JS undefined despite declared string type; encodeURIComponent(undefined) becomes literal undefined in URL. Output id can be undefined at runtime and omitted by JSON.stringify (`reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:56-70`).
4. Await getToken now, before any provider service settings read. Rejection propagates. isLocalHost iff server==localhost, isInternalRequest iff server.includes("gateway"). suffix local localhost:3003 else server.slice(4), blindly removing first four characters even for arbitrary configured hosts (`reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:72-77`).
5. Build fluidUrl `https://<config ? new URL(provider.get("worker:serverUrl")).host : suffix>/<encodeURIComponent(tenantId)>/<encodeURIComponent(documentId)>`. Append reqUrl.search unchanged if nonempty; no fragment or document-relative path appended (`reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:79-93`).
6. Choose endpoint branch in table; then storageUrl += `/repos/${tenantId}` without encoding. Build output above, return (`reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:95-139`).

| Predicate, in precedence order | storage base | orderer | delta URL |
|---|---|---|---|
| provider truthy AND server.includes gateway | provider.get worker:internalBlobStorageUrl | provider.get worker:alfredUrl | same alfred value + /deltas/enc(tenant)/enc(doc) |
| provider truthy | provider.get worker:blobStorageUrl then first literal historian:3000→localhost:3001 | provider.get worker:serverUrl | orderer + /deltas/enc(tenant)/enc(doc) |
| server==localhost | http://localhost:3001 | http://localhost:3003 | http://localhost:3003/deltas/rawTenant/rawDoc |
| otherwise | https://historian.<server.slice(4)> | https://alfred.<server.slice(4)> | https://alfred.<server.slice(4)>/deltas/rawTenant/rawDoc |

After every branch append /repos/rawTenant to storage base. No trailing-slash cleanup. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:99-126`.

Configured example: tenant `a b`, doc `c/d`, provider worker:serverUrl=http://gateway:3000, internalBlobStorageUrl=http://historian:3000, alfredUrl=http://alfred:3000, request http://gateway:3000/x?q=1:

```json
{"endpoints":{"storageUrl":"http://historian:3000/repos/a b","deltaStorageUrl":"http://alfred:3000/deltas/a%20b/c%2Fd","ordererUrl":"http://alfred:3000"},"id":"c/d","tokens":{"jwt":"abc"},"type":"fluid","url":"https://gateway:3000/a%20b/c%2Fd?q=1"}
```

This is plain string output; spaces in storageUrl are not normalized until a later URL consumer. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:60-64`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:79-105`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:124-138`.

### getAbsoluteUrl

Parse resolvedUrl.url; assert truthy pathname; destructure [,tenantId,documentId] from pathname.split("/"); assert both truthy. Remove exactly one initial `/` from relativeUrl when present. Return `${hostUrl}/${encodeURIComponent(tenantId)}/${encodeURIComponent(documentId)}/${relative}`. No decode, no query propagation, no slash normalization of hostUrl or relative remainder. Therefore resolved pathname `/a%20b/c%2Fd` becomes hostUrl `/a%2520b/c%252Fd/` for empty relative; relative //x leaves //x after final join; hostUrl trailing slash produces double separator. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:142-159`.

## Invariants and asserts

getAbsoluteUrl 0x0b9 pathname exists, 0x0ba tenant truthy, 0x0bb document truthy. Invalid WHATWG URL or percent encoding (e.g. lone surrogate in configured id passed encodeURIComponent) throws; no catch/retry. resolve itself has no asserts on path segment counts beyond branch selection. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:42-70`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:79-85`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:146-159`.

## JS-semantics hazards

WHATWG hostname lowercases/canonicalizes; localhost with absent port is rejected without config; acceptance requires the explicit nonstandard port3000. URL.pathname retains percent escapes; encodeURIComponent re-encodes `%`, so preserving double encoding is required. Dot segments are normalized by URL before split. Configured relative requests use dummy host, therefore do not enter gateway/internal routing even if configured serverUrl uses gateway. String.replace changes only first occurrence; no global hostname rewrite. Undefined document segment is not empty string or null and JSON.stringify omits undefined output id. getToken called after rejection filter but before provider lookup errors. Source: `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:35-85`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:99-138`, `reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:146-159`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/test/routerlicious-urlResolver.spec.ts:1-35` begins fixtures for hosted/local/configured resolver behaviors; use exact generated endpoint and absolute-url strings. Include accepted-host rejection without token call, internal gateway config, malformed URL errors and re-encoding of already escaped pathname (`reference/fluidframework-3.11.0/packages/drivers/routerlicious-urlResolver/src/urlResolver.ts:34-159`).

## Open questions

None. Tokens are host-supplied opaque strings; this package does not define token-fetch HTTP or claim validation.
