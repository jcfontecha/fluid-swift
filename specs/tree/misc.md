# Miscellaneous Tree Support — Fluid Framework 3.11.0

## 1. Role

This file covers packaged JSON/Fluid-serializable schemas, extensible unions, tables, sandbox host/guest synchronization, and support utilities. These compose normal tree nodes and checkout operations; none replaces the field CRDT. Sandboxing is a separate structured-clone transport protocol, not a new service op format. `reference/fluidframework-3.11.0/packages/dds/tree/src/jsonDomainSchema.ts:32-63` `reference/fluidframework-3.11.0/packages/dds/tree/src/serializableDomainSchema.ts:35-68` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/README.md:1`

## 2. Surface used by other packages

`JsonAsTree`, `FluidSerializableAsTree`, `ExtensibleUnionNode.createSchema`, `TableSchema.column/row/table`; sandbox Host, Guest and transport/session/synchronization implementations; utilities for branded IDs, compressed-ID codecs, ID allocation, reference counting, ordered/nested/range collections, offset lists, string pieces/sequences, snapshot reads and Breakable. Nominal and conditional typing and API-extractor workarounds are TS-only; schema identifiers, constraints, ownership and iteration behavior remain normative. `reference/fluidframework-3.11.0/packages/dds/tree/src/extensibleUnionNode.ts:60-166` `reference/fluidframework-3.11.0/packages/dds/tree/src/tableSchema.ts:1621-2168` `reference/fluidframework-3.11.0/packages/dds/tree/src/util/index.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/index.ts:6`

## 3. Wire and persisted formats

### Packaged domain trees

JsonAsTree admits null, number, string, boolean and recursively `com.fluidframework.json.object` (record) / `com.fluidframework.json.array`. FluidSerializableAsTree scope is `com.fluidframework.serializable`, object/array names identical, allowed leaves additionally Fluid handle. Nodes encode using ordinary stored schema and forest codecs. JSON object field order is explicitly not preserved by this domain; scalar number precision remains JavaScript Double. Concise import/export omits type tags; e.g. `{"items":[null,3,"x"]}` produces a record field items with a typed array containing those three leaves. A handle remains an opaque handle leaf, not a record of its implementation properties. `reference/fluidframework-3.11.0/packages/dds/tree/src/jsonDomainSchema.ts:32-88` `reference/fluidframework-3.11.0/packages/dds/tree/src/jsonDomainSchema.ts:115-149` `reference/fluidframework-3.11.0/packages/dds/tree/src/serializableDomainSchema.ts:31-83` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/conciseTree.ts:20-39`

Extensible union schema has one optional field per known type T, developer key `"_"+T.identifier`, STORED key exactly `T.identifier`; wrapper object permits unknown optional fields. Example known type `demo.A` with child {x:1}: public construction `{ "_demo.A": A({x:1}) }`; persisted wrapper field is `"demo.A"`, not `_demo.A`. Unknown populated optional fields must survive. This is not an enum discriminator plus a single `value` field. `reference/fluidframework-3.11.0/packages/dds/tree/src/extensibleUnionNode.ts:121-166`

Table types use customized `com.fluidframework.tableV2<userScope>` scope. Column object `Column` fields `id` (identifier), `props`; Row `Row` fields `id`, `cells` (required record `Row.cells`, keys column IDs), `props`. TableRoot public property `table` stores under `""` and holds object `Table` with required `rows` array `Table.rows` and `columns` array `Table.columns`. TableRoot/Row/Column allow unknown optional fields; inner Table does not. Default props schema is optional null. Example logical empty persisted tree is TableRoot {empty-key: Table {rows: Table.rows [], columns: Table.columns []}}; cells are sparse row-local entries, not a dense matrix, and no row/column index is persisted in a cell. `reference/fluidframework-3.11.0/packages/dds/tree/src/tableSchema.ts:185-222` `reference/fluidframework-3.11.0/packages/dds/tree/src/tableSchema.ts:330-377` `reference/fluidframework-3.11.0/packages/dds/tree/src/tableSchema.ts:503-549` `reference/fluidframework-3.11.0/packages/dds/tree/src/tableSchema.ts:1478-1482` `reference/fluidframework-3.11.0/packages/dds/tree/src/tableSchema.ts:1699-1706`

