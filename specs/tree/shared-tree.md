# Shared Tree — Fluid Framework 3.11.0

## 1. Role

SharedTree assembles the change family, edit history, stored-schema repository, forest, repair roots and ID compressor. TreeCheckout is mutable state over a branch, not a second shared channel. TreeView is a schema-aware lifetime/compatibility wrapper over checkout. [shared-tree-core.md](shared-tree-core.md) owns commit-graph rebase and sequencing algebra; [simple-tree.md](simple-tree.md) owns public node/schema semantics. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTree.ts:209-345`

## 2. Surface used by other packages

SharedTreeKernel/factory, `viewWith`, `TreeViewConfiguration`, `SchematizingSimpleTreeView`, `CheckoutBase`/`TreeCheckout`, independent views, `SharedTreeChangeFamily`, `SharedTreeEditBuilder`, serialized changes, history and branch/location APIs. ID compressor is mandatory: factory throws without it. Default forest is reference forest; optimized/expensive-debug are explicit options, not different wire protocols. `reference/fluidframework-3.11.0/packages/dds/tree/src/treeFactory.ts:58-82` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTree.ts:750-769` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/index.ts:6-87`

## 3. Wire and persisted formats

### SharedTree change union

In memory: `{changes:[{type:"data",innerChange:ModularChangeset}|{type:"schema",innerChange:SchemaChange}]}`. Wire is an ordered ARRAY, each item exactly one meaningful property `{data: modularEncoded}` OR `{schema: schemaEncoded}`; no `type`, no local `changes` wrapper and no independent version field here. Empty logical change emits `[]`. In-memory SchemaChange is `{schema:{new:<stored>,old:<stored>},isInverse:boolean}`; WIRE schema payload is `{new:<encodedStored>,old:<encodedStored>}` in new-before-old order, with neither an isInverse property nor a schema wrapper. Inverse schema changes cannot be transmitted (0x933), as specified in [schema-edits.md](schema-edits.md). Parent message/history selects SharedTreeChange 3→modular3, 4→modular4, 5→modular5; schema codec is explicitly self-versioned. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTreeChangeTypes.ts:6-24` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTreeChangeFormat.ts:12-35` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTreeChangeCodecs.ts:107-135`

Concrete encoder-derived empty change is `[]`; a complete schema-only example replacing an empty v1 repository with itself is `[{"schema":{"new":{"version":1,"nodes":{},"root":{"kind":"Forbidden","types":[]}},"old":{"version":1,"nodes":{},"root":{"kind":"Forbidden","types":[]}}}}]`. Nested schema versions follow the configured schema writer. This is a union, not two independently optional effects: decoder rejects zero or multiple discriminants. The complete encoder below fixes the dependent context and emission order, including a schema followed by data in the same op. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTreeChangeCodecs.ts:162-227` `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/discriminatedUnions.ts:6`

### Ordered change encoding and decoding

Literal oracle procedure (comments removed), `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTreeChangeCodecs.ts:147-227`:

```typescript
function makeSharedTreeChangeCodec(
	modularChangeCodec: IJsonCodec<
		ModularChangeset,
		JsonCompatibleReadOnly,
		JsonCompatibleReadOnly,
		ChangeEncodingContext
	>,
	codecOptions: CodecWriteOptions,
): IJsonCodec<
	SharedTreeChange,
	EncodedSharedTreeChange,
	EncodedSharedTreeChange,
	ChangeEncodingContext
