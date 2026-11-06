# ODSP compact snapshot (3.11.0)

## Role

This is the `application/ms-fluid` snapshot codec: a ZipIt typed tree containing snapshot metadata, hierarchical path entries, raw blobs and JSON-encoded sequenced operations. It is not ZIP, a compressed JSON document, a varint protocol, or a summary-upload format. Parser output is `ISnapshot` with `snapshotFormatV:1`. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotParser.ts:266-315`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotWriter.ts:152-185`.

## Surface used by other packages

`parseCompactSnapshotResponse(Uint8Array,logger)` returns snapshot plus timing/slow-path counters. `convertToCompactSnapshot(ISnapshot)` produces bytes. `ReadBuffer`, `WriteBuffer`, `TreeBuilder`, `TreeBuilderSerializer`, `NodeCore`, `BlobCore` implement the codec; `NodeCore` defaults to a set, stores ordered children, and offers typed getters, `iteratePairs`, `addNode/addBlob/addString/addDictionaryString/addNumber/addBool`. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotParser.ts:266-315`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotWriter.ts:152-185`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/zipItDataRepresentationUtils.ts:282-379`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/WriteBufferUtils.ts:263-283`.

## Wire and persisted formats

### Complete byte grammar

All codes below are **hex bytes**. All following integers and byte counts are unsigned little-endian positional base-256; there is no continuation bit, padding, alignment or terminator for a scalar. Integer accumulator is a JS number. String lengths count UTF-8 **bytes**, not UTF-16 units or Unicode scalars. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/ReadBufferUtils.ts:44-61`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/WriteBufferUtils.ts:44-53`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/zipItDataRepresentationUtils.ts:26-109`.

| Marker | Meaning | Following bytes |
|---|---|---|
| `01` | zero | none |
| `02`, `03` | Int8, UInt8 | 1 byte magnitude; both decode identically |
| `04`, `05` | Int16, UInt16 | 2 bytes magnitude; both decode identically |
| `06`, `07` | Int32, UInt32 | 4 bytes magnitude; both decode identically |
| `08`, `09` | Int64, UInt64 | 8 bytes magnitude; both decode identically |
| `0b`, `0c` | true, false | none |
| `0d` | empty string | none |
| `0e`, `0f`, `10` | UTF-8 string | length in 1, 2, 4 bytes, then exactly length bytes |
| `11`, `12`, `13` | dictionary string reference | ID in 1, 2, 4 bytes |
| `14` | dictionary declaration | 1-byte ID, 1-byte UTF-8 byte length, then string bytes |
| `15` | big dictionary declaration | 4-byte ID, 4-byte UTF-8 byte length, then string bytes |
| `20` | empty binary blob | none |
| `21`, `22`, `23`, `24` | binary blob | length in 1, 2, 4, 8 bytes, then exactly length raw bytes |
| `31`, `32` | list start, end | nested elements between markers |
| `33`, `34` | set start, end | nested elements between markers |

Every other code, including `00`, `0a`, `16`–`1f`, `25`–`30`, is invalid and throws `Invalid code: <decimal>`. “Signed” marker names do **not** imply sign extension: `02 ff` decodes to 255, not -1. Dictionary declarations modify a document-global dictionary but **do not append an element**; a declaration must be followed by a reference to make a key/value element. Writer IDs start at 1, increase on first use, and are shared across all nested nodes. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/zipItDataRepresentationUtils.ts:428-523`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/WriteBufferUtils.ts:148-189`.

Writer integer width is `calcLength(n)`: zero→0, otherwise count successive floor-divisions by 256, then round that byte count up to the next power of two. Examples: 255→`03 ff`; 256→`05 00 01`; 65536→`07 00 00 01 00`; 4294967296→`09 00 00 00 00 01 00 00 00`. Writer accepts nonnegative integers only. Normal strings use markers 0d/0e/0f/10. Blob bytes are **raw**, despite a misleading base64 comment in the writer. A source defect maps an 8-byte blob-length width to marker **16 decimal (`10`)**, not 36 decimal (`24`); readers accept `24`, but writer's >4GiB representation is not reader-compatible. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/WriteBufferUtils.ts:72-140`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/WriteBufferUtils.ts:191-258`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/zipItDataRepresentationUtils.ts:368-374`.

A dictionary string's first emission is `14 id len utf8 11 id` when both ID and length fit one byte (empty length fits); otherwise it is `15 id:u32 len:u32 utf8 <11|12|13> id`. A big declaration always uses 4-byte ID **and** length, even if only one requires >255. Keys added through either `addStringProperty` or `addDictionaryStringProperty` are dictionary strings, but both helpers add their **value as an ordinary string**. Thus repeated values are not automatically interned. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/WriteBufferUtils.ts:148-189`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/zipItDataRepresentationUtils.ts:239-254`.