### Sandbox transport vocabulary

The boundary carries null/undefined/Boolean/number/string, arrays, plain records, ArrayBuffer and authorized handle tokens. This is structured clone, NOT JSON.stringify: undefined and buffers cross intact. Handle marker is `{"type":"__sandbox_handle__","token":0}`; ordinary records colliding with either reserved marker are escaped as `{"type":"__sandbox_object__","entries":[["type","__sandbox_handle__"],["token",0]]}`. Escape reconstruction preserves the root as DATA, never interprets it as another marker, and rejects duplicate property names. Received records are null-prototype. Raw received buffers become identity-registered placeholders locally; `{arrayBufferMarker:true}` is not authority to unwrap a buffer. `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/transport.ts:25-146` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/common.ts:173-264`

Protocol outer object contains exactly ONE key from Host→Guest: hostInitialization, hostUpdate, hostIdRange, guestChangeAck, blobResponse, blobResponseError, sessionFailure; Guest→Host: hostUpdateAck, guestChange, blobRequest, sessionFailure. Every envelope and message rejects additional fields. ID counters are nonnegative safe integers; generation counts on ranges are positive safe integers; revision is "root" or integer. Exact nested payload declarations follow; Type.Readonly has no wire effect, Type.Optional means absent property is accepted, Type.Literal fixes the literal. `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/common.ts:342-681`

### Complete shard/range and protocol payload schemas

Literal declarations (comments removed), `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/common.ts:364-669`:

```typescript
const IdSpaceShardSessionId = TypeSystem.Type<SessionId>(
	"Sandbox.IdSpaceShardSessionId",
	(_schema, value) => typeof value === "string" && isStableId(value),
)();
const GuestIdSpaceShardToken = Type.Object(
	{
		shardId: IdSpaceShardSessionId,
		localGenCount: NonNegativeSafeInteger,
		disposed: Type.Literal(false),
	},
	{ additionalProperties: false },
);
const ParentIdSpaceShardSyncToken = Type.Object(
	{
		type: Type.Literal("parentIdSpaceShardSyncToken"),
		shardId: IdSpaceShardSessionId,
		localGenCount: NonNegativeSafeInteger,
	},
	{ additionalProperties: false },
);
const FinalizedIdRange = Type.Object(
	{
		sessionId: IdSpaceShardSessionId,
		ids: Type.Object(
			{
				firstGenCount: PositiveSafeInteger,
				count: PositiveSafeInteger,
				requestedClusterSize: PositiveSafeInteger,
				localIdRanges: Type.Array(Type.Tuple([PositiveSafeInteger, PositiveSafeInteger])),
			},
			{ additionalProperties: false },
		),
	},
	{ additionalProperties: false },
);
export type HostInitializationMessage = Static<typeof HostInitializationMessage>;
const HostInitializationMessage = Type.Object(
	{
		baseRevision: Type.Readonly(SessionRevisionTag),
		mainRevision: Type.Readonly(SessionRevisionTag),
		trunkRevision: Type.Readonly(SessionRevisionTag),
		tree: Type.Readonly(SerializedTreePayload),
		schema: Type.Readonly(SerializedTreePayload),
		commits: Type.Readonly(SerializedTreeCommits),
		idCompressor: Type.Readonly(Type.String()),
	},
	{ additionalProperties: false },
);
export type HostUpdateMessage = Static<typeof HostUpdateMessage>;
const HostUpdateMessage = Type.Object(
	{
		updateId: Type.Readonly(HostUpdateId),
		baseRevision: Type.Readonly(SessionRevisionTag),
		mainRevision: Type.Readonly(SessionRevisionTag),
		trunkRevision: Type.Readonly(SessionRevisionTag),
		commits: Type.Readonly(SerializedTreeCommits),
		parentIdSpaceShardSyncToken: Type.Readonly(ParentIdSpaceShardSyncToken),
	},
	{ additionalProperties: false },
);
export type HostIdRangeMessage = Static<typeof HostIdRangeMessage>;
const HostIdRangeMessage = Type.Object(
	{
		rangeId: Type.Readonly(HostIdRangeId),
		parentIdSpaceShardSyncToken: Type.Readonly(ParentIdSpaceShardSyncToken),
		range: Type.Readonly(FinalizedIdRange),
	},
	{ additionalProperties: false },
);
export type HostUpdateAckMessage = Static<typeof HostUpdateAckMessage>;
const HostUpdateAckMessage = Type.Object(
	{
		updateId: Type.Readonly(HostUpdateId),
	},
	{ additionalProperties: false },
);
export type GuestChangeMessage = Static<typeof GuestChangeMessage>;
const GuestChangeMessage = Type.Object(
	{
		changeId: Type.Readonly(GuestChangeId),
		mainRevision: Type.Readonly(SessionRevisionTag),
		trunkRevision: Type.Readonly(SessionRevisionTag),
		change: Type.Readonly(SerializedTreePayload),
		idSpaceShardToken: Type.Readonly(GuestIdSpaceShardToken),
	},
	{ additionalProperties: false },
);
export type GuestChangeAckMessage = Static<typeof GuestChangeAckMessage>;
const GuestChangeAckMessage = Type.Object(
	{
		changeId: Type.Readonly(GuestChangeId),
	},
	{ additionalProperties: false },
);
export type SessionFailureMessage = Static<typeof SessionFailureMessage>;
const SessionFailureMessage = Type.Object(
	{
		code: Type.Enum(SandboxFailureCode),
		protocolMessage: Type.Optional(Type.String()),
		sensitiveMessage: Type.Optional(Type.String()),
	},
	{ additionalProperties: false },
);
export type BlobRequestMessage = Static<typeof BlobRequestMessage>;
const BlobRequestMessage = Type.Object(
	{
		requestId: Type.Readonly(BlobRequestId),
		token: Type.Readonly(HandleToken),
	},
	{ additionalProperties: false },
);
const BlobSuccessMessage = Type.Object(
	{
		requestId: Type.Readonly(BlobRequestId),
		blob: Type.Readonly(RegisteredBufferPlaceholder),
	},
	{ additionalProperties: false },
);
const BlobErrorMessage = Type.Object(
	{
		requestId: Type.Readonly(BlobRequestId),
		error: Type.Readonly(Type.String()),
	},
	{ additionalProperties: false },
);
export type HostToGuestMessage = Static<typeof hostToGuestMessageSchema>;
const hostToGuestMessageSchema = Type.Object(
	{
		hostInitialization: Type.Optional(HostInitializationMessage),
		hostUpdate: Type.Optional(HostUpdateMessage),
		hostIdRange: Type.Optional(HostIdRangeMessage),
		guestChangeAck: Type.Optional(GuestChangeAckMessage),
		blobResponse: Type.Optional(BlobSuccessMessage),
		blobResponseError: Type.Optional(BlobErrorMessage),
		sessionFailure: Type.Optional(SessionFailureMessage),
	},
	unionOptions,
);
export type GuestToHostMessage = Static<typeof guestToHostMessageSchema>;
const guestToHostMessageSchema = Type.Object(
	{
		hostUpdateAck: Type.Optional(HostUpdateAckMessage),
		guestChange: Type.Optional(GuestChangeMessage),
		blobRequest: Type.Optional(BlobRequestMessage),
		sessionFailure: Type.Optional(SessionFailureMessage),
	},
	unionOptions,
);
```

Concrete complete message examples:
```json
{"hostUpdateAck":{"updateId":0}}
{"guestChangeAck":{"changeId":0}}
{"blobRequest":{"requestId":0,"token":0}}
{"blobResponseError":{"requestId":0,"error":"not a blob"}}
{"sessionFailure":{"code":"protocolViolation","protocolMessage":"Invalid Host and Guest protocol message."}}
```
Blob success has requestId then `blob:ArrayBuffer` (not JSON). Failure codes are `protocolViolation`, `applicationUsageError`, `processingFailure`; protocolMessage and sensitiveMessage are optional strings; peer diagnostic text does not become a trusted local error message. `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/common.ts:39-43` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/common.ts:95-122` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/common.ts:551-642`

Serialized commits used in sandbox carry envelope version 2; encode property order `version`, `revision`, `originatorId`, `change`, optional `customMetadata`. `change` uses newest supported SharedTree change codec, independently of envelope version and usual production writer floor. Decode first requires serialized format v2, then REQUIRES originatorId equal to the destination compressor’s localSessionId, constructs change context with decoded revision, decodes change and custom metadata. It is same-SharedTree transport, not arbitrary cross-document replay. Child ID-shard synchronization makes sandbox session IDs consistent before applying it. A complete no-op form is `{"version":2,"revision":"root","originatorId":"00000000-0000-4000-8000-000000000001","change":[]}` (schema-shaped illustration; a live commit must supply its actual valid revision/session context). Application custom metadata is recursively encoded as compact m/c nodes, defined in the existing core spec. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/serializedChange.ts:46-73` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/serializedChange.ts:179-246`

### Utility encodings

Possibly compressed ID is `string | number`. Non-stable strings pass through; stable UUID that compressor cannot recompress stays string. Recompressible UUID normalizes to OP space; originator-dependent may use local negative IDs with supplied originator session, whereas originatorless writes a number only when op ID is final, else original string. Example arbitrary `"external-key"` remains `"external-key"`; a finalized compressor ID 42 encodes `42`, not `"42"`. Numeric decode must normalize to session space; final numeric magnitude alone is not a local ID. `reference/fluidframework-3.11.0/packages/dds/tree/src/util/compressedIds.ts:79-152`

OffsetList is an array mixing numeric skips and nonnumeric content. Factory coalesces skips, omits zero and trailing skip, emits positive accumulated skip only before content. Example pushOffset(2), pushOffset(3), pushContent({x:1}), pushOffset(4) gives `[5,{"x":1}]`. It is an internal sparse representation whose caller determines whether it is persisted. `reference/fluidframework-3.11.0/packages/dds/tree/src/util/offsetList.ts:6-45`

## 4. Behavior

### Extensible union and domain schemas

Union `isValid` counts ALL nonempty underlying fields, including unknown, and returns count==1. `union` first throws if invalid, then returns first known child exposed by TreeAlpha.children; a valid unknown variant yields undefined, not invalid. `create(child)` obtains its runtime schema and constructs the matching optional field. Do not discard unknown variants or require every valid union to be expressible by a closed Swift enum. JSON/serializable schema recursion is lazy and type workarounds are not extra schema nodes. `reference/fluidframework-3.11.0/packages/dds/tree/src/extensibleUnionNode.ts:139-166` `reference/fluidframework-3.11.0/packages/dds/tree/src/jsonDomainSchema.ts:115-149`

### Table operations and concurrency constraints

create gathers columns/rows, validates unique IDs within inputs AND against existing tables on insert, and rejects cells referencing missing column IDs. No constructor-time API may bypass those checks. Lookup by index uses current order; by ID uses lazy ID→node caches; node argument must be the exact node in that table (an equal ID from a different tree fails). Cache invalidation occurs on array nodeChanged for insertion/removal/move, listener registered once. `reference/fluidframework-3.11.0/packages/dds/tree/src/tableSchema.ts:552-599` `reference/fluidframework-3.11.0/packages/dds/tree/src/tableSchema.ts:1136-1285` `reference/fluidframework-3.11.0/packages/dds/tree/src/tableSchema.ts:1334-1410`

| Operation | Ordered edit | Constraint before commit / on revert |
|---|---|---|
| insertColumns | validate index and IDs; insert at gap (default end); return inserted now-hydrated nodes | none / noChange |
| insertRows | validate rows and cells; constrain referenced existing columns; insert | nodeInDocument for distinct referenced columns / none |
| setCell | resolve row/column; assign row.cells[column.id] | column exists / column exists only if replacing populated cell |
| removeColumns | validate selection; delete matching cell keys row-by-row, then remove column nodes | noChange / none |
| removeRows | validate selection; remove row nodes | none / nodeInDocument for referenced columns |
| removeCell | resolve; if absent return undefined; delete key then return prior cell | none / column exists |

All table hydrated edits execute as transactions with the specified constraints; unhydrated edits run directly and do not fabricate a checkout. Removing a zero-length selection returns [] without an edit. List-based removals first resolve every ID/node, deduplicate in caller insertion order, compute contiguous current-array ranges, delete those ranges highest-index first, and return nodes in deduplicated caller order; index forms use [start,start+count), omitted count means rest. Constraints are intentionally conservative: noChange may reject unrelated intervening changes. Do not weaken them to a local validation-only check. `reference/fluidframework-3.11.0/packages/dds/tree/src/tableSchema.ts:634-982` `reference/fluidframework-3.11.0/packages/dds/tree/src/tableSchema.ts:1043-1128`

### Table batching and referenced-column constraint generation

Literal declarations/procedure (comments removed), `reference/fluidframework-3.11.0/packages/dds/tree/src/tableSchema.ts:1043-1128`:

```typescript
			#applyEditsInBatch(options: {
				applyEdits: () => void;
				preconditions?: readonly TransactionConstraintAlpha[];
				preconditionsOnRevert?: readonly TransactionConstraintAlpha[];
			}): void {
				const { applyEdits, preconditions, preconditionsOnRevert } = options;
				const context = TreeAlpha.context(this);
				withBufferedTreeEvents(() => {
					if (context.isView()) {
						context.runTransaction(
							() => {
								applyEdits();
								if (preconditionsOnRevert !== undefined) {
									return { preconditionsOnRevert };
								}
							},
							preconditions === undefined ? undefined : { preconditions },
						);
					} else {
						applyEdits();
					}
				});
			}
			#buildColumnInDocumentConstraintsForRows(
				rows: Iterable<RowValueType>,
			): TransactionConstraintAlpha[] | undefined {
				if (!TreeAlpha.context(this).isView()) {
					return undefined;
				}
				const referencedColumnIds = new Set<string>();
				for (const row of rows) {
					const cells = (row as RowValueInternalType).cells;
					if (cells === undefined) {
						continue;
					}
					for (const id of Object.keys(cells)) {
						referencedColumnIds.add(id);
					}
				}
				if (referencedColumnIds.size === 0) {
					return undefined;
				}
				const columnCache = this.#getColumnCache();
				const constraints: TransactionConstraintAlpha[] = [];
				for (const id of referencedColumnIds) {
					const column = columnCache.get(id) ?? fail(0xd05 );
					constraints.push({ type: "nodeInDocument", node: column });
				}
				assert(
					constraints.length > 0,
					0xd06 ,
				);
				return constraints;
			}