> {
	const schemaChangeCodec = makeSchemaChangeCodec(codecOptions);
	const decoderLibrary = new DiscriminatedUnionDispatcher<
		EncodedSharedTreeInnerChange,
		[context: ChangeEncodingContext],
		SharedTreeInnerChange
	>({
		data(encoded, context): SharedTreeInnerChange {
			return {
				type: "data",
				innerChange: modularChangeCodec.decode(encoded, context),
			};
		},
		schema(encoded): SharedTreeInnerChange {
			return {
				type: "schema",
				innerChange: schemaChangeCodec.decode(encoded),
			};
		},
	});
	return withSchemaValidation(
		EncodedSharedTreeChange(schemaChangeCodec.encodedSchema),
		{
			encode: (change, context) => {
				const changes: EncodedSharedTreeInnerChange[] = [];
				let updatedSchema: TreeStoredSchema | undefined;
				for (const decodedChange of change.changes) {
					if (decodedChange.type === "data") {
						const schemaAndPolicy =
							updatedSchema === undefined
								? context.schema
								: {
										policy:
											context.schema === undefined
												? defaultSchemaPolicy
												: context.schema.policy,
										schema: updatedSchema,
									};
						changes.push({
							data: modularChangeCodec.encode(decodedChange.innerChange, {
								originatorId: context.originatorId,
								schema: schemaAndPolicy,
								idCompressor: context.idCompressor,
								revision: context.revision,
								isSummary: context.isSummary,
							}),
						});
					} else if (decodedChange.type === "schema") {
						changes.push({
							schema: schemaChangeCodec.encode(decodedChange.innerChange),
						});
						updatedSchema = decodedChange.innerChange.schema.new;
					}
				}
				return changes;
			},
			decode: (encodedChange, context) => {
				const changes: Mutable<SharedTreeChange["changes"]> = [];
				for (const subChange of encodedChange) {
					changes.push(decoderLibrary.dispatch(subChange, context));
				}
				return { changes };
			},
		},
		codecOptions.jsonValidator,
	);
}
```

### Summary layout, blob by blob

Paths below are relative to the SharedTree DDS kernel summary, not the container's `.channels` hierarchy. Outer SharedObject/runtime attributes are not tree content. Full summary emits `.metadata` before component payload; component traversal order is EditManager, Schema, Forest, DetachedFieldIndex. Unchanged components may instead be summary handles to their prior paths. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sharedTreeCore.ts:177-180` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sharedTreeCore.ts:221-239` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sharedTreeCore.ts:260-291` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/versionedSummarizer.ts:81-97`

```text
.metadata                              {"version":2}
indexes/
  EditManager/
    .metadata                          {"version":2}
    String                             edit-manager JSON payload
  Schema/
    .metadata                          {"version":2}
    SchemaString                       stored-schema JSON payload
  Forest/
    .metadata                          {"version":2} or {"version":3}
    ForestTree                         forest JSON, layout 1/2 only
    contents                           forest JSON, layout 3 only
    <chunkReferenceId>/                layout 3 incremental chunks, if present
      contents                         this chunk's inline forest JSON
      <childChunkReferenceId>/...       recursive chunk subtrees
  DetachedFieldIndex/
    .metadata                          {"version":2}
    DetachedFieldIndexBlob             detached-index JSON payload
```

Layout 1 is pre-versioning and can have no `.metadata`. Schema and detached-index layout selection are separate from payload codec versions; baseline versioned component metadata is 2. Forest layout selects 2 before minimum collaboration 2.74, 3 at/after 2.74; read layouts 1/2/3. Nonincremental layout 3 stores the entire forest in `contents`; incremental layout 3 stores inline content plus nested chunk trees or summary handles. Blob strings are produced by the supplied serializer; handles inside tree content are serialized by Fluid serializer, not ordinary JSONEncoder. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/summaryTypes.ts:18-23` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/summaryTypes.ts:91-110` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryTypes.ts:21-42` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryFormatCommon.ts:11-41` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryFormatV3.ts:7-18` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/schemaSummarizer.ts:82-87` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/detachedFieldIndexSummarizer.ts:94-103`

Payloads are not duplicated here: [shared-tree-core.md](shared-tree-core.md) defines String's trunk/branches/history messages, [schema-index.md](schema-index.md) defines SchemaString, [forest-summary.md](forest-summary.md) and [chunked-forest.md](chunked-forest.md) define ForestTree/contents and nested chunk references, [core.md](core.md) defines DetachedFieldIndexBlob. The literal paths and layout gates above compose those formats; no component may be regenerated merely from visible root data. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTree.ts:242-320`