### Snapshot tree schema and emission order

Notation `set(k,v,...)` means `33` + alternating key/value elements + `34`; `list(...)` means `31` + elements + `32`. Builder itself has no marker; writer appends one root set. Root in exact order:

```text
set("mrv", "1.0", "cv", "1.0", "lsn", latest,
    "snapshot", set("id", snapshotTree.id,
                    "message", "Snapshot@" + sequenceNumber,
                    "sequenceNumber", sequenceNumber,
                    "treeNodes", list(pathEntries...)),
    "blobs", list(blobEntries...),
    ["deltas", set("firstSequenceNumber", ops[0].sequenceNumber,
                   "deltas", list(JSON.stringify(op0), ...))])
```

All quoted keys above are dictionary strings **except** blob-entry key `data`, which is an ordinary string. Values are ordinary strings or typed nodes/numbers. `latest` is explicit latestSequenceNumber unless undefined, else the last op's sequenceNumber if ops nonempty, else snapshot sequenceNumber; zero is not replaced. Deltas pair is omitted entirely when ops empty. Each blob entry is `set("id",storageBlobId,"data",rawBytes)` in input Map insertion order; IBlob contents decode with encoding or default utf8. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotWriter.ts:30-57`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotWriter.ts:107-185`.

Within each tree, emit Object.entries(trees) first, then Object.entries(blobs). Tree entry order is `name:path`, optional `unreferenced:true` **from the enclosing snapshotTree**, optional `children:list(...)` iff that child has any blobs or subtrees, optional `groupId:child.groupId` iff not undefined (including empty string). Blob entry is `name:path,value:id`. No nodeType is emitted; readers also accept service entries `name,path,nodeType,3,value,id`, without validating the numeric 3 on the fast path. Subtree IDs are not serialized. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotWriter.ts:64-98`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotParser.ts:133-188`.

Version gates are literal: parser reads required string mrv and cv, optional numeric lsn; asserts `parseFloat("1.0") >= parseFloat(mrv)`, `parseFloat(cv) >= parseFloat("1.0")`, and **`cv === "1.0"`**. A semver library is not equivalent (`cv="1.00"` fails). Thus older minimum-read values can be accepted, but only creator version exactly 1.0 is accepted. `snapshotFormatV:1` is an in-memory/cache discriminator distinct from these wire strings. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotParser.ts:29-30`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotParser.ts:274-305`.

### Worked writer-derived hex fixture

Input is `{snapshotTree:{id:"s",trees:{},blobs:{}},blobContents:new Map(),ops:[],sequenceNumber:0}`; lsn defaults to 0. This emits one empty snapshot with no deltas. Lines concatenate; left labels explain bytes and are not part of the stream. Source algorithm: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotWriter.ts:30-185`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/WriteBufferUtils.ts:148-258`.

```text
33                                             root set
14 01 03 6d 72 76 11 01 0e 03 31 2e 30          declare/ref mrv; "1.0"
14 02 02 63 76 11 02 0e 03 31 2e 30             declare/ref cv; "1.0"
14 03 03 6c 73 6e 11 03 01                      declare/ref lsn; zero
14 04 08 73 6e 61 70 73 68 6f 74 11 04 33       snapshot key; nested set
14 05 02 69 64 11 05 0e 01 73                   id; "s"
14 06 07 6d 65 73 73 61 67 65 11 06             message key
0e 0a 53 6e 61 70 73 68 6f 74 40 30             "Snapshot@0"
14 07 0e 73 65 71 75 65 6e 63 65 4e 75 6d 62 65 72 11 07 01
                                               sequenceNumber; zero
14 08 09 74 72 65 65 4e 6f 64 65 73 11 08 31 32 treeNodes; empty list
34                                             end snapshot set
14 09 05 62 6c 6f 62 73 11 09 31 32             blobs; empty list
34                                             end root set
```

