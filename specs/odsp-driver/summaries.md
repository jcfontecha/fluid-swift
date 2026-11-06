# ODSP summary upload

## Role

OdspSummaryUploadManager turns runtime SummaryObjects into ODSP recursive snapshot entries, resolves prior-summary handles, and POSTs a proposal. Storage manager coordinates relay flush before single-commit summaries and final renaming after initial empty-file creation. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspSummaryUploadManager.ts:42-155`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentStorageManager.ts:729-818`.

## Surface used by other packages

`writeSummaryTree(tree,context)->Promise<string>` consumes ISummaryContext `{ackHandle?:string,proposalHandle?:string,referenceSequenceNumber:number}`; storage calls it from uploadSummaryWithContext. Returned string is response id/proposal handle, not an ack. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspSummaryUploadManager.ts:57-84`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentStorageManager.ts:786-818`.

## Wire and persisted formats

POST `<snapshotStorageUrl>/snapshot`, Content-Type application/json, Authorization full auth header, epoch/correlation added by tracker. If relay identity defined, `If-Match: fluid:sessionid=<tenantId>/<sessionId>` plus `;containerid=<ackHandle>` iff parentHandle truthy. No header when relay identity undefined. Exact body insertion order `{entries:[...],message:"app",sequenceNumber:referenceSequenceNumber,type:"container"|"channel"}`. Type container iff combined app+protocol summary OR ackHandle===undefined; otherwise channel. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspSummaryUploadManager.ts:87-126`.

Recursive value tree is `{type:"tree",entries:Entry[]}`. Entry value form has insertion order `{value:Value,path:key,type:"tree"|"blob",unreferenced?:true,groupId?:string}`; handle/attachment entry is `{path:key,type:GitType,id:string}`. Value blob is `{type:"blob",content:string,encoding:"utf-8"|"base64"}` in that order. String blobs retain string exactly, typed bytes base64. Undefined fields are omitted by JSON.stringify. Tree unreferenced emitted when MarkUnreferencedNodes setting (default true) allows it; groupId always propagated if defined. Keys are raw, not URI-encoded, and cannot contain `/`. Response `{id:string}`; missing/falsy id throws `Failed to write summary tree`. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/contracts.ts:71-111`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspSummaryUploadManager.ts:168-278`.

Concrete channel example (parent `p`, ref=7, string blob h=`hi`, prior tree handle `/old`, attachment a=`attachment-id`):

```http
POST S/snapshot
Content-Type: application/json
Authorization: Bearer TOKEN
If-Match: fluid:sessionid=t/session;containerid=p

{"entries":[{"value":{"type":"blob","content":"hi","encoding":"utf-8"},"path":"h","type":"blob"},{"path":"reuse","type":"tree","id":"p/.app/old"},{"path":"a","type":"blob","id":"attachment-id"}],"message":"app","sequenceNumber":7,"type":"channel"}
```

Example subtree with binary blob `00 ff`: `{"value":{"type":"tree","entries":[{"value":{"type":"blob","content":"AP8=","encoding":"base64"},"path":"b","type":"blob"}]},"path":"store","type":"tree","unreferenced":true,"groupId":"g"}`. Source: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspSummaryUploadManager.ts:198-278`.

## Behavior

1. If lastSummaryProposalHandle defined and differs from context.proposalHandle, log LastSummaryProposedHandleMismatch only; no actual dedup cache restoration occurs here. Convert tree recursively in Object.keys order; rootNodeName remains `.app` at every recursion. Tree recurse→copy unreferenced/groupId→accumulate blob count. Blob choose string/base64. Handle requires truthy parentHandle, prepend `/` to nonempty relative handle, then id=`parentHandle/.app<handlePath>` (empty handle→`parent/.app`). Attachment id passes through verbatim. Unknown SummaryType unreachable. Build/push entry after child conversion. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspSummaryUploadManager.ts:57-78`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspSummaryUploadManager.ts:168-278`.
2. Token-refresh wrapper obtains auth with exact request URL/method, adds If-Match, JSON.stringify once per attempt; tracker fetchAndParseAsJSON uploadSummary. Require truthy returned id, set lastSummaryProposalHandle=id only after success, return. A failed proposal leaves previous handle. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspSummaryUploadManager.ts:74-154`.
3. Storage sets lazy summary-module promise before flush. If `.protocol` property exists in summary.tree and ackHandle!==undefined: call flush; seq defined>=reference ends loop. Otherwise if retry>3 log FlushFailure and **continue upload anyway**; else log FlushExtraCall, increment retry, wait `(retryAfter??1)*1000`. This allows **4 flush calls**, not 3, and no independent timeout in socket flush. Flush rejection propagates. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentStorageManager.ts:733-771`.
4. After upload, if pendingRename defined and disablePendingRename!==true, assert initial context (ack/proposal undefined, ref=0), call renameEmptyFluidFile, clear pendingRename then set fileName=response.name. Rename failure rejects even though summary upload already succeeded; last manager proposal remains updated. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentStorageManager.ts:786-818`.

## Invariants and asserts

0x9cd every child key contains no slash; handle with no parent throws `Parent summary does not exist to reference by handle.`; 0x0ad value/id cannot coexist; falsy absent id/value throws Invalid tree entry. Summary manager initialized 0x56e; pending rename initial-context 0xa88. HTTP 412 is nonretryable (wrong parent; same payload cannot fix it). Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspSummaryUploadManager.ts:185-278`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentStorageManager.ts:786-803`, `reference/fluidframework-3.11.0/packages/utils/odsp-doclib-utils/src/odspErrorUtils.ts:332-340`.

## JS-semantics hazards

Undefined ackHandle versus empty string affects payload type differently from truthy-parent handle validation and If-Match suffix. Preserve raw string JSON escaping/number formatting and object insertion order; Foundation encoder order is not the oracle. markUnreferencedNodes parameter is not passed explicitly to recursive call, so every recursion reevaluates config default. Flush result code alone does not decide success: sequence threshold does. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspSummaryUploadManager.ts:98-123`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspSummaryUploadManager.ts:168-237`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/odspDocumentStorageManager.ts:741-770`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/odspSummaryUploadManager.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/socketTests/deltaConnectionUpdateTests.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/odspCreateContainer.spec.ts:1`. Add literal JSON goldens covering binary, handles with/without leading slash, undefined/empty parent, metadata, failed upload and post-upload rename failure.

## Open questions

None.