### Complete baseline golden blob example

The committed full-tree fixture below represents a parent label "foo" and two child counts. Every content string below is literal JSON blob content, not a paraphrased tree. This also fixes field/property insertion order. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/shared-tree/summary-load-snapshots/singleTree-Compressed-v2_0-1.json:1`

`.metadata`
```json
{"version":2}
```

`indexes/EditManager/.metadata`
```json
{"version":2}
```

`indexes/EditManager/String`
```json
{"trunk":[],"branches":[],"version":3}
```

`indexes/Schema/.metadata`
```json
{"version":2}
```

`indexes/Schema/SchemaString`
```json
{"version":1,"nodes":{"com.fluidframework.leaf.number":{"leaf":0},"com.fluidframework.leaf.string":{"leaf":1},"test schema.child":{"object":{"count":{"kind":"Value","types":["com.fluidframework.leaf.number"]}}},"test schema.nodes":{"object":{"":{"kind":"Sequence","types":["test schema.child"]}}},"test schema.parent":{"object":{"child":{"kind":"Value","types":["test schema.nodes"]},"label":{"kind":"Value","types":["com.fluidframework.leaf.string"]}}}},"root":{"kind":"Value","types":["test schema.parent"]}}
```

`indexes/Forest/.metadata`
```json
{"version":2}
```

`indexes/Forest/ForestTree`
```json
{"keys":["rootFieldKey"],"fields":{"version":1,"identifiers":[],"shapes":[{"c":{"type":"test schema.parent","value":false,"fields":[["label",1],["child",2]]}},{"c":{"type":"com.fluidframework.leaf.string","value":true}},{"c":{"type":"test schema.nodes","value":false,"fields":[["",3]]}},{"a":4},{"c":{"type":"test schema.child","value":false,"fields":[["count",5]]}},{"c":{"type":"com.fluidframework.leaf.number","value":true}}],"data":[[0,"foo",[1,2]]]},"version":1}
```

`indexes/DetachedFieldIndex/.metadata`
```json
{"version":2}
```

`indexes/DetachedFieldIndex/DetachedFieldIndexBlob`
```json
{"version":1,"data":[],"maxId":4}
```


## 4. Behavior

### Change-family compose, inverse and concurrent schema transitions

Compose flattens tagged changes in input order, collecting adjacent data changes. Before EVERY schema item it flushes the accumulated data run through modular compose, appends the schema item unchanged, clears the run; flushes again at end. It never composes data across a schema boundary. Inverse maps data through modular invert with isRollback/revision, maps schema to swapped old/new and isInverse=true, then reverses ALL subchanges. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTreeChangeFamily.ts:128-201`

Rebase has a deliberately severe schema rule: if EITHER change list is empty, return source unchanged; otherwise, if EITHER contains a schema subchange, return `{changes:[]}`. No concurrent schema change is supported, even a widening one; do not implement a plausible Swift merge policy that makes it survive. Otherwise require exactly one data subchange on each side (0x884/0x885), invoke modular rebase with revision metadata and ignoreNoChangeViolation, wrap one data result. A nonconcurrent shared history optimization avoids rebasing already shared changes, so this is not a blanket prohibition on sequential data after a schema edit. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTreeChangeFamily.ts:203-253`

Empty changes classify as implicit constraint violation; any data subchange with positive constraintViolationCount classifies explicit violation; otherwise satisfied. Refreshers across a schema-separated data run are not independently regenerated: first data change requires all roots; later changes filter already included roots and tolerate unavailable roots removed earlier in this change, because the forest will retain them during application. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTreeChangeFamily.ts:295-368` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTreeChangeFamily.ts:405-435`

### Construction and load

1. Merge defaults/options; retainHistory must be boolean or nonnegative safe integer; minVersionForCollab below 2.0 throws.
2. Create schema repository, configured forest, repair index named `repair`, schema/field-batch codecs and their summarizers, revision codec, detached-index summarizer, SharedTreeChangeFamily and mitigation wrapper.
3. Construct core with schema/forest/repair summarizers; construct checkout against its local branch and same schema/forest/repair objects; register main as shared branch and editable checkout.
4. Load component metadata; reject unsupported layout or missing metadata when pre-versioning support is false. Start edit-manager and remaining component loads; attached loading awaits all. Detached loading waits edit-manager first, updates detachedRevision to latest negative sequenced revision if any, then awaits remaining loads. Schema load requires empty existing schema before applying decoded schema (0x3da). `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTree.ts:214-345` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/versionedSummarizer.ts:100-120` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sharedTreeCore.ts:294-320` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/schemaSummarizer.ts:124-141`