```

### Sandbox session states and synchronization transitions

Endpoint states Active, Failed, Disposed. run in Active invokes breaker synchronously; any thrown value becomes SandboxSessionError. First failure: store failure → stop synchronization/reject pending work → optionally send fixed sessionFailure without invoking failed codec → close port → queueMicrotask(report). Received failure uses notifyPeer=false (no echo). Failed/Disposed→run is no-op. dispose is idempotent, stops/rejects if no prior failure, closes port; does not resume or silently recreate. Tree references retained by app are not made safe by this fail-stop boundary. `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/session.ts:70-182`

Host initialization forks an authoring checkout, captures retained finalized base plus following commits, then sends compressed base tree/schema, serialized child compressor, commits and base/main/trunk revisions. Guest reconstructs snapshot and replays commits; it retains a Host mirror branch and a separate authoring checkout. Merely loading the visible root would lose the rebase base. ID shard support requires runtime oldestSupportedClient >=3.4.0; it is a prerequisite, not a tree codec version number. `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/hostSynchronization.ts:133-163` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/host.ts:328-387` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/guest.ts:209-272` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/sandboxing.ts:15-24`

Host main change/sequencing→send update only when head OR finalized boundary differs. Find common ancestor with previous sent head; assign next safe update ID; retain exact sent branch and trunk; serialize commits BEFORE capturing parent shard sync token; send update. Pending→acknowledged only when ACK matches OLDEST pending update; rebase host authoring mirror onto exact sent snapshot, update acknowledged main/trunk, delete/dispose retained snapshot; resolve pending promise only when all pending gone. This exact-snapshot rule matters if a revision rebases while packet is in flight. `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/hostSynchronization.ts:211-230` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/hostSynchronization.ts:276-313`

Guest local changed→send only if isLocal; serialize change first (serialization may mint IDs), read live child token next, assign ID/store pending then send main/trunk basis and token. Host receive→require next changeId, increment counter, require basis matches ACKNOWLEDGED main/trunk, authorize/import child token, apply serialized change on guest-basis checkout, merge copy into main WITHOUT disposing guest checkout, then ACK. Guest ACK removes pending known ID (unknown rejects); when set empty clear/resolve promise. Guest ACK processing does not demand FIFO ordering, unlike Host update ACK processing. `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/guestSynchronization.ts:130-172` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/hostSynchronization.ts:170-205` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/guestSynchronization.ts:314-330`

Guest HostUpdate→validate next updateId, increment, apply monotonic matching parent sync token BEFORE decoding revisions/commits, replace Host branch suffix at retained known base, validate declared main head and trunk ancestor, set main/trunk, rebase guest authoring checkout over host mirror, then ACK. Finalized ranges have their own ordered counter and sync token; apply parent token first, finalize range, advance range counter only after success. Missing/duplicate updates/ranges, unknown bases, wrong shard, backward generation counts are terminal protocol errors. `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/guestSynchronization.ts:183-310`

Host token authorization is session-local by absolute handle path; equal paths share token and restore original host handle. Guest only returns handles originating in that session; get() caches one resolution promise INCLUDING failure and cannot attach graph. Blob request authorizes token synchronously, resolves asynchronously, accepts ArrayBuffer only (not Fluid object handles); guest verifies outstanding request ID before unwrapping registered buffer. Foreign token/duplicate response fails protocol. Stop rejects all pending requests. `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/hostTransport.ts:20-95` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/guestTransport.ts:21-180` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/host.ts:209-243`

Transport encode/decode always copies restricted graphs before protocol validation. It rejects cyclic structures, unsupported prototypes/accessors/symbol keys and custom buffer properties; ordinary collision records are escaped. Protocol schema validation is ALWAYS interpreted even if main SharedTree uses no-op validation. This isolation boundary is not enforced by Swift Codable alone. `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/transport.ts:156-292` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/common.ts:298-313`