For a nonempty scalar contrast, list `"é", bytes[00 ff], 256, true` is `31 0e 02 c3 a9 21 02 00 ff 05 00 01 0b 32`. A dictionary declaration for `"x"` followed by two references is `14 01 01 78 11 01 11 01`, representing two elements, not three. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/WriteBufferUtils.ts:148-258`.

## Behavior

1. Start parser at position 0 with implicit root children, empty stack/dictionary/string-worklist. Start marker appends node, pushes current children and changes destination. End marker pops destination; parser intentionally does not check list-vs-set match. Declaration reads ID and length, records lazy string and assigns dictionary[ID], without appending. Reference requires a prior declaration and appends its shared string object. Scalar strings append lazy objects; blobs retain a slice into the original byte buffer; integer/boolean append values. At EOF require destination is implicit root. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/zipItDataRepresentationUtils.ts:428-525`.
2. Resolve strings in one UTF-8 decode by concatenating each byte range plus NUL, splitting at NUL and assigning results when split count is worklist length+1. Embedded NUL takes `StringParsingError` telemetry path, then asserts uninitialized content equals separately decoded original; this is **not a functioning recovery assignment** and normally fails 0x3ea. Do not silently support this malformed-for-oracle case. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/zipItDataRepresentationUtils.ts:528-571`.
3. Require exactly one builder element, a node; materialize alternating properties (later duplicate key wins), validate versions, read snapshot, read blobs, then optional deltas. Blob fast path requires four elements with keys id/data in slots 0/2; generalized property lookup accepts other orders/unknown fields. Both map duplicate IDs by last write. Deltas JSON.parse each string, and allow empty service deltas; otherwise firstSequenceNumber must equal first op.sequenceNumber. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotParser.ts:45-107`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotParser.ts:266-315`.
4. Tree fast paths: `(name,path)`→empty child; `(name,path,children,node)`→recursive child; `(name,path,value,id)`→blob; six elements name/nodeType/value→blob; name/unreferenced/children→recursive child, require true and set **enclosing tree** unreferenced. General path sets enclosing unreferenced if present/true; `value` takes precedence over `children`; children recurse and attach groupId iff present; otherwise empty child **drops groupId**. Preserve these asymmetries rather than treating metadata as uniformly child-local. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotParser.ts:113-231`.

## Invariants and asserts

Read EOF 0x223; skip nonnegative 0x224 and within buffer 0x3dc. Write remaining magnitude zero 0x226; consumed buffer reuse fails 0x225/0x227. Map key exists 0x287; declared lengths fit 0x283/0x284; node markers defined 0x285/0x286; supported string element 0x3dd. Pair count even 0x22c and complete pair 0x22b; missing dictionary ID 0x3de; balanced structure 0x3e7; all strings copied 0x418; EOF 0x233. Snapshot root count 0x219; version gates 0x20f/0x210/0x2c2; snapshot id/sequence required by writer 0x21b/0x21c; nonnegative integer 0x231/0x232; unreferenced true 0x281/0x3db; first delta matches 0x280. Typed node mismatches throw nonretryable `incorrectServerResponse` with message `Buffer parsing exception: ...` and nodeType/expectedNodeType. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/ReadBufferUtils.ts:44-61`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/WriteBufferUtils.ts:23-61`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/zipItDataRepresentationUtils.ts:111-135`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/zipItDataRepresentationUtils.ts:295-374`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/zipItDataRepresentationUtils.ts:428-663`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotParser.ts:89-315`.

## JS-semantics hazards

UInt64 still accumulates Double and may round above 2^53; do not promise exact arbitrary UInt64 parity. Preserve Map insertion order and JS Object.entries order (integer-like keys first); values are not dictionary-interned even when helper name suggests otherwise. UTF-8 conversion is not Foundation String length. ReadBuffer.freeze freezes the backing ArrayBuffer object, not proof of immutable bytes; Swift must retain correct slice ownership/offset (BlobShallowCopy.arrayBuffer adds typed-array byteOffset). Binary length marker bug, NUL-string failure and parent-local unreferenced behavior are oracle behavior. Sources: `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/ReadBufferUtils.ts:19-55`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/zipItDataRepresentationUtils.ts:206-246`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/zipItDataRepresentationUtils.ts:528-571`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/compactSnapshotWriter.ts:70-98`.

## Test assets to reuse

`reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/zipItDataRepresentationTests.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/snapshotFormatTests.spec.ts:1`, `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/jsonSnapshotFormatTests.spec.ts:1`; local JSON fixtures `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/localSnapshots/localSnapshot1.json:1` and `reference/fluidframework-3.11.0/packages/drivers/odsp-driver/src/test/localSnapshots/localSnapshot2.json:1`. Differential fixtures must exercise integer width boundaries, dictionary ID 255/256, reordered pairs, optional nodeType, empty deltas, groupId on empty/nonempty trees, unreferenced parent, embedded NUL, and typed-array subview offsets.

## Open questions

None. The observed writer/reader asymmetries above are compatibility facts, not assumptions about intended service behavior.