### View state transitions

States: alive+compatible (root readable/editable), alive+incompatible (compatibility readable, root unavailable), disposed (no further operations). `viewWith` permits one schematized context per checkout; incompatible creation does not initialize the document. Initialize is permitted only when schema AND forest are empty; it sets schema and content together inside the schema-edit path. Required-root initialization first applies an intermediate OPTIONAL root schema with the same types/metadata, inserts content, then applies the required root schema through the explicit non-superset initialization path; optional/sequence/forbidden roots already tolerate empty and use the new schema directly. Forbidden root initialization requires zero nodes (0xd67); optional root initializer accepts at most one (0x7f4). Upgrade requires canUpgrade; it only widens the permitted stored document language, not a content migration. Stored schema change disposes old flex view, recomputes compatibility and enabled staged upgrades, installs context iff canView, emits schemaChanged then rootChanged. Upgrade batches suppress intermediate view events and flush hydration before final events. Disposal removes listeners/context; local branch view may own checkout lifetime, main view does not destroy the shared channel. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/tree.ts:84-103` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/schematizingTreeView.ts:328-435` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/schematizingTreeView.ts:530-717` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/schematizeTree.ts:6-137`

### Checkout changes and event order

Branch active afterChange → lock → beforeBatch → for each data subchange derive delta and visit forest/anchors/repair index; for schema subchange apply new schema then log schema metrics → afterBatch → unlock → validate newly appended commits. Main-branch append additionally creates change metadata and a synchronous revertible factory, then emits locked `changed`; view forwards changed then commitApplied. Factory is valid only inside this emission, only once per revision; schema-containing commits have no revertible factory. Rebase-driven remote changed metadata has isLocal=false and default kind; local append isLocal=true even when produced by local merge. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1135-1275` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1457-1496` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/schematizingTreeView.ts:285-303`

Local commit settled maps Satisfied→FullyApplied, ImplicitViolation→FullyDropped, ExplicitViolation→NewContentOnly, emits under edit lock, then deletes emitter. This is not a universal Boolean success acknowledgement. Revertible owns a retained branch and must be disposed to release history. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1100-1133` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1160-1184`

### Fork, rebase and merge

Fork checks alive, rejects open transaction, forks commit branch, clones schema, creates separate breaker and forest clone, clones repair data, shares change family/ID compressor/revision minting, then emits fork. Thus fork isolation includes schema and removed content, not just JSON visible root. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1738-1767`