### Utilities that affect correctness

ID allocator starts max=-1; allocate(count default1) asserts >0, returns previous max+1, then increases max by count. State object is shared with allocator; do not copy it when reconstructing one. ReferenceCountedBase starts count1; add increments, remove decrements then asserts >=0 (0x4c4), invokes onUnreferenced exactly when count becomes zero; isShared means >1. ARC is not a substitute for chunk ownership/COW counts. `reference/fluidframework-3.11.0/packages/dds/tree/src/util/idAllocator.ts:27-41` `reference/fluidframework-3.11.0/packages/dds/tree/src/util/referenceCounting.ts:41-68`

Breakable is a permanent invalidation boundary: healthy use succeeds; break records first Error and throws it; same Error can bubble through nested breakers unchanged; a different error after broken invokes use and throws UsageError referring to original cause. run checks healthy before callback; synchronous throw breaks, native Promise rejection breaks, resolution rechecks healthy before returning. This does not serialize concurrent tasks. throwIfBroken checks but doesn't mark new errors broken; breakingMethod does. `reference/fluidframework-3.11.0/packages/dds/tree/src/util/breakable.ts:45-135` `reference/fluidframework-3.11.0/packages/dds/tree/src/util/breakable.ts:166-210`

StringPiece/StringSequence maintain immutable backing text and atom boundaries; checkpoints every64 atoms, backing pieces at most4096 visible UTF-16 units without splitting a valid pair. Adjacent separately supplied surrogate halves remain TWO atoms even if joined fullString now looks like one scalar. Slice shares immutable storage and preserves boundaries; do not join then resegment after concatenate. RangeMap stores sorted nonoverlapping start/length/value entries, supplies holes as undefined, adjusts value via offsetValue when cutting/querying within an entry; integer specialization supplies integer offset/subtract. Branded/nested maps/sets and stack iterators are internal collection conveniences; preserve traversal order and missing-entry semantics, not JS class scaffolding. `reference/fluidframework-3.11.0/packages/dds/tree/src/util/stringStorage.ts:6-36` `reference/fluidframework-3.11.0/packages/dds/tree/src/util/stringStorage.ts:44-145` `reference/fluidframework-3.11.0/packages/dds/tree/src/util/rangeMap.ts:12-95` `reference/fluidframework-3.11.0/packages/dds/tree/src/util/rangeMap.ts:401-442` `reference/fluidframework-3.11.0/packages/dds/tree/src/util/nestedMap.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/util/stackyIterator.ts:6`