`A.rebaseOnto(B)` calls B's internal rebase(A): source A must not be a shared branch; alive/lock/transaction restrictions apply, then underlying A branch rebases onto B. The result updates A's checkout by its effective branch change. B is unchanged. `A.merge(B,disposeMerged=true)` checks both alive, target unlocked and BOTH transaction depths zero, merges B into A (rebasing B's edits onto A history), then disposes B only if requested AND B is not shared. Repeated shared history is not appended twice. Lack of common ancestor is an error, not permission for replacing a snapshot. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1917-1952` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1954-2016`

### Transactions and constraints

The stack owns nested transaction branches; edits apply to checkout immediately while submission is withheld. Start checkpoints removed roots. Abort restores that checkpoint THEN applies rollback viewUpdate if any. Commit applies viewUpdate if any, then automatically validates outermost squash commit once depth reaches zero. Nested labels form a tree; outermost completion clears the live label tree, while metadata retains a snapshot. Fork and merge reject pending transactions. The public callback transitions and node/no-change constraints are fully specified in [simple-tree.md](simple-tree.md); the literal mounting/unmounting procedure follows. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1043-1080` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:995-1020`

### Transaction mount, constraint and result order

Literal oracle procedure/declaration, `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1386-1454`:

```typescript
	private mountTransaction(
		params: RunTransactionParamsAlpha | undefined,
		isAsync: boolean,
	): void {
		this.checkNotDisposed();
		this.editLock.checkUnlocked("Running a transaction");
		if (isAsync && this.transaction.size > 0) {
			throw new UsageError(
				"An asynchronous transaction cannot be started while another transaction is already in progress.",
			);
		}
		this.pushLabelFrame(params?.label);
		this.transaction.start({
			postProcessor: extractTransactionChangeProcessor(params?.postProcessor),
			customMetadata: this.snapshotCustomMetadata(params),
		});

		addConstraintsToTransaction(this, false, params?.preconditions);
	}

	private unmountTransaction<TSuccessValue, TFailureValue>(
		transactionCallbackStatus:
			| TransactionCallbackStatusAlpha<TSuccessValue, TFailureValue>
			| VoidTransactionCallbackStatusAlpha
			| void,
		params: RunTransactionParamsAlpha | undefined,
	): TransactionValueResult<TSuccessValue, TFailureValue> | TransactionVoidResult {
		this.checkNotDisposed();
		const rollback = transactionCallbackStatus?.rollback;
		const value = (
			transactionCallbackStatus as TransactionCallbackStatusAlpha<TSuccessValue, TFailureValue>
		)?.value;

		if (rollback === true) {
			this.popLabelFrame(true);
			this.transaction.abort();
			return value === undefined
				? { success: false }
				: { success: false, value: value as TFailureValue };
		}

		addConstraintsToTransaction(this, true, transactionCallbackStatus?.preconditionsOnRevert);

		this.popLabelFrame(false);
		this.runWithTransactionLabel(() => {
			this.transaction.commit();
		}, params?.label);
		return value === undefined
			? { success: true }
			: { success: true, value: value as TSuccessValue };
	}


	private applyInternalChange(change: SharedTreeChange, revision?: RevisionTag): void {
		for (const innerChange of change.changes) {
			if (innerChange.type === "data") {
```

## 5. Invariants and asserts

New schema must permit every old document (0xbe6), except explicit internal non-superset/inverse paths. Shared branches cannot rebase (0xa5d). Duplicate component keys fail core construction. Mutation exceptions are fail-stop through Breakable/mitigated family; an incoming algebra failure must stop processing rather than submit a guessed repair. A callback exception is not proof of rolled-back state in the newer API. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1941-1947` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:2018-2029` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sharedTreeCore.ts:234-238` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTree.ts:294-314`

## 6. JS-semantics hazards

Preserve synchronous nested event dispatch and listener registration order. Keep the graph's revision IDs separate from sequence numbers and tree identifiers. Clone/copy-on-write forest chunks without aliasing mutable schema/repair indexes. Do not conflate child payload codec version with `.metadata` layout. The wire union's property absence is significant, and schema→data order changes data encoding context. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTreeChangeCodecs.ts:178-220` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1738-1767`

## 7. Test assets to reuse

Shared-tree checkout/view integration, transaction nesting, schema-change, fork/merge/rebase and summary roundtrip suites under `src/test/shared-tree`; summary snapshots under `src/test/snapshots`; codec golden families under `src/test/codec`. Include detached-load negative revisions, summary component handles, local optimistic edit rebased over schema rollback, schema+data same op, abort restoring repair IDs and held revertibles across merges. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/sharedTreeCore.ts:305-318` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1466-1480`

## 8. Open questions

None for these boundaries and formats. Commit-graph and field algebra details are in their separately owned specs, not reimplemented here.