readSnapshotBlob reads storage bytes and UTF-8 decodes before caller parsing; never parse a handle's implementation object. cloneWithReplacements/objMerge are construction helpers, not alternate summary serialization. Pure TS brands, opaque types, type-check utilities and TypeBox brands do not create wire wrappers. `reference/fluidframework-3.11.0/packages/dds/tree/src/util/readSnapshotBlob.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/util/cloneWithReplacements.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/util/objMerge.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/util/brand.ts:6`

## 5. Invariants and asserts

Union validity is exactly one nonempty stored field. Table row/column IDs must be unique; populated cells must reference a live column, with transaction and inverse constraints preserving this across concurrency. Host branch updates require common ancestry (0xd65), guest branch base must remain ancestor (0xd5d); guest edits require live child shard (0xd5b/0xd5c). Refcount cannot become negative (0x4c4); ID count must be positive (0x5cf); originatorless compressed ID must resolve as final at runtime (0xd0a). `reference/fluidframework-3.11.0/packages/dds/tree/src/extensibleUnionNode.ts:151-155` `reference/fluidframework-3.11.0/packages/dds/tree/src/tableSchema.ts:1334-1410` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/hostSynchronization.ts:281-283` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/guestSynchronization.ts:145-151` `reference/fluidframework-3.11.0/packages/dds/tree/src/util/compressedIds.ts:114-125`

## 6. JS-semantics hazards

Do not use Swift closed enums to discard unknown union/schema fields. Keep handle authorization separate from integer shape validation. Decode restricted transport values before invoking schema codecs; preserve undefined, null, empty and absent distinctly. Keep safe-integer counters and monotonic generation progress distinct from JS Double leaves. Don't run terminal error report inline inside tree callbacks (oracle queues a microtask). Don't collapse text piece boundaries, or ARC ownership into semantic chunk references. `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/session.ts:162-176` `reference/fluidframework-3.11.0/packages/dds/tree/src/sandboxing/common.ts:140-170` `reference/fluidframework-3.11.0/packages/dds/tree/src/util/stringStorage.ts:16-21`

## 7. Test assets to reuse

`src/test/extensibleUnionNode.spec.ts`, `tableSchema.spec.ts`; JSON/serializable-domain tests; `src/test/shared-tree/sandboxing/{transport,common,sandboxing,idCompressorCompatibility}.spec.ts`; utility tests for compressedIds, stringStorage, reference counting, rangeMap and offsetList. Critical mixed-client cases: unknown sole union member, invalid zero/two members, cell creation concurrent with column removal and inverse edits, rebased in-flight Host snapshot ACK, guest local negative IDs, out-of-order/duplicate protocol counters, marker collisions and duplicate escaped keys, fake buffer placeholder, foreign handle, failing cached blob resolution, separate surrogate halves joined after construction. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/extensibleUnionNode.spec.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/test/tableSchema.spec.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/test/shared-tree/sandboxing/idCompressorCompatibility.spec.ts:1`

## 8. Open questions

None for these protocol and domain contracts. Native process/IPC choice may differ from MessagePort, but if it interoperates with the TS sandbox it must retain these envelopes, authorization boundaries and ordering.

