# Core — Fluid Framework 3.11.0

## 1. Role

Core defines the representation boundary shared by field algorithms, forests and history: revision/atom identity, stored schema, synchronous tree cursors, delta execution, anchors and detached-root bookkeeping. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/index.ts:6`

## 2. Surface used by other packages

Port `ChangeFamily`/`ChangeRebaser`, `TaggedChange`, `GraphCommit`, revision metadata/replacers; `MapTree`, `ITreeCursorSynchronous`, tree/field up-paths; `TreeStoredSchema`/repository and node-schema classes; `DeltaRoot`, `DeltaVisitor`, `applyDelta`; `AnchorSet`; `DetachedFieldIndex`. These are internal imports used across the package, exposed by `reference/fluidframework-3.11.0/packages/dds/tree/src/core/index.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/index.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/change-family/changeFamily.ts:36` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/changeRebaser.ts:41`

## 3. Wire and persisted formats

Revision = session-space compressed numeric ID OR literal `"root"`; wire revision = op-space ID OR `"root"`. Encode normalizes to op space; decode normalizes to session space using the message originator session. Atom = `{revision?,localId}`; encoded atom is bare localId when revision missing or equal to encoding context revision, otherwise `[localId,encodedRevision]`. The bare form decodes with context revision, not necessarily nil. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/types.ts:40` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/revisionTagCodec.ts:24` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/changeAtomIdCodec.ts:24`

Tree data: node has schema identifier `type`, optional primitive/handle/null `value`, ordered map of field key → ordered child array. Empty fields are omitted by MapTree normalization. Stored schema: root field plus node-schema map; field schema `{kind,types}`; node variant is object-field record, map field schema, or leaf enum. Persisted leaf values are Number=0, String=1, Boolean=2, FluidHandle=3, Null=4. V2 wraps node union in `{kind,metadata?}`, adds field metadata; schema-index owns outer version. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/mapTree.ts:15` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/formatV1.ts:49` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/formatV2.ts:26`

Detached index JSON, emission order: `{version,data,maxId}`. Each data entry is `[major,minor,root]` for a single root or `[major,[[minor,root],...]]` otherwise. Preserve nested-map iteration order; these are individual roots, not `[start,count]` ranges despite the type name. `maxId` can start at -1. V1 only root/final numeric majors; V2 additionally emits stable UUID for an unfinalized major and recompresses it on load. Undefined major cannot be summarized (0x88e/0xbfb). V1 baseline; V2 minimum 2.52; both readable. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecCommon.ts:37` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecV1.ts:29` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecV2.ts:24` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecs.ts:22`

Detached component layout is independently v2 (`.metadata` + `DetachedFieldIndexBlob`), accepts layout v1 and missing metadata; a missing detached-index blob is permitted. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/detachedFieldIndexSummarizer.ts:68` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/detachedFieldIndexSummarizer.ts:118`


### Decision procedure: `core/rebase/revisionTagCodec.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/revisionTagCodec.ts:1-40`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class RevisionTagCodec
	implements JsonCodecPart<RevisionTag, typeof RevisionTagSchema, ChangeEncodingContext>
{
	public localSessionId: SessionId;
	public readonly encodedSchema = RevisionTagSchema;
	public constructor(private readonly idCompressor: IIdCompressor) {
		this.localSessionId = idCompressor.localSessionId;
	}
	public encode(tag: RevisionTag): EncodedRevisionTag {
		return tag === "root"
			? tag
			: (this.idCompressor.normalizeToOpSpace(tag) as EncodedRevisionTag);
	}
	public decode(tag: EncodedRevisionTag, context: ChangeEncodingContext): RevisionTag {
		if (tag === "root") {
			return tag;
		}
		assert(
			typeof tag === "number",
			0x88d  ,
		);
		return this.idCompressor.normalizeToSessionSpace(tag, context.originatorId);
	}
}
```

### Decision procedure: `core/schema-stored/formatV1.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/formatV1.ts:1-92`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type FieldKey = Brand<string, "tree.FieldKey">;
export const FieldKeySchema = brandedStringType<FieldKey>();
export type TreeNodeSchemaIdentifier<TName extends string = string> = Brand<
	TName,
	"tree.TreeNodeSchemaIdentifier"
>;
export type FieldKindIdentifier = Brand<string, "tree.FieldKindIdentifier">;
export const FieldKindIdentifierSchema = brandedStringType<FieldKindIdentifier>();
export const TreeNodeSchemaIdentifierSchema = brandedStringType<TreeNodeSchemaIdentifier>();
const FieldSchemaFormatBase = Type.Object({
	kind: FieldKindIdentifierSchema,
	types: Type.Array(TreeNodeSchemaIdentifierSchema),
});
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
export type FieldSchemaFormat = Static<typeof FieldSchemaFormat>;
export const FieldSchemaFormat = Type.Composite([FieldSchemaFormatBase], noAdditionalProps);
export enum PersistedValueSchema {
	Number,
	String,
	Boolean,
	FluidHandle,
	Null,
}
export type TreeNodeSchemaDataFormat = Static<typeof TreeNodeSchemaDataFormat>;
export const TreeNodeSchemaDataFormat = Type.Object(
	{
		object: Type.Optional(Type.Record(Type.String(), FieldSchemaFormat)),
		map: Type.Optional(FieldSchemaFormat),
		leaf: Type.Optional(Type.Enum(PersistedValueSchema)),
	},
	unionOptions,
);
```

### Decision procedure: `core/schema-stored/formatV2.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/formatV2.ts:1-82`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type PersistedMetadataFormat = Static<typeof PersistedMetadataFormat>;
export const PersistedMetadataFormat = Type.Optional(
	Type.Unsafe<JsonCompatibleReadOnlyObject>(
		Type.Record(Type.String(), JsonCompatibleReadOnlySchema),
	),
);
const FieldSchemaFormatBase = Type.Object({
	kind: FieldKindIdentifierSchema,
	types: Type.Array(TreeNodeSchemaIdentifierSchema),
	metadata: PersistedMetadataFormat,
});
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
export type FieldSchemaFormat = Static<typeof FieldSchemaFormat>;
export const FieldSchemaFormat = Type.Composite([FieldSchemaFormatBase], noAdditionalProps);
export const TreeNodeSchemaUnionFormat = Type.Object(
	{
		object: Type.Optional(Type.Record(Type.String(), FieldSchemaFormat)),
		map: Type.Optional(FieldSchemaFormat),
		leaf: Type.Optional(Type.Enum(PersistedValueSchema)),
	},
	unionOptions,
);
export type TreeNodeSchemaUnionFormat = Static<typeof TreeNodeSchemaUnionFormat>;
export type TreeNodeSchemaDataFormat = Static<typeof TreeNodeSchemaDataFormat>;
export const TreeNodeSchemaDataFormat = Type.Object(
	{
		kind: TreeNodeSchemaUnionFormat,
		metadata: PersistedMetadataFormat,
	},
	noAdditionalProps,
);
```

### Decision procedure: `core/tree/detachedFieldIndexCodecCommon.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecCommon.ts:1-85`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function makeDetachedFieldIndexCodecFromMajorCodec<
	TEncodedRevisionTag,
	TEncodedRevisionTagSchema extends TSchema,
	TVersion extends DetachedFieldIndexFormatVersion,
>(
	majorCodec: IJsonCodec<Major, TEncodedRevisionTag>,
	version: TVersion,
	encodedRevisionTagSchema: TEncodedRevisionTagSchema,
) {
	const formatSchema = Format(version, encodedRevisionTagSchema);
	return {
		schema: formatSchema,
		encode: (data: DetachedFieldSummaryData): Static<typeof formatSchema> => {
			const rootsForRevisions: EncodedRootsForRevision[] = [];
			for (const [major, innerMap] of data.data) {
				const encodedRevision = majorCodec.encode(major);
				const rootRanges: RootRanges = [];
				for (const [minor, detachedField] of innerMap) {
					rootRanges.push([minor, detachedField.root]);
				}
				if (hasSingle(rootRanges)) {
					const firstRootRange = rootRanges[0];
					const rootsForRevision: EncodedRootsForRevision = [
						encodedRevision,
						firstRootRange[0],
						firstRootRange[1],
					];
					rootsForRevisions.push(rootsForRevision);
				} else {
					const rootsForRevision: EncodedRootsForRevision = [encodedRevision, rootRanges];
					rootsForRevisions.push(rootsForRevision);
				}
			}
			const encoded: Static<typeof formatSchema> = {
				version,
				data: rootsForRevisions,
				maxId: data.maxId,
			};
			return encoded;
		},
		decode: (parsed: Static<typeof formatSchema>): DetachedFieldSummaryData => {
			const map = new Map();
			for (const rootsForRevision of parsed.data) {
				const innerMap = new Map<number, DetachedField>();
				if (rootsForRevision.length === 2) {
					for (const [minor, root] of rootsForRevision[1]) {
						innerMap.set(minor, { root });
					}
				} else {
					innerMap.set(rootsForRevision[1], { root: rootsForRevision[2] });
				}
				const revision = rootsForRevision[0] as TEncodedRevisionTag;
				map.set(majorCodec.decode(revision), innerMap);
			}
			return {
				data: map,
				maxId: parsed.maxId,
			};
		},
	};
}
```

### Decision procedure: `core/tree/detachedFieldIndexCodecV1.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecV1.ts:1-81`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
class MajorCodec implements IJsonCodec<Major, EncodedRevisionTag> {
	public constructor(
		private readonly revisionTagCodec: RevisionTagCodec,
		private readonly idCompressor: IIdCompressor,
	) {}
	public encode(major: Major): EncodedRevisionTag {
		assert(major !== undefined, 0x88e  );
		const id = this.revisionTagCodec.encode(major);
		assert(
			id === "root" || isFinalId(id),
			0x88f  ,
		);
		return id;
	}
	public decode(major: EncodedRevisionTag): RevisionTag {
		assert(
			major === "root" || isFinalId(major),
			0x890  ,
		);
		return this.revisionTagCodec.decode(major, {
			originatorId: this.revisionTagCodec.localSessionId,
			idCompressor: this.idCompressor,
			revision: undefined,
			isSummary: true,
		});
	}
}
export function makeDetachedNodeToFieldCodecV1(
	revisionTagCodec: RevisionTagCodec,
	idCompressor: IIdCompressor,
): CodecAndSchema<DetachedFieldSummaryData> {
	const majorCodec = new MajorCodec(revisionTagCodec, idCompressor);
	return makeDetachedFieldIndexCodecFromMajorCodec(
		majorCodec,
		brand(DetachedFieldIndexFormatVersion.v1),
		RevisionTagSchema,
	);
}
```

### Decision procedure: `core/tree/detachedFieldIndexCodecV2.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecV2.ts:1-70`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
class MajorCodec implements IJsonCodec<Major> {
	public constructor(
		private readonly revisionTagCodec: RevisionTagCodec,
		private readonly idCompressor: IIdCompressor,
	) {}
	public encode(major: Major): EncodedRevisionTag | StableId {
		assert(major !== undefined, 0xbfb  );
		const id = this.revisionTagCodec.encode(major);
		if (id !== "root" && !isFinalId(id)) {
			assert(major !== "root", 0xbfc  );
			const long = this.idCompressor.decompress(major);
			return long;
		}
		return id;
	}
	public decode(major: EncodedRevisionTag | StableId): RevisionTag {
		assert(
			major === "root" ||
				(typeof major === "string" && isStableId(major)) ||
				(typeof major === "number" && isFinalId(major)),
			0xbfd  ,
		);
		if (typeof major === "string" && isStableId(major)) {
			return this.idCompressor.recompress(major);
		}
		return this.revisionTagCodec.decode(major, {
			originatorId: this.revisionTagCodec.localSessionId,
			idCompressor: this.idCompressor,
			revision: undefined,
			isSummary: true,
		});
	}
}
export function makeDetachedNodeToFieldCodecV2(
	revisionTagCodec: RevisionTagCodec,
	idCompressor: IIdCompressor,
): CodecAndSchema<DetachedFieldSummaryData> {
	const majorCodec = new MajorCodec(revisionTagCodec, idCompressor);
	return makeDetachedFieldIndexCodecFromMajorCodec(
		majorCodec,
		DetachedFieldIndexFormatVersion.v2,
		StableOrFinalRevisionTag,
	);
}
```

### Decision procedure: `core/tree/detachedFieldIndexCodecs.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecs.ts:1-41`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
type BuildData = ICodecOptions & {
	readonly revisionTagCodec: RevisionTagCodec;
	readonly idCompressor: IIdCompressor;
};
export const detachedFieldIndexCodecBuilder = VersionDispatchingCodecBuilder.build(
	"DetachedFieldIndex",
	[
		{
			minVersionForCollab: lowestMinVersionForCollab,
			formatVersion: DetachedFieldIndexFormatVersion.v1,
			codec: (buildData: BuildData) =>
				makeDetachedNodeToFieldCodecV1(buildData.revisionTagCodec, buildData.idCompressor),
		},
		{
			minVersionForCollab: FluidClientVersion.v2_52,
			formatVersion: DetachedFieldIndexFormatVersion.v2,
			codec: (buildData: BuildData) =>
				makeDetachedNodeToFieldCodecV2(buildData.revisionTagCodec, buildData.idCompressor),
		},
	],
);
```

### Decision procedure: `core/tree/detachedFieldIndexFormatCommon.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexFormatCommon.ts:1-84`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const DetachedFieldIndexFormatVersion = strictEnum("DetachedFieldIndexFormatVersion", {
	v1: 1,
	v2: 2,
});
export type DetachedFieldIndexFormatVersion = Values<typeof DetachedFieldIndexFormatVersion>;
export const DetachId = Type.Integer();
export const ForestRootIdSchema = brandedIntegerType<ForestRootId>({
	minimum: -1,
});
export const RootRange = Type.Tuple([
	DetachId,
	ForestRootIdSchema,
]);
export type RootRange = Static<typeof RootRange>;
export const RootRanges = Type.Array(RootRange);
export type RootRanges = Static<typeof RootRanges>;
export const EncodedRootsForRevision = <Schema extends TSchema>(tRevisionTag: Schema) =>
	Type.Union([
		Type.Tuple([tRevisionTag, RootRanges]),
		Type.Tuple([tRevisionTag, DetachId, ForestRootIdSchema]),
	]);
export type EncodedRootsForRevision = Static<ReturnType<typeof EncodedRootsForRevision>>;
export const Format = <
	TVersion extends DetachedFieldIndexFormatVersion,
	TRevisionTagSchema extends TSchema,
>(
	tVersion: TVersion,
	tRevisionTag: TRevisionTagSchema,
) =>
	Type.Object(
		{
			version: Type.Literal(tVersion),
			data: Type.Array(EncodedRootsForRevision(tRevisionTag)),
			maxId: ForestRootIdSchema,
		},
		{ additionalProperties: false },
	);
export type Format = Static<ReturnType<typeof Format>>;
```

### Decision procedure: `core/tree/detachedFieldIndexFormatV1.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexFormatV1.ts:1-18`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const FormatV1 = Format(
	brand<DetachedFieldIndexFormatVersion>(DetachedFieldIndexFormatVersion.v1),
	RevisionTagSchema,
);
export type FormatV1 = Static<typeof FormatV1>;
```

### Decision procedure: `core/tree/detachedFieldIndexFormatV2.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexFormatV2.ts:1-21`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const StableOrFinalRevisionTag = Type.Union([RevisionTagSchema, StableIdSchema]);
export const FormatV2 = Format(
	brand<DetachedFieldIndexFormatVersion>(DetachedFieldIndexFormatVersion.v2),
	StableOrFinalRevisionTag,
);
export type FormatV2 = Static<typeof FormatV2>;
```

### Decision procedure: `core/tree/persistedTreeTextFormat.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/persistedTreeTextFormat.ts:1-100`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
interface EncodedFieldMapObject<TChild> {
	[key: string]: TChild[];
}
const EncodedFieldMapObject = <Schema extends TSchema>(tChild: Schema) =>
	Type.Record(Type.String(), Type.Array(tChild, { minItems: 1 }));
type EncodedNodeData = Static<typeof EncodedNodeData>;
const EncodedNodeData = Type.Object({
	value: Type.Optional(Type.Any()),
	type: Type.Readonly(schemaFormatV1.TreeNodeSchemaIdentifierSchema),
});
interface EncodedGenericFieldsNode<TChild> {
	fields?: EncodedFieldMapObject<TChild>;
	globalFields?: EncodedFieldMapObject<TChild>;
}
const EncodedGenericFieldsNode = <Schema extends TSchema>(tChild: Schema) =>
	Type.Object({
		fields: Type.Optional(EncodedFieldMapObject(tChild)),
		globalFields: Type.Optional(EncodedFieldMapObject(tChild)),
	});
interface EncodedGenericTreeNode<TChild>
	extends EncodedGenericFieldsNode<TChild>,
		EncodedNodeData {}
const EncodedGenericTreeNode = <Schema extends TSchema>(tChild: Schema) =>
	Type.Composite([EncodedGenericFieldsNode(tChild), EncodedNodeData], {
		additionalProperties: false,
	});
export interface EncodedJsonableTree extends EncodedGenericTreeNode<EncodedJsonableTree> {}
export const EncodedJsonableTree = Type.Recursive((Self) => EncodedGenericTreeNode(Self));
```

### Decision procedure: `core/tree/treeTextFormat.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/treeTextFormat.ts:1-175`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface FieldMapObject<TChild> {
	[key: string]: TChild[];
}
export interface GenericTreeNode<TChild> extends GenericFieldsNode<TChild>, NodeData {}
export interface GenericFieldsNode<TChild> {
	fields?: FieldMapObject<TChild>;
}
export interface JsonableTree extends GenericTreeNode<JsonableTree> {}
export function getGenericTreeField<T>(
	node: GenericFieldsNode<T>,
	key: FieldKey,
	createIfMissing: boolean,
): T[] {
	const children = getGenericTreeFieldMap(node, createIfMissing);
	if (Object.prototype.hasOwnProperty.call(children, key)) {
		return children[key] ?? fail(0xaed  );
	}
	if (createIfMissing === false) {
		return [];
	}
	const newField: T[] = [];
	children[key] = newField;
	return newField;
}
function getGenericTreeFieldMap<T>(
	node: GenericFieldsNode<T>,
	createIfMissing: boolean,
): FieldMapObject<T> {
	let children = node.fields;
	if (children === undefined) {
		children = {};
		if (createIfMissing) {
			node.fields = children;
		}
	}
	return children;
}
export function setGenericTreeField<T>(
	node: GenericFieldsNode<T>,
	key: FieldKey,
	content: T[],
): void {
	const children = getGenericTreeFieldMap(node, true);
	Object.defineProperty(children, key, {
		enumerable: true,
		configurable: true,
		writable: true,
		value: content,
	});
}
export function genericTreeKeys<T>(tree: GenericFieldsNode<T>): readonly FieldKey[] {
	const fields = tree.fields;
	if (fields === undefined) {
		return [];
	}
	return Object.keys(fields) as FieldKey[];
}
export function genericTreeDeleteIfEmpty<T>(
	node: GenericFieldsNode<T>,
	key: FieldKey,
	removeMapObject: boolean,
): void {
	const children = getGenericTreeFieldMap(node, false);
	if (Object.prototype.hasOwnProperty.call(children, key) && children[key]?.length === 0) {
		delete children[key];
		if (removeMapObject && Object.keys(children).length === 0) {
			delete node.fields;
		}
	}
}
```

### Decision procedure: `feature-libraries/changeAtomIdCodec.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/changeAtomIdCodec.ts:1-39`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function makeChangeAtomIdCodec(
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
): JsonCodecPart<ChangeAtomId, typeof EncodedChangeAtomId, ChangeEncodingContext> {
	return {
		encode(changeAtomId: ChangeAtomId, context: ChangeEncodingContext): EncodedChangeAtomId {
			return changeAtomId.revision === undefined || changeAtomId.revision === context.revision
				? changeAtomId.localId
				: [changeAtomId.localId, revisionTagCodec.encode(changeAtomId.revision, context)];
		},
		decode(changeAtomId: EncodedChangeAtomId, context: ChangeEncodingContext): ChangeAtomId {
			return Array.isArray(changeAtomId)
				? {
						localId: changeAtomId[0],
						revision: revisionTagCodec.decode(changeAtomId[1], context),
					}
				: { localId: changeAtomId, revision: context.revision };
		},
		encodedSchema: EncodedChangeAtomId,
	};
}
```

### Literal examples and version boundary

With context revision R, atom `{localId:2,revision:R}` encodes as `2`; atom of another revision whose op-space value is 9 encodes as `[2,9]`. `"root"` bypasses compressor normalization. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/changeAtomIdCodec.ts:24-39`

Empty detached index: `{"version":1,"data":[],"maxId":-1}`. One root followed by a revision with two roots: `{"version":2,"data":[["root",0,0],[9,[[2,1],[3,2]]]],"maxId":2}`. The single-root triple and multi-root pair are selected by actual inner-map size, not a compression option. An unfinalized v2 major can instead be a stable UUID string; v1 asserts rather than writing it. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecCommon.ts:37-81`

The detached summary subtree is `DetachedFieldIndex`; `.metadata` blob is `{"version":2}`, and `DetachedFieldIndexBlob` is the JSON above. Loaded entries initially lack latest-relevant revisions: `loadData` sets `isFullyLoaded=false`; exactly one subsequent `setRevisionsForLoadedData` assigns each major's current relevance and sets it true. Allocation's high-water mark is restored before further roots are allocated. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/detachedFieldIndexSummarizer.ts:40-134` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndex.ts:280-334`

`persistedTreeTextFormat` also declares unversioned human-readable objects, not another negotiated codec: a node is `{fields?,globalFields?,value?,type}` with fields and globalFields mapping keys to nonempty node arrays. The persisted declaration does not accept a bare type string. These are distinct from FieldBatch v1/v2/text. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/persistedTreeTextFormat.ts:56-100`

## 4. Behavior

### Algebra contract

`compose([A,B,...])` means A then B; each input's context is predecessor output. `rebase(A,B)` transports A from common input context to B's output. `invert(A,false,newRevision)` is intention undo; `invert(A,true,newRevision)` is rollback and tagged `rollbackOf`. Revisions survive semantic rebases. Empty compose is identity. Do not demand raw structural equality between differently normalized changes. The exact field algebra is in the sequence/optional/modular specs, not this interface. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/changeRebaser.ts:41` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/changeRebaser.ts:142` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/types.ts:169`

For branch transport, undo source commits in reverse order with rollback inverses, rebase source intentions over target commits and transported source predecessors, preserving their revision identities; changes to the current view compose rollback path + target path + rebased source path. The graph algorithm is in core/rebase/utils.ts and is consumed by branch.ts. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branch.ts:386` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree-core/branch.ts:461`

### Required algebra laws (semantic equality)

Let e=compose([]), AB=compose([A,B]), and A⁻¹=invert(A,isRollback,newRevision) with appropriate tagging. Identity and associativity: eA=Ae=A; compose(a concatenated with b)=compose([compose(a),compose(b)]); AA⁻¹=e. Equal changes must have identical effects on *every* tree and be substitutable in every rebaser method, not merely serialize alike. Rebase laws: R(A,BC)=R(R(A,B),C); R(AB,C)=compose([R(A,C), R(B,compose([A⁻¹,C,R(A,C)]))]); R(A,e)=A; R(e,A)=e. These equations require valid sequential contexts and revision metadata. Rollback inverses participate in sandwich rebases; ordinary undo can allocate different detach aliases and must not be substituted for rollback. `ignoreNoChangeViolation` suppresses only no-change constraint invalidation, for undo/redo's special net-no-effect handling. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/changeRebaser.ts:10-114`

### Delta execution

Root members: `fields?`, `build?`, `destroy?`, `refreshers?`, `global?`, `rename?`. Mark `{count,fields?,detach?,attach?}`: neither=retain; detach only=remove; attach only=insert; both=equal-count replacement. Nested `fields` edits the pre-existing node, never new attach content. Detached ID `{major?,minor}` names each root; multi-root ranges increment minor. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/delta.ts:73` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/delta.ts:143`

Execute builds (existing identities are reused), collect global edits/refreshers, detach pass over root fields and fixed-point detached roots, transfer renamed roots, attach pass over root fields and fixed-point detached roots, then destroys. Renames atomize ranges and retry delayed entries only while progress is made: source may need a refresher; occupied destination delays transfer; transfer moves detached tree, migrates pending modifications, then deletes old mapping. Detach must precede attach globally for moves across fields and ancestors. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/visitDelta.ts:40` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/visitDelta.ts:131` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/visitDelta.ts:161`

### Anchors and detached fields

AnchorSet stores only tracked paths in sorted per-field child arrays. `track` increments references to shared PathNodes; `locate` resolves live nodes; `forget` releases. Visitor detaches shift following sibling indexes and moves tracked subtrees into detached root fields; attaches shift destination indexes and reparent moved PathNodes. Destroy marks anchored subtree dangling, emits deletion notifications, and disposes paths only when references/listeners/children no longer retain them. Move must preserve PathNode identity and anchor slots. Events include treeChanging, subtreeChanging/Changed, childrenChanging/Changed; their depth-first visitor order is observable. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/anchorSet.ts:206` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/anchorSet.ts:575` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/anchorSet.ts:774` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/anchorSet.ts:937` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/anchorSet.ts:1257`

Detached index maintains both `(major,minor)→root` and latest-relevant-revision→roots. Allocation creates consecutive forest roots; keys are prefix plus root ID, not atom IDs. Updating relevance and revision renaming must keep both maps coherent; delete entries when attached or destroyed. `purge()` clears both maps and returns nothing; `getRootsLastTouchedByRevision(revision)` enumerates roots, and `deleteRootsLastTouchedByRevision(revision)` removes their mappings; summary serializes allocation high-water mark so reload cannot reuse root IDs. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndex.ts:67`

### Algorithm notation and completeness

The following decision procedures are part of this specification, not external reading assignments. They preserve exact predicates, allocation order, collection traversal, return shapes and synchronous event calls. `undefined` means absent; `null` is a value; object spread is right-biased; `delete` removes a property; `Map`/`Set` iterate in insertion order. TypeBox `Optional(T)` permits absence, not null; tuples are fixed-order JSON arrays; singleton discriminated unions have exactly one case property. Assertions stop execution at the displayed short code. Helpers in another area use that area's same-named procedure; generic collection utilities retain JavaScript order. These are reference algorithms to translate into Swift, not a proposal to embed TypeScript in the client.

### Decision procedure: `core/rebase/changeRebaser.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/changeRebaser.ts:1-214`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface ChangeRebaser<TChangeset> {
	_typeCheck?: Invariant<TChangeset>;
	compose(changes: TaggedChange<TChangeset>[]): TChangeset;
	invert(
		changes: TaggedChange<TChangeset>,
		isRollback: boolean,
		revision: RevisionTag,
	): TChangeset;
	rebase(
		change: TaggedChange<TChangeset>,
		over: TaggedChange<TChangeset>,
		revisionMetadata: RevisionMetadataSource,
		ignoreNoChangeViolation?: boolean,
	): TChangeset;
	getRevisions(change: TChangeset): Set<RevisionTag | undefined>;
	changeRevision(change: TChangeset, replacer: RevisionReplacer): TChangeset;
}
export interface RevisionReplacer {
	readonly updatedRevision: RevisionTag;
	isObsolete(revision: RevisionTag | undefined): boolean;
	getUpdatedAtomId<T extends ChangeAtomId>(id: T, count?: number): T;
}
export interface TaggedChange<TChangeset, TTag = RevisionTag | undefined> {
	readonly revision: TTag;
	readonly rollbackOf?: RevisionTag;
	readonly change: TChangeset;
}
export function mapTaggedChange<TIn, TOut>(
	input: TaggedChange<TIn>,
	change: TOut,
): TaggedChange<TOut> {
	return { ...input, change };
}
export type RevisionIndexer = (tag: RevisionTag) => number | undefined;
export interface RevisionMetadataSource {
	readonly getIndex: RevisionIndexer;
	readonly tryGetInfo: (tag: RevisionTag | undefined) => RevisionInfo | undefined;
	readonly hasRollback: (tag: RevisionTag) => boolean;
}
export interface RevisionInfo {
	readonly revision: RevisionTag;
	readonly rollbackOf?: RevisionTag;
}
export function tagChange<T>(change: T, revision: RevisionTag | undefined): TaggedChange<T> {
	return { revision, change };
}
export function tagRollbackInverse<TChange, TTag>(
	inverseChange: TChange,
	revision: TTag,
	rollbackOf: RevisionTag | undefined,
): TaggedChange<TChange, TTag> {
	return {
		revision,
		change: inverseChange,
		rollbackOf,
	};
}
export function makeAnonChange<T>(change: T): TaggedChange<T> {
	return { revision: undefined, change };
}
export interface FinalChange {
	readonly status: FinalChangeStatus;
}
export enum FinalChangeStatus {
	conflicted,
	rebased,
	commuted,
}
```

### Decision procedure: `core/rebase/rebaseValidation.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/rebaseValidation.ts:1-159`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const RebaseValidationLevel = {
	None: 0,
	Cheap: 1,
	Strict: 2,
} as const;
export type RebaseValidationLevel =
	(typeof RebaseValidationLevel)[keyof typeof RebaseValidationLevel];
export interface RebaseValidation {
	readonly currentLevel: RebaseValidationLevel;
	readonly Level: typeof RebaseValidationLevel;
	readonly setLevel: (level: RebaseValidationLevel) => RebaseValidationLevel;
	readonly runWithLevel: <TOut>(level: RebaseValidationLevel, callback: () => TOut) => TOut;
}
let rebaseValidationLevel: RebaseValidationLevel = RebaseValidationLevel.Cheap;
function setLevel(level: RebaseValidationLevel): RebaseValidationLevel {
	if (level !== RebaseValidationLevel.None && !nonProductionConditionalsIncluded()) {
		throw new UsageError(
			"Rebase validation cannot be enabled because debug asserts have been optimized out",
		);
	}
	const old = rebaseValidationLevel;
	rebaseValidationLevel = level;
	return old;
}
export const RebaseValidation: RebaseValidation = {
	get currentLevel(): RebaseValidationLevel {
		return rebaseValidationLevel;
	},
	Level: RebaseValidationLevel,
	setLevel,
	runWithLevel: <TOut>(level: RebaseValidationLevel, callback: () => TOut): TOut => {
		const old = setLevel(level);
		try {
			return callback();
		} finally {
			rebaseValidationLevel = old;
		}
	},
};
export function cheapRebaseValidation(prefix: string, predicate: () => true | string): void {
	debugAssert(() =>
		RebaseValidation.currentLevel >= RebaseValidationLevel.Cheap
			? prefixPredicate(prefix, predicate())
			: true,
	);
}
export function strictRebaseValidation(prefix: string, predicate: () => true | string): void {
	debugAssert(() =>
		RebaseValidation.currentLevel === RebaseValidationLevel.Strict
			? prefixPredicate(prefix, predicate())
			: true,
	);
}
```

### Decision procedure: `core/rebase/types.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/types.ts:1-631`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const SessionIdSchema = brandedStringType<SessionId>();
export type RevisionTag = SessionSpaceCompressedId | "root";
export type EncodedRevisionTag = Brand<OpSpaceCompressedId, "EncodedRevisionTag"> | "root";
export const RevisionTagSchema = Type.Union([
	Type.Literal("root"),
	brandedNumberType<Exclude<EncodedRevisionTag, string>>(),
]);
export type EncodedStableId = Brand<StableId, "EncodedStableId">;
export const StableIdSchema = Type.String();
export type ChangesetLocalId = Brand<number, "ChangesetLocalId">;
export interface ChangeAtomId {
	readonly revision?: RevisionTag;
	readonly localId: ChangesetLocalId;
}
export type EncodedChangeAtomId = [ChangesetLocalId, EncodedRevisionTag] | ChangesetLocalId;
export type ChangeAtomIdMap<T> = NestedMap<RevisionTag | undefined, ChangesetLocalId, T>;
export function areEqualChangeAtomIds(a: ChangeAtomId, b: ChangeAtomId): boolean {
	return a.localId === b.localId && a.revision === b.revision;
}
export function areEqualChangeAtomIdOpts(
	a: ChangeAtomId | undefined,
	b: ChangeAtomId | undefined,
): boolean {
	if (a === undefined || b === undefined) {
		return a === b;
	}
	return areEqualChangeAtomIds(a, b);
}
export function makeChangeAtomId(
	localId: ChangesetLocalId,
	revision?: RevisionTag,
): ChangeAtomId {
	return revision === undefined ? { localId } : { localId, revision };
}
export function asChangeAtomId(id: ChangesetLocalId | ChangeAtomId): ChangeAtomId {
	return typeof id === "object" ? id : { localId: id };
}
export function taggedAtomId(
	id: ChangeAtomId,
	revision: RevisionTag | undefined,
): ChangeAtomId {
	return makeChangeAtomId(id.localId, id.revision ?? revision);
}
export function taggedOptAtomId(
	id: ChangeAtomId | undefined,
	revision: RevisionTag | undefined,
): ChangeAtomId | undefined {
	if (id === undefined) {
		return undefined;
	}
	return taggedAtomId(id, revision);
}
export function offsetChangeAtomId<T extends ChangeAtomId>(id: T, offset: number): T {
	return { ...id, localId: offsetChangesetLocalId(id.localId, offset) };
}
export function offsetChangesetLocalId(
	value: ChangesetLocalId,
	offset: number,
): ChangesetLocalId {
	return brand(value + offset);
}
export function compareChangesetLocalIds(a: ChangesetLocalId, b: ChangesetLocalId): number {
	return a - b;
}
export function comparePartialChangesetLocalIds(
	a: ChangesetLocalId | undefined,
	b: ChangesetLocalId | undefined,
): number {
	if (a === undefined) {
		return b === undefined ? 0 : -1;
	} else if (b === undefined) {
		return 1;
	}
	return compareChangesetLocalIds(a, b);
}
export interface GraphCommit<TChange> {
	readonly revision: RevisionTag;
	readonly change: TChange;
	readonly parent?: GraphCommit<TChange>;
	readonly customMetadata: CustomMetadataTree | undefined;
	readonly wasTrimmed?: true;
}
export interface CustomMetadataTree {
	readonly metadata: JsonCompatibleReadOnlyObject | undefined;
	readonly children: readonly CustomMetadataTree[];
}
export function flattenCustomMetadata(
	tree: CustomMetadataTree | undefined,
): JsonCompatibleReadOnlyObject | undefined {
	if (tree === undefined) {
		return undefined;
	}
	let flattened: Record<string, JsonCompatibleReadOnly | undefined> | undefined;
	const visit = (node: CustomMetadataTree): void => {
		for (const child of node.children) {
			visit(child);
		}
		if (node.metadata !== undefined) {
			flattened ??= {};
			for (const key of Object.keys(node.metadata)) {
				Object.defineProperty(flattened, key, {
					value: node.metadata[key],
					writable: true,
					enumerable: true,
					configurable: true,
				});
			}
		}
	};
	visit(tree);
	return flattened;
}
export enum CommitKind {
	Default,
	Undo,
	Redo,
}
export interface CommitMetadata {
	readonly kind: CommitKind;
	readonly isLocal: boolean;
}
export interface LocalChangeMetadata
	extends Extract<ChangeMetadataBeta, { readonly isLocal: true }> {
	getChange(): JsonCompatibleReadOnly;
	getRevertible(
		onDisposed?: (revertible: RevertibleAlpha) => void,
	): RevertibleAlpha | undefined;
	readonly label?: unknown;
	readonly labels: TransactionLabels;
}
export interface LocalCommitEvents {
	settled(outcome: CommitOutcome): void;
}
export interface LabelTree {
	label: unknown;
	sublabels: LabelTree[];
}
export type TransactionLabels = Set<unknown> & { tree?: LabelTree };
export enum CommitOutcome {
	FullyApplied,
	FullyDropped,
	NewContentOnly,
}
export interface RemoteChangeMetadata
	extends Extract<ChangeMetadataBeta, { readonly isLocal: false }> {
	readonly getChange?: undefined;
	readonly getRevertible?: undefined;
	readonly label?: undefined;
	readonly labels: TransactionLabels;
}
export type ChangeMetadataBeta = CommitMetadata &
	(
		| {
				readonly isLocal: true;
				readonly events: Listenable<LocalCommitEvents>;
		  }
		| {
				readonly isLocal: false;
		  }
	);
export type ChangeMetadata = LocalChangeMetadata | RemoteChangeMetadata;
export function mintCommit<TChange>(
	parent: GraphCommit<TChange>,
	commit: Omit<GraphCommit<TChange>, "parent">,
): GraphCommit<TChange> {
	const { revision, change, customMetadata } = commit;
	return {
		revision,
		change,
		parent,
		customMetadata,
	};
}
export type ChangeAtomIdRangeMap<V> = RangeMap<ChangeAtomId, V>;
export function newChangeAtomIdRangeMap<V>(
	offsetValue?: (value: V, offset: number) => V,
): ChangeAtomIdRangeMap<V> {
	return new RangeMap(offsetChangeAtomId, subtractChangeAtomIds, offsetValue);
}
export function newChangeAtomIdTransform(): ChangeAtomIdRangeMap<ChangeAtomId> {
	return new RangeMap(offsetChangeAtomId, subtractChangeAtomIds, offsetChangeAtomId);
}
export function subtractChangeAtomIds(a: ChangeAtomId, b: ChangeAtomId): number {
	const cmp = comparePartialRevisions(a.revision, b.revision);
	if (cmp !== 0) {
		return cmp * Number.POSITIVE_INFINITY;
	}
	return a.localId - b.localId;
}
export function comparePartialRevisions(
	a: RevisionTag | undefined,
	b: RevisionTag | undefined,
): number {
	if (typeof a === "number") {
		return typeof b === "number" ? a - b : 1;
	} else if (typeof b === "number") {
		return -1;
	}
	return comparePartialStrings(a, b);
}
```

### Decision procedure: `core/rebase/utils.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/utils.ts:1-732`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface RebasedCommits<TChange> {
	deletedSourceCommits: GraphCommit<TChange>[];
	targetCommits: GraphCommit<TChange>[];
	sourceCommits: GraphCommit<TChange>[];
}
export interface RebaseStats {
	readonly sourceBranchLength: number;
	readonly rebaseDistance: number;
	readonly countDropped: number;
}
export interface RebaseStatsWithDuration extends RebaseStats {
	readonly duration: number;
}
export interface BranchRebaseResult<TChange> {
	readonly newSourceHead: GraphCommit<TChange>;
	readonly sourceChange: TChange | undefined;
	readonly commits: RebasedCommits<TChange>;
	readonly telemetryProperties: RebaseStats;
}
interface RebaseChangeResult<TChange> {
	readonly change: TChange;
	readonly telemetryProperties: RebaseStats;
}
export function rebaseBranch<TChange, TEditor extends ChangeFamilyEditor = ChangeFamilyEditor>(
	mintRevisionTag: () => RevisionTag,
	changeFamily: ChangeFamily<TEditor, TChange>,
	sourceHead: GraphCommit<TChange>,
	targetHead: GraphCommit<TChange>,
): BranchRebaseResult<TChange>;
export function rebaseBranch<TChange, TEditor extends ChangeFamilyEditor = ChangeFamilyEditor>(
	mintRevisionTag: () => RevisionTag,
	changeFamily: ChangeFamily<TEditor, TChange>,
	sourceHead: GraphCommit<TChange>,
	targetCommit: GraphCommit<TChange>,
	targetHead: GraphCommit<TChange>,
): BranchRebaseResult<TChange>;
export function rebaseBranch<TChange, TEditor extends ChangeFamilyEditor = ChangeFamilyEditor>(
	mintRevisionTag: () => RevisionTag,
	changeFamily: ChangeFamily<TEditor, TChange>,
	sourceHead: GraphCommit<TChange>,
	targetCommit: GraphCommit<TChange>,
	targetHead = targetCommit,
): BranchRebaseResult<TChange> {
	const sourcePath: GraphCommit<TChange>[] = [];
	const targetPath: GraphCommit<TChange>[] = [];
	const ancestor = findCommonAncestor([sourceHead, sourcePath], [targetHead, targetPath]);
	assert(ancestor !== undefined, 0x675  );
	const sourceBranchLength = sourcePath.length;
	const targetCommitIndex = targetPath.indexOf(targetCommit);
	if (targetCommitIndex === -1) {
		return {
			newSourceHead: sourceHead,
			sourceChange: undefined,
			commits: { deletedSourceCommits: [], targetCommits: [], sourceCommits: sourcePath },
			telemetryProperties: {
				sourceBranchLength,
				rebaseDistance: targetCommitIndex + 1,
				countDropped: 0,
			},
		};
	}
	const sourceSet = new Set(sourcePath.map((r) => r.revision));
	let newBaseIndex = targetCommitIndex;
	for (const [i, { revision }] of targetPath.entries()) {
		if (sourceSet.has(revision)) {
			sourceSet.delete(revision);
			newBaseIndex = Math.max(newBaseIndex, i);
		} else if (i > targetCommitIndex) {
			break;
		}
	}
	const newBase = targetPath[newBaseIndex] ?? oob();
	const targetCommits = targetPath.slice(0, newBaseIndex + 1);
	const deletedSourceCommits = [...sourcePath];
	const targetRebasePath = [...targetCommits];
	if (hasSome(sourcePath) && hasSome(targetRebasePath)) {
		const minLength = Math.min(sourcePath.length, targetRebasePath.length);
		for (let i = 0; i < minLength; i++) {
			const firstSourcePath = sourcePath[0];
			const firstTargetRebasePath = targetRebasePath[0];
			if (firstSourcePath.revision === firstTargetRebasePath.revision) {
				sourcePath.shift();
				targetRebasePath.shift();
			}
		}
	}
	const sourceCommits: GraphCommit<TChange>[] = [];
	if (!hasSome(targetRebasePath)) {
		for (const c of sourcePath) {
			sourceCommits.push(mintCommit(sourceCommits[sourceCommits.length - 1] ?? newBase, c));
		}
		return {
			newSourceHead: sourceCommits[sourceCommits.length - 1] ?? newBase,
			sourceChange: undefined,
			commits: {
				deletedSourceCommits,
				targetCommits,
				sourceCommits,
			},
			telemetryProperties: {
				sourceBranchLength,
				rebaseDistance: targetCommits.length,
				countDropped: sourceBranchLength - sourceSet.size,
			},
		};
	}
	const changeRebaser = changeFamily.rebaser;
	let newHead = newBase;
	const revInfos = getRevInfoFromTaggedChanges([...targetRebasePath, ...sourcePath]);
	const revisionMetadata = revisionMetadataSourceFromInfo(revInfos);
	let editsToCompose: TaggedChange<TChange>[] = [...targetRebasePath];
	for (const c of sourcePath) {
		const rollback = rollbackFromCommit(changeRebaser, c, mintRevisionTag, true  );
		if (sourceSet.has(c.revision)) {
			const currentComposedEdit = makeAnonChange(changeRebaser.compose(editsToCompose));
			editsToCompose = [currentComposedEdit];
			const change = changeRebaser.rebase(c, currentComposedEdit, revisionMetadata);
			newHead = {
				revision: c.revision,
				change,
				parent: newHead,
				customMetadata: c.customMetadata,
			};
			sourceCommits.push(newHead);
			editsToCompose.push(tagChange(change, c.revision));
		}
		revInfos.push({ revision: c.revision });
		editsToCompose.unshift(rollback);
		revInfos.unshift({ revision: rollback.revision, rollbackOf: rollback.rollbackOf });
	}
	return defineLazyCachedProperty(
		{
			newSourceHead: newHead,
			commits: {
				deletedSourceCommits,
				targetCommits,
				sourceCommits,
			},
			telemetryProperties: {
				sourceBranchLength,
				rebaseDistance: targetCommits.length,
				countDropped: sourceBranchLength - sourceSet.size,
			},
		},
		"sourceChange",
		() => {
			const composed = changeRebaser.compose(editsToCompose);
			cheapRebaseValidation("Malformed rebase net change", () =>
				changeFamily.validator(composed),
			);
			return composed;
		},
	);
}
export function rebaseChange<TChange, TEditor extends ChangeFamilyEditor = ChangeFamilyEditor>(
	changeFamily: ChangeFamily<TEditor, TChange>,
	change: TaggedChange<TChange>,
	sourceHead: GraphCommit<TChange>,
	targetHead: GraphCommit<TChange>,
	mintRevisionTag: () => RevisionTag,
	ignoreNoChangeViolation?: boolean,
): RebaseChangeResult<TChange> {
	const sourcePath: GraphCommit<TChange>[] = [];
	const targetPath: GraphCommit<TChange>[] = [];
	assert(
		findCommonAncestor([sourceHead, sourcePath], [targetHead, targetPath]) !== undefined,
		0x576  ,
	);
	const inverses = sourcePath.map((commit) =>
		rollbackFromCommit(changeFamily.rebaser, commit, mintRevisionTag, true),
	);
	inverses.reverse();
	const telemetryProperties = {
		sourceBranchLength: 1,
		rebaseDistance: sourcePath.length + targetPath.length,
		countDropped: 0,
	};
	const rebased = rebaseChangeOverChanges(
		changeFamily.rebaser,
		change,
		[...inverses, ...targetPath],
		ignoreNoChangeViolation,
	);
	cheapRebaseValidation("Malformed rebase change result", () =>
		changeFamily.validator(rebased),
	);
	return {
		change: rebased,
		telemetryProperties,
	};
}
export function revisionMetadataSourceFromInfo(
	revInfos: readonly RevisionInfo[],
): RevisionMetadataSource {
	const getIndex = (revision: RevisionTag): number | undefined => {
		const index = revInfos.findIndex((revInfo) => revInfo.revision === revision);
		return index >= 0 ? index : undefined;
	};
	const tryGetInfo = (revision: RevisionTag | undefined): RevisionInfo | undefined => {
		if (revision === undefined) {
			return undefined;
		}
		const index = getIndex(revision);
		return index === undefined ? undefined : revInfos[index];
	};
	const hasRollback = (revision: RevisionTag): boolean => {
		return revInfos.some((info) => info.rollbackOf === revision);
	};
	return { getIndex, tryGetInfo, hasRollback };
}
export function rebaseChangeOverChanges<TChange>(
	changeRebaser: ChangeRebaser<TChange>,
	changeToRebase: TaggedChange<TChange>,
	changesToRebaseOver: TaggedChange<TChange>[],
	ignoreNoChangeViolation?: boolean,
): TChange {
	const revisionMetadata = revisionMetadataSourceFromInfo(
		getRevInfoFromTaggedChanges([...changesToRebaseOver, changeToRebase]),
	);
	let result = changeToRebase;
	for (const b of changesToRebaseOver) {
		result = mapTaggedChange(
			changeToRebase,
			changeRebaser.rebase(result, b, revisionMetadata, ignoreNoChangeViolation),
		);
	}
	return result.change;
}
function getRevInfoFromTaggedChanges(changes: TaggedChange<unknown>[]): RevisionInfo[] {
	const revInfos: RevisionInfo[] = [];
	for (const taggedChange of changes) {
		revInfos.push(...revisionInfoFromTaggedChange(taggedChange));
	}
	return revInfos;
}
function revisionInfoFromTaggedChange(taggedChange: TaggedChange<unknown>): RevisionInfo[] {
	const revInfos: RevisionInfo[] = [];
	if (taggedChange.revision !== undefined) {
		const info: Mutable<RevisionInfo> = { revision: taggedChange.revision };
		if (taggedChange.rollbackOf !== undefined) {
			info.rollbackOf = taggedChange.rollbackOf;
		}
		revInfos.push(info);
	}
	return revInfos;
}
function rollbackFromCommit<TChange>(
	changeRebaser: ChangeRebaser<TChange>,
	commit: GraphCommit<TChange>,
	mintRevisionTag: () => RevisionTag,
	cache?: boolean,
): TaggedChange<TChange, RevisionTag> {
	const cachedRollback = Rollback.get(commit);
	if (cachedRollback !== undefined) {
		return cachedRollback;
	}
	const tag = mintRevisionTag();
	const rollback = tagRollbackInverse(
		changeRebaser.invert(commit, true, tag),
		tag,
		commit.revision,
	);
	if (cache === true) {
		Rollback.set(commit, rollback);
	}
	return rollback;
}
export function findAncestor<T extends { parent?: T }>(
	descendant: T | [descendant: T, path?: T[]],
): T;
export function findAncestor<T extends { parent?: T }>(
	descendant: T | [descendant: T | undefined, path?: T[]] | undefined,
): T | undefined;
export function findAncestor<T extends { parent?: T }>(
	descendant: T | [descendant: T | undefined, path?: T[]] | undefined,
	predicate: (t: T) => boolean,
): T | undefined;
export function findAncestor<T extends { parent?: T }>(
	descendant: T | [descendant: T | undefined, path?: T[]] | undefined,
	predicate: (t: T) => boolean = (t): boolean => t.parent === undefined,
): T | undefined {
	let d: T | undefined;
	let path: T[] | undefined;
	if (Array.isArray(descendant)) {
		[d, path] = descendant;
	} else {
		d = descendant;
	}
	for (let cur = d; cur !== undefined; cur = cur.parent) {
		if (predicate(cur)) {
			path?.reverse();
			return cur;
		}
		path?.push(cur);
	}
	if (path !== undefined) {
		path.length = 0;
	}
	return undefined;
}
export function findCommonAncestor<T extends { parent?: T }>(
	descendantA: T | [descendantA: T, path?: T[]] | undefined,
	descendantB: T | [descendantB: T, path?: T[]] | undefined,
): T | undefined {
	let a: T | undefined;
	let b: T | undefined;
	let pathA: T[] | undefined;
	let pathB: T[] | undefined;
	if (Array.isArray(descendantA)) {
		[a, pathA] = descendantA;
		assert(pathA === undefined || pathA.length === 0, 0x578  );
	} else {
		a = descendantA;
	}
	if (Array.isArray(descendantB)) {
		[b, pathB] = descendantB;
		assert(pathB === undefined || pathB.length === 0, 0x579  );
	} else {
		b = descendantB;
	}
	if (a === b) {
		return a;
	}
	const reversePaths = (): void => {
		pathA?.reverse();
		pathB?.reverse();
	};
	const visited = new Set();
	while (a !== undefined || b !== undefined) {
		if (a !== undefined) {
			if (visited.has(a)) {
				if (pathB !== undefined) {
					pathB.length = pathB.findIndex((r) => Object.is(r, a));
				}
				reversePaths();
				return a;
			}
			visited.add(a);
			pathA?.push(a);
			a = a.parent;
		}
		if (b !== undefined) {
			if (visited.has(b)) {
				if (pathA !== undefined) {
					pathA.length = pathA.findIndex((r) => Object.is(r, b));
				}
				reversePaths();
				return b;
			}
			visited.add(b);
			pathB?.push(b);
			b = b.parent;
		}
	}
	if (pathA !== undefined) {
		pathA.length = 0;
	}
	if (pathB !== undefined) {
		pathB.length = 0;
	}
	return undefined;
}
export function replaceChange<TChange>(
	commit: GraphCommit<TChange>,
	change: TChange,
): GraphCommit<TChange> {
	const output = { ...commit, change };
	Rollback.set(output, undefined);
	return output;
}
namespace Rollback {
	const map = new WeakMap<GraphCommit<unknown>, TaggedChange<unknown, RevisionTag>>();
	export function get<TChange>(
		commit: GraphCommit<TChange>,
	): TaggedChange<TChange, RevisionTag> | undefined {
		return map.get(commit) as TaggedChange<TChange, RevisionTag> | undefined;
	}
	export function set<TChange>(
		commit: GraphCommit<TChange>,
		rollback: TaggedChange<TChange, RevisionTag> | undefined,
	): void {
		if (rollback === undefined) {
			map.delete(commit);
		} else {
			map.set(commit, rollback);
		}
	}
}
export function isAncestor<TNode extends { readonly parent?: TNode }>(
	ancestor: TNode,
	descendant: TNode,
	allowEqual: boolean,
): boolean {
	if (allowEqual && ancestor === descendant) {
		return true;
	}
	let current = descendant.parent;
	while (current !== undefined) {
		if (current === ancestor) {
			return true;
		}
		current = current.parent;
	}
	return false;
}
export function diffHistories<TChange>(
	changeRebaser: ChangeRebaser<TChange>,
	sourceCommit: GraphCommit<TChange>,
	targetCommit: GraphCommit<TChange>,
	mintRevisionTag: () => RevisionTag,
): TChange {
	const sourcePath: GraphCommit<TChange>[] = [];
	const targetPath: GraphCommit<TChange>[] = [];
	const ancestor = findCommonAncestor([sourceCommit, sourcePath], [targetCommit, targetPath]);
	assert(ancestor !== undefined, 0xc6f  );
	const inverses = sourcePath.map((commit) =>
		rollbackFromCommit(changeRebaser, commit, mintRevisionTag),
	);
	inverses.reverse();
	return changeRebaser.compose([...inverses, ...targetPath]);
}
```

### Decision procedure: `core/change-family/changeFamily.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/change-family/changeFamily.ts:1-114`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type ProcessChangeFn<TChange, TChangeProcessingContext> =
	TChangeProcessingContext extends never
		? (change: TChange) => TChange
		: (change: TChange, context: TChangeProcessingContext) => TChange;
export interface ChangeFamily<
	TEditor extends ChangeFamilyEditor,
	TChange,
	TChangeProcessingContext = never,
> {
	buildEditor(
		mintRevisionTag: () => RevisionTag,
		changeReceiver: (change: TaggedChange<TChange>) => void,
	): TEditor;
	readonly rebaser: ChangeRebaser<TChange>;
	readonly codecs: ICodecFamily<TChange, ChangeEncodingContext, ChangeDecodingContext>;
	readonly validator: (change: TChange) => true | string;
	hasSchemaChange(change: TChange): boolean;
	buildProcessor(
		processFn: ProcessChangeFn<TChange, TChangeProcessingContext>,
	): (change: TChange) => TChange;
}
export interface ChangeEncodingContext {
	readonly originatorId: SessionId;
	readonly revision: RevisionTag | undefined;
	readonly idCompressor: IIdCompressor;
	readonly schema?: SchemaAndPolicy;
	readonly isSummary: boolean;
}
export type ChangeDecodingContext = Omit<ChangeEncodingContext, "schema"> & {
	readonly healing?: IdentifierHealingConfig;
};
export type ChangeFamilyCodec<TChange> = IJsonCodec<
	TChange,
	JsonCompatibleReadOnly,
	JsonCompatibleReadOnly,
	ChangeEncodingContext,
	ChangeDecodingContext
>;
export interface ChangeFamilyEditor {
	enterTransaction(): void;
	exitTransaction(): void;
}
```

### Decision procedure: `core/change-family/editBuilder.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/change-family/editBuilder.ts:1-26`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export abstract class EditBuilder<TChange> implements ChangeFamilyEditor {
	public constructor(
		private readonly changeReceiver: (change: TaggedChange<TChange>) => void,
	) {}
	protected applyChange(change: TaggedChange<TChange>): void {
		this.changeReceiver(change);
	}
	public enterTransaction(): void {}
	public exitTransaction(): void {}
}
```

### Decision procedure: `core/schema-stored/multiplicity.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/multiplicity.ts:1-54`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export enum Multiplicity {
	Single,
	Optional,
	Sequence,
	Forbidden,
}
```

### Decision procedure: `core/schema-stored/schema.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/schema.ts:1-441`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const SchemaFormatVersion = strictEnum("SchemaFormatVersion", {
	v1: 1,
	v2: 2,
});
export type SchemaFormatVersion = Values<typeof SchemaFormatVersion>;
type FieldSchemaFormat = FieldSchemaFormatV1 | FieldSchemaFormatV2;
export enum ValueSchema {
	Number,
	String,
	Boolean,
	FluidHandle,
	Null,
}
export type TreeTypeSet = ReadonlySet<TreeNodeSchemaIdentifier>;
export interface FieldKindData {
	readonly identifier: FieldKindIdentifier;
	readonly multiplicity: Multiplicity;
}
export interface SchemaAndPolicy {
	readonly schema: StoredSchemaCollection;
	readonly policy: SchemaPolicy;
}
export interface SchemaPolicy {
	readonly fieldKinds: ReadonlyMap<FieldKindIdentifier, FieldKindData>;
}
export interface TreeFieldStoredSchema {
	readonly kind: FieldKindIdentifier;
	readonly types: TreeTypeSet;
	readonly persistedMetadata: JsonCompatibleReadOnlyObject | undefined;
}
export const forbiddenFieldKindIdentifier = brandConst("Forbidden")<FieldKindIdentifier>();
export const storedEmptyFieldSchema: TreeFieldStoredSchema = {
	kind: forbiddenFieldKindIdentifier,
	types: new Set(),
	persistedMetadata: undefined,
};
export const identifierFieldKindIdentifier = "Identifier";
export abstract class TreeNodeStoredSchema {
	protected _typeCheck!: MakeNominal;
	public constructor(public readonly metadata: PersistedMetadataFormat | undefined) {}
	public abstract encodeV1(): TreeNodeSchemaDataFormatV1;
	public abstract encodeV2(): TreeNodeSchemaDataFormatV2;
	public abstract getFieldSchema(field: FieldKey): TreeFieldStoredSchema;
}
export class ObjectNodeStoredSchema extends TreeNodeStoredSchema {
	public constructor(
		public readonly objectNodeFields: ReadonlyMap<FieldKey, TreeFieldStoredSchema>,
		metadata?: PersistedMetadataFormat | undefined,
	) {
		super(metadata);
	}
	public override encodeV1(): TreeNodeSchemaDataFormatV1 {
		const fieldsObject: Record<string, FieldSchemaFormat> =
			this.encodeFieldsObject(encodeFieldSchemaV1);
		return {
			object: fieldsObject,
		};
	}
	public override encodeV2(): TreeNodeSchemaDataFormatV2 {
		const fieldsObject: Record<string, FieldSchemaFormat> =
			this.encodeFieldsObject(encodeFieldSchemaV2);
		const kind = { object: fieldsObject };
		return { kind, metadata: this.metadata };
	}
	public override getFieldSchema(field: FieldKey): TreeFieldStoredSchema {
		return this.objectNodeFields.get(field) ?? storedEmptyFieldSchema;
	}
	private encodeFieldsObject(
		encodeFieldSchema: (storedFieldSchema: TreeFieldStoredSchema) => FieldSchemaFormat,
	): Record<string, FieldSchemaFormat> {
		const fieldsObject: Record<string, FieldSchemaFormat> = Object.create(null) as Record<
			string,
			FieldSchemaFormat
		>;
		for (const key of [...this.objectNodeFields.keys()].sort()) {
			Object.defineProperty(fieldsObject, key, {
				enumerable: true,
				configurable: true,
				writable: true,
				value: encodeFieldSchema(
					this.objectNodeFields.get(key) ?? fail(0xae7  ),
				),
			});
		}
		return fieldsObject;
	}
}
export class MapNodeStoredSchema extends TreeNodeStoredSchema {
	public constructor(
		public readonly mapFields: TreeFieldStoredSchema,
		metadata?: PersistedMetadataFormat | undefined,
	) {
		super(metadata);
	}
	public override encodeV1(): TreeNodeSchemaDataFormatV1 {
		return {
			map: encodeFieldSchemaV1(this.mapFields),
		};
	}
	public override encodeV2(): TreeNodeSchemaDataFormatV2 {
		const kind = { map: encodeFieldSchemaV2(this.mapFields) };
		return { kind, metadata: this.metadata };
	}
	public override getFieldSchema(field: FieldKey): TreeFieldStoredSchema {
		return this.mapFields;
	}
}
export class LeafNodeStoredSchema extends TreeNodeStoredSchema {
	public constructor(public readonly leafValue: ValueSchema) {
		super(undefined);
	}
	public override encodeV1(): TreeNodeSchemaDataFormatV1 {
		return {
			leaf: encodeValueSchema(this.leafValue),
		};
	}
	public override encodeV2(): TreeNodeSchemaDataFormatV2 {
		return {
			kind: {
				leaf: encodeValueSchema(this.leafValue),
			},
		};
	}
	public override getFieldSchema(field: FieldKey): TreeFieldStoredSchema {
		return storedEmptyFieldSchema;
	}
}
type StoredSchemaDecoder = (
	metadata: PersistedMetadataFormat | undefined,
) => TreeNodeStoredSchema;
export const storedSchemaDecodeDispatcher: DiscriminatedUnionDispatcher<
	TreeNodeSchemaUnionFormat,
	[],
	StoredSchemaDecoder
> = new DiscriminatedUnionDispatcher({
	leaf: (data: PersistedValueSchema) => (metadata) =>
		new LeafNodeStoredSchema(decodeValueSchema(data)),
	object: (data: Record<TreeNodeSchemaIdentifier, FieldSchemaFormat>) => (metadata) => {
		const map = new Map();
		for (const [key, value] of Object.entries(data)) {
			map.set(key, decodeFieldSchema(value));
		}
		return new ObjectNodeStoredSchema(map, metadata);
	},
	map: (data: FieldSchemaFormat) => (metadata) =>
		new MapNodeStoredSchema(decodeFieldSchema(data), metadata),
});
const valueSchemaEncode = new Map([
	[ValueSchema.Number, PersistedValueSchema.Number],
	[ValueSchema.String, PersistedValueSchema.String],
	[ValueSchema.Boolean, PersistedValueSchema.Boolean],
	[ValueSchema.FluidHandle, PersistedValueSchema.FluidHandle],
	[ValueSchema.Null, PersistedValueSchema.Null],
]);
const valueSchemaDecode = invertMap(valueSchemaEncode);
function encodeValueSchema(inMemory: ValueSchema): PersistedValueSchema {
	return valueSchemaEncode.get(inMemory) ?? fail(0xae8  );
}
function decodeValueSchema(inMemory: PersistedValueSchema): ValueSchema {
	return valueSchemaDecode.get(inMemory) ?? fail(0xae9  );
}
export function encodeFieldSchemaV1(schema: TreeFieldStoredSchema): FieldSchemaFormatV1 {
	return {
		kind: schema.kind,
		types: [...schema.types].sort(),
	};
}
export function encodeFieldSchemaV2(schema: TreeFieldStoredSchema): FieldSchemaFormatV2 {
	const fieldSchema: FieldSchemaFormatV1 = encodeFieldSchemaV1(schema);
	return schema.persistedMetadata === undefined
		? { ...fieldSchema }
		: { ...fieldSchema, metadata: schema.persistedMetadata };
}
export function decodeFieldSchema(schema: FieldSchemaFormatV2): TreeFieldStoredSchema {
	const out: TreeFieldStoredSchema = {
		kind: schema.kind,
		types: new Set(schema.types),
		persistedMetadata: schema.metadata,
	};
	return out;
}
export interface TreeStoredSchema extends StoredSchemaCollection {
	readonly rootFieldSchema: TreeFieldStoredSchema;
}
export interface StoredSchemaCollection {
	readonly nodeSchema: ReadonlyMap<TreeNodeSchemaIdentifier, TreeNodeStoredSchema>;
}
```

### Decision procedure: `core/schema-stored/storedSchemaRepository.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/storedSchemaRepository.ts:1-138`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface SchemaEvents {
	beforeSchemaChange(newSchema: TreeStoredSchema): void;
	afterSchemaChange(newSchema: TreeStoredSchema): void;
}
export interface TreeStoredSchemaSubscription extends TreeStoredSchema {
	readonly events: Listenable<SchemaEvents>;
}
export interface MutableTreeStoredSchema extends TreeStoredSchemaSubscription {
	apply(newSchema: TreeStoredSchema): void;
}
export class TreeStoredSchemaRepository implements MutableTreeStoredSchema {
	protected nodeSchemaData: BTree<TreeNodeSchemaIdentifier, TreeNodeStoredSchema>;
	protected rootFieldSchemaData: TreeFieldStoredSchema;
	protected readonly _events = createEmitter<SchemaEvents>();
	public readonly events: Listenable<SchemaEvents> = this._events;
	public constructor(data?: TreeStoredSchema) {
		if (data === undefined) {
			this.rootFieldSchemaData = storedEmptyFieldSchema;
			this.nodeSchemaData = new BTree<TreeNodeSchemaIdentifier, TreeNodeStoredSchema>(
				[],
				compareStrings,
			);
		} else {
			if (data instanceof TreeStoredSchemaRepository) {
				this.rootFieldSchemaData = data.rootFieldSchema;
				this.nodeSchemaData = data.nodeSchemaData.clone();
			} else {
				this.rootFieldSchemaData = data.rootFieldSchema;
				this.nodeSchemaData = cloneNodeSchemaData(data.nodeSchema);
			}
		}
	}
	public get nodeSchema(): ReadonlyMap<TreeNodeSchemaIdentifier, TreeNodeStoredSchema> {
		return this.nodeSchemaData as unknown as ReadonlyMap<
			TreeNodeSchemaIdentifier,
			TreeNodeStoredSchema
		>;
	}
	public get rootFieldSchema(): TreeFieldStoredSchema {
		return this.rootFieldSchemaData;
	}
	public apply(newSchema: TreeStoredSchema): void {
		this._events.emit("beforeSchemaChange", newSchema);
		const clone = new TreeStoredSchemaRepository(newSchema);
		this.rootFieldSchemaData = clone.rootFieldSchemaData;
		this.nodeSchemaData = clone.nodeSchemaData;
		this._events.emit("afterSchemaChange", newSchema);
	}
	public clone(): TreeStoredSchemaRepository {
		return new TreeStoredSchemaRepository(this);
	}
}
export function schemaDataIsEmpty(data: TreeStoredSchema): boolean {
	return data.nodeSchema.size === 0;
}
function cloneNodeSchemaData(
	nodeSchema: StoredSchemaCollection["nodeSchema"],
): BTree<TreeNodeSchemaIdentifier, TreeNodeStoredSchema> {
	const entries: [TreeNodeSchemaIdentifier, TreeNodeStoredSchema][] = [
		...nodeSchema.entries(),
	];
	return new BTree<TreeNodeSchemaIdentifier, TreeNodeStoredSchema>(entries, compareStrings);
}
```

### Decision procedure: `core/tree/anchorSet.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/anchorSet.ts:1-1326`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type Anchor = Brand<number, "rebaser.Anchor">;
const NeverAnchor: Anchor = brand(0);
export interface AnchorLocator {
	locate(anchor: Anchor): AnchorNode | undefined;
}
export type AnchorSlot<TContent> = BrandedKey<Opaque<Brand<number, "AnchorSlot">>, TContent>;
export interface AnchorEvents {
	afterDestroy(anchor: AnchorNode): void;
	childrenChanging(anchor: AnchorNode): void;
	childrenChanged(anchor: AnchorNode): void;
	childrenChangedAfterBatch(arg: {
		changedFields: ReadonlySet<FieldKey>;
		fieldMarks: ReadonlyMap<FieldKey, readonly Delta.Mark[]>;
	}): void;
	subtreeChanging(anchor: AnchorNode): void;
	subtreeChanged(anchor: AnchorNode): void;
	subtreeChangedAfterBatch(): void;
}
export interface AnchorSetRootEvents {
	childrenChanging(anchors: AnchorSet): void;
	treeChanging(anchors: AnchorSet): void;
}
export interface AnchorNode extends INormalizedUpPath<AnchorNode> {
	readonly events: Listenable<AnchorEvents> & HasListeners<AnchorEvents>;
	readonly slots: BrandedMapSubset<AnchorSlot<any>>;
	readonly anchorSet: AnchorSet;
	child(key: FieldKey, index: number): UpPath<AnchorNode>;
	childIfAnchored(key: FieldKey, index: number): AnchorNode | undefined;
	getOrCreateChildRef(key: FieldKey, index: number): [Anchor, AnchorNode];
}
export function anchorSlot<TContent>(): AnchorSlot<TContent> {
	return brandedSlot<AnchorSlot<TContent>>();
}
export class AnchorSet implements AnchorLocator {
	readonly #events = createEmitter<AnchorSetRootEvents>();
	public readonly events: Listenable<AnchorSetRootEvents> = this.#events;
	private anchorCounter = 1;
	public generationNumber = 0;
	private readonly root = new PathNode(this, EmptyKey, 0, undefined);
	private readonly anchorToPath: Map<Anchor, PathNode> = new Map();
	private activeVisitor?: DeltaVisitor;
	public constructor() {
		this.events.on("treeChanging", () => {
			this.generationNumber += 1;
		});
	}
	public get slots(): BrandedMapSubset<AnchorSlot<any>> {
		return this.root.slots;
	}
	public *[Symbol.iterator](): IterableIterator<AnchorNode> {
		const stack: PathNode[] = [];
		let node: PathNode | undefined = this.root;
		while (node !== undefined) {
			yield node;
			for (const [_, children] of node.children) {
				for (const child of children) {
					stack.push(child);
				}
			}
			node = stack.pop();
		}
	}
	public isEmpty(): boolean {
		return this.root.children.size === 0;
	}
	public locate(anchor: Anchor): AnchorNode | undefined {
		if (anchor === NeverAnchor) {
			return undefined;
		}
		const path = this.anchorToPath.get(anchor);
		assert(
			path !== undefined,
			0x3a6  ,
		);
		return path.status === Status.Alive ? path : undefined;
	}
	public forget(anchor: Anchor): void {
		if (anchor !== NeverAnchor) {
			const path = this.anchorToPath.get(anchor);
			assert(path !== undefined, 0x351  );
			path.removeRef();
			this.anchorToPath.delete(anchor);
		}
	}
	public track(path: UpPath | null): Anchor {
		if (path === null) {
			return NeverAnchor;
		}
		const foundPath = this.trackInner(path);
		const anchor: Anchor = brand(this.anchorCounter++);
		this.anchorToPath.set(anchor, foundPath);
		return anchor;
	}
	private trackInner(path: UpPath): PathNode {
		if (path instanceof PathNode && path.anchorSet === this) {
			path.addRef();
			return path;
		}
		const parent = path.parent ?? this.root;
		const parentPath = this.trackInner(parent);
		const child = parentPath.getOrCreateChild(path.parentField, path.parentIndex);
		parentPath.removeRef();
		return child;
	}
	public find(path: UpPath): PathNode | undefined {
		if (path instanceof PathNode && path.anchorSet === this) {
			return path;
		}
		const parent = path.parent ?? this.root;
		const parentPath = this.find(parent);
		return parentPath?.childIfAnchored(path.parentField, path.parentIndex);
	}
	public internalizePath(originalPath: UpPath): UpPath {
		let path: UpPath | undefined = originalPath;
		const stack: UpPath[] = [];
		while (path !== undefined) {
			if (path instanceof PathNode && path.anchorSet === this) {
				break;
			}
			stack.push(path);
			path = path.parent;
		}
		let wrapWith: UpPath | undefined;
		while ((wrapWith = stack.pop()) !== undefined) {
			if (path === undefined || path instanceof PathNode) {
				const child = (path ?? this.root).childIfAnchored(
					wrapWith.parentField,
					wrapWith.parentIndex,
				);
				if (child !== undefined) {
					path = child;
					continue;
				}
			}
			if (path === wrapWith.parent && !(wrapWith instanceof PathNode)) {
				path = wrapWith;
			} else {
				path = {
					parent: path,
					parentField: wrapWith.parentField,
					parentIndex: wrapWith.parentIndex,
				};
			}
		}
		return path ?? fail(0xaea  );
	}
	private deepDelete(nodes: readonly PathNode[]): void {
		const stack = [...nodes];
		while (stack.length > 0) {
			const node = stack.pop()!;
			assert(node.status === Status.Alive, 0x408  );
			node.status = Status.Dangling;
			node.events.emit("afterDestroy", node);
			for (const children of node.children.values()) {
				stack.push(...children);
			}
		}
	}
	private decoupleNodes(startPath: UpPath, count: number): PathNode[] {
		assert(count > 0, 0x681  );
		const sourceParent = this.find(startPath.parent ?? this.root);
		const sourceChildren = sourceParent?.children?.get(startPath.parentField);
		let nodes: PathNode[] = [];
		if (sourceChildren !== undefined) {
			let numberBeforeDecouple = 0;
			let numberToDecouple = 0;
			let index = 0;
			while (
				index < sourceChildren.length &&
				sourceChildren[index]!.parentIndex < startPath.parentIndex
			) {
				numberBeforeDecouple++;
				index++;
			}
			while (
				index < sourceChildren.length &&
				sourceChildren[index]!.parentIndex < startPath.parentIndex + count
			) {
				numberToDecouple++;
				index++;
			}
			while (index < sourceChildren.length) {
				sourceChildren[index]!.parentIndex -= count;
				index++;
			}
			nodes = sourceChildren.splice(numberBeforeDecouple, numberToDecouple);
			if (sourceChildren.length === 0) {
				sourceParent!.afterEmptyField(startPath.parentField);
			}
		}
		return nodes;
	}
	private coupleNodes(
		destination: UpPath,
		count: number,
		coupleInfo: { startParentIndex: number; nodes: PathNode[] },
	): void {
		assert(coupleInfo.nodes.length > 0, 0x682  );
		const destinationPath = this.trackInner(destination.parent ?? this.root);
		for (const node of coupleInfo.nodes) {
			node.parentIndex += destination.parentIndex - coupleInfo.startParentIndex;
			node.parentPath = destinationPath;
			node.parentField = destination.parentField;
			node.detachedNodeId = isDetachedUpPathRoot(destination)
				? offsetDetachIdOpt(
						destination.detachedNodeId,
						node.parentIndex - destination.parentIndex,
					)
				: undefined;
		}
		const field = destinationPath.children.get(destination.parentField);
		if (field === undefined) {
			destinationPath.children.set(destination.parentField, coupleInfo.nodes);
		} else {
			const numberBeforeCouple = this.increaseParentIndexes(
				field,
				destination.parentIndex,
				count,
			);
			field.splice(numberBeforeCouple, 0, ...coupleInfo.nodes);
		}
		destinationPath.removeRef();
	}
	private increaseParentIndexes(
		field: PathNode[],
		fromParentIndex: number,
		count: number,
	): number {
		let index = 0;
		while (index < field.length && field[index]!.parentIndex < fromParentIndex) {
			index++;
		}
		const numberBeforeIncrease = index;
		while (index < field.length) {
			field[index]!.parentIndex += count;
			index++;
		}
		return numberBeforeIncrease;
	}
	private moveChildren(sourceStart: UpPath, destination: UpPath, count: number): void {
		const nodes = this.decoupleNodes(sourceStart, count);
		if (nodes.length > 0) {
			this.coupleNodes(destination, count, {
				startParentIndex: sourceStart.parentIndex,
				nodes,
			});
		} else {
			this.offsetChildren(destination, count);
		}
	}
	private removeChildren(path: UpPath, count: number): void {
		const nodes = this.decoupleNodes(path, count);
		this.deepDelete(nodes);
	}
	private offsetChildren(firstSiblingToOffset: UpPath, offset: number): void {
		const nodePath = this.find(firstSiblingToOffset.parent ?? this.root);
		const field = nodePath?.children.get(firstSiblingToOffset.parentField);
		if (field !== undefined) {
			this.increaseParentIndexes(field, firstSiblingToOffset.parentIndex, offset);
		}
	}
	public acquireVisitor(): DeltaVisitor {
		assert(
			this.activeVisitor === undefined,
			0x767  ,
		);
		const referencedPathNodes: PathNode[] = [];
		const visitor = {
			anchorSet: this,
			maybeWithNode(withNode: (anchorNode: PathNode) => void, withRoot?: () => void) {
				if (this.parent === undefined && withRoot !== undefined) {
					withRoot();
				} else {
					assert(this.parent !== undefined, 0x5b0  );
					this.parent = this.anchorSet.internalizePath(this.parent);
					if (this.parent instanceof PathNode) {
						this.parent.addRef();
						referencedPathNodes.push(this.parent);
						withNode(this.parent);
					}
				}
			},
			parentField: undefined as FieldKey | undefined,
			parent: undefined as UpPath | undefined,
			bufferedEvents: [] as BufferedEvent[],
			storedFieldMarks: new Map<PathNode, Map<FieldKey, readonly Delta.Mark[]>>(),
			currentDepth: 0,
			depthThresholdForSubtreeChanged: 0,
			free() {
				assert(
					this.anchorSet.activeVisitor !== undefined,
					0x768  ,
				);
				for (const node of referencedPathNodes) {
					node.removeRef();
				}
				this.anchorSet.activeVisitor = undefined;
				const eventsByNode: Map<PathNode, Set<FieldKey>> = new Map();
				const marksByNode: Map<PathNode, Map<FieldKey, readonly Delta.Mark[]>> = new Map();
				for (const { node, event, changedField, fieldMarks } of this.bufferedEvents) {
					if (event === "childrenChangedAfterBatch") {
						const resolvedField: FieldKey =
							changedField ??
							fail(0xb57  );
						const keys = getOrCreate(eventsByNode, node, () => new Set());
						keys.add(resolvedField);
						if (fieldMarks !== undefined) {
							const nodeMarks = getOrCreate(marksByNode, node, () => new Map());
							if (!nodeMarks.has(resolvedField)) {
								nodeMarks.set(resolvedField, fieldMarks);
							}
						}
					}
				}
				const alreadyEmitted = new Map<PathNode, (keyof AnchorEvents)[]>();
				for (const { node, event } of this.bufferedEvents) {
					const emittedEvents = getOrAddEmptyToMap(alreadyEmitted, node);
					if (emittedEvents.includes(event)) {
						continue;
					}
					emittedEvents.push(event);
					if (event === "childrenChangedAfterBatch") {
						const changedFields =
							eventsByNode.get(node) ??
							fail(0xaeb  );
						const fieldMarks: ReadonlyMap<FieldKey, readonly Delta.Mark[]> =
							marksByNode.get(node) ?? new Map();
						node.events.emit(event, { changedFields, fieldMarks });
					} else {
						node.events.emit(event);
					}
				}
			},
			notifyChildrenChanging(): void {
				this.maybeWithNode(
					(p) => p.events.emit("childrenChanging", p),
					() => this.anchorSet.#events.emit("childrenChanging", this.anchorSet),
				);
			},
			notifyChildrenChanged(): void {
				const parentField = this.parentField;
				this.maybeWithNode(
					(p) => {
						assert(
							parentField !== undefined,
							0xa24  ,
						);
						p.events.emit("childrenChanged", p);
						const fieldMarks = this.storedFieldMarks.get(p)?.get(parentField);
						this.bufferedEvents.push({
							node: p,
							event: "childrenChangedAfterBatch",
							changedField: parentField,
							fieldMarks,
						});
					},
					() => {},
				);
			},
			attach(source: FieldKey, count: number, destination: PlaceIndex): void {
				this.notifyChildrenChanging();
				this.attachEdit(source, count, destination);
				this.notifyChildrenChanged();
			},
			attachEdit(source: FieldKey, count: number, destination: PlaceIndex): void {
				assert(
					this.parentField !== undefined,
					0x7a2  ,
				);
				const sourcePath = {
					parent: this.anchorSet.root,
					parentField: source,
					parentIndex: 0,
				};
				const destinationPath = {
					parent: this.parent,
					parentField: this.parentField,
					parentIndex: destination,
				};
				this.anchorSet.moveChildren(sourcePath, destinationPath, count);
				this.depthThresholdForSubtreeChanged = this.currentDepth;
			},
			detach(
				source: Range,
				destination: FieldKey,
				detachedNodeId: Delta.DetachedNodeId,
			): void {
				this.notifyChildrenChanging();
				this.detachEdit(source, destination, detachedNodeId);
				this.notifyChildrenChanged();
			},
			detachEdit(
				source: Range,
				destination: FieldKey,
				detachedNodeId: Delta.DetachedNodeId,
			): void {
				assert(
					this.parentField !== undefined,
					0x7a5  ,
				);
				const sourcePath: UpPath = {
					parent: this.parent,
					parentField: this.parentField,
					parentIndex: source.start,
				};
				const destinationPath: NormalizedUpPath = {
					parent: this.anchorSet.root,
					parentField: destination,
					parentIndex: 0,
					detachedNodeId,
				};
				this.anchorSet.moveChildren(sourcePath, destinationPath, source.end - source.start);
				this.depthThresholdForSubtreeChanged = this.currentDepth;
			},
			replace(
				newContentSource: FieldKey,
				range: Range,
				oldContentDestination: FieldKey,
				destinationDetachedNodeId: Delta.DetachedNodeId,
			): void {
				this.notifyChildrenChanging();
				this.detachEdit(range, oldContentDestination, destinationDetachedNodeId);
				this.attachEdit(newContentSource, range.end - range.start, range.start);
				this.notifyChildrenChanged();
			},
			destroy(detachedField: FieldKey, count: number): void {
				this.anchorSet.removeChildren(
					{
						parent: undefined,
						parentField: detachedField,
						parentIndex: 0,
					},
					count,
				);
			},
			create(content: ITreeCursorSynchronous[], destination: FieldKey): void {
			},
			enterNode(index: number): void {
				assert(this.parentField !== undefined, 0x3ab  );
				this.parent = {
					parent: this.parent,
					parentField: this.parentField,
					parentIndex: index,
				};
				this.parentField = undefined;
				this.maybeWithNode((p) => {
					p.events.emit("subtreeChanging", p);
				});
				this.currentDepth++;
			},
			exitNode(index: number): void {
				assert(this.parent !== undefined, 0x3ac  );
				if (this.depthThresholdForSubtreeChanged === this.currentDepth) {
					this.maybeWithNode((p) => {
						p.events.emit("subtreeChanged", p);
						this.bufferedEvents.push({
							node: p,
							event: "subtreeChangedAfterBatch",
						});
					});
					this.depthThresholdForSubtreeChanged--;
				}
				const parent = this.parent;
				this.parentField = parent.parentField;
				this.parent = parent.parent;
				this.currentDepth--;
			},
			enterField(key: FieldKey): void {
				this.parentField = key;
			},
			exitField(key: FieldKey): void {
				this.parentField = undefined;
			},
			fieldMarks(marks: readonly Delta.Mark[]): void {
				assert(
					this.parentField !== undefined,
					0xce4  ,
				);
				if (this.parent !== undefined) {
					const interned = this.anchorSet.internalizePath(this.parent);
					if (interned instanceof PathNode) {
						getOrCreate(this.storedFieldMarks, interned, () => new Map()).set(
							this.parentField,
							marks,
						);
						if (this.parentField === EmptyKey) {
							const hasShallowChange = marks.some(
								(m) => m.attach !== undefined || m.detach !== undefined,
							);
							const hasDeepChanges = marks.some(
								(m) => m.fields !== undefined && m.fields.size > 0,
							);
							const onlyDeepChanges = !hasShallowChange && hasDeepChanges;
							if (onlyDeepChanges) {
								this.bufferedEvents.push({
									node: interned,
									event: "childrenChangedAfterBatch",
									changedField: this.parentField,
									fieldMarks: marks,
								});
							}
						}
					}
				}
			},
		};
		this.#events.emit("treeChanging", this);
		this.activeVisitor = visitor;
		return visitor;
	}
}
enum Status {
	Alive,
	Disposed,
	Dangling,
}
class PathNode extends ReferenceCountedBase implements AnchorNode {
	public status: Status = Status.Alive;
	public readonly events = createEmitter<AnchorEvents>(this.considerDispose.bind(this));
	public readonly children: Map<FieldKey, PathNode[]> = new Map();
	public readonly slots: BrandedMapSubset<AnchorSlot<any>> = new Map();
	public detachedNodeId: Delta.DetachedNodeId | undefined;
	public constructor(
		public readonly anchorSet: AnchorSet,
		public parentField: FieldKey,
		public parentIndex: number,
		public parentPath: PathNode | undefined,
	) {
		super(1);
	}
	public child(key: FieldKey, index: number): UpPath<AnchorNode> {
		return (
			this.childIfAnchored(key, index) ?? {
				parent: this,
				parentField: key,
				parentIndex: index,
			}
		);
	}
	public getOrCreateChildRef(key: FieldKey, index: number): [Anchor, AnchorNode] {
		const anchor = this.anchorSet.track(this.child(key, index));
		const node =
			this.anchorSet.locate(anchor) ??
			fail(0xaec  );
		return [anchor, node];
	}
	private isRoot(): boolean {
		return this.parentPath === undefined;
	}
	public get parent(): PathNode | undefined {
		assert(this.status !== Status.Disposed, 0x409  );
		assert(
			this.parentPath !== undefined,
			0x355  ,
		);
		if (this.parentPath.isRoot()) {
			return undefined;
		}
		return this.parentPath;
	}
	public addRef(count = 1): void {
		assert(this.status === Status.Alive, 0x40a  );
		this.referenceAdded(count);
	}
	public removeRef(count = 1): void {
		assert(this.status !== Status.Disposed, 0x40b  );
		this.referenceRemoved(count);
	}
	protected onUnreferenced(): void {
		this.considerDispose();
	}
	public getOrCreateChild(key: FieldKey, index: number): PathNode {
		assert(this.status === Status.Alive, 0x40c  );
		let field = this.children.get(key);
		if (field === undefined) {
			field = [];
			this.children.set(key, field);
		}
		let child = binaryFind(field, index);
		if (child === undefined) {
			child = new PathNode(this.anchorSet, key, index, this);
			field.push(child);
			field.sort((a, b) => a.parentIndex - b.parentIndex);
		} else {
			child.addRef();
		}
		return child;
	}
	public childIfAnchored(key: FieldKey, index: number): PathNode | undefined {
		assert(this.status === Status.Alive, 0x40d  );
		const field = this.children.get(key);
		return field === undefined ? undefined : binaryFind(field, index);
	}
	public removeChild(child: PathNode): void {
		assert(this.status === Status.Alive, 0x40e  );
		const key = child.parentField;
		const field = this.children.get(key);
		const childIndex = field?.indexOf(child) ?? -1;
		assert(childIndex !== -1, 0x35c  );
		field?.splice(childIndex, 1);
		if (field?.length === 0) {
			this.afterEmptyField(key);
		}
	}
	public afterEmptyField(key: FieldKey): void {
		assert(this.status === Status.Alive, 0x40f  );
		this.children.delete(key);
		this.considerDispose();
	}
	private considerDispose(): void {
		assert(this.status !== Status.Disposed, 0x41d  );
		if (this.isUnreferenced() && this.children.size === 0 && !this.events.hasListeners()) {
			if (this.status === Status.Alive) {
				this.parentPath?.removeChild(this);
			}
			this.status = Status.Disposed;
		}
	}
}
function binaryFind(sorted: readonly PathNode[], index: number): PathNode | undefined {
	const guess = sorted[index];
	if (guess !== undefined && guess.parentIndex === index) {
		return guess;
	}
	let min = 0;
	let max = sorted.length;
	while (min !== max) {
		const mid = Math.floor((min + max) / 2);
		const item = sorted[mid]!;
		const found = item.parentIndex;
		if (found === index) {
			return item;
		} else if (found > index) {
			max = mid;
		} else {
			min = mid + 1;
		}
	}
	return undefined;
}
interface BufferedEvent {
	node: PathNode;
	event: keyof AnchorEvents;
	changedField?: FieldKey;
	fieldMarks?: readonly Delta.Mark[];
}
```

### Decision procedure: `core/tree/chunk.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/chunk.ts:1-111`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface TreeChunk extends ReferenceCounted {
	readonly topLevelLength: number;
	cursor(): ChunkedCursor;
}
export const dummyRoot: FieldKey = rootFieldKey;
export const cursorChunk: unique symbol = Symbol("cursorChunk");
interface WithChunk {
	readonly [cursorChunk]?: TreeChunk | undefined;
}
export function tryGetChunk(cursor: ITreeCursor): undefined | TreeChunk {
	assert(
		cursor.mode === CursorLocationType.Nodes,
		0x57b  ,
	);
	return (cursor as WithChunk)[cursorChunk];
}
export interface ChunkedCursor extends ITreeCursorSynchronous, WithChunk {
	atChunkRoot(): boolean;
	fork(): ChunkedCursor;
}
```

### Decision procedure: `core/tree/cursor.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/cursor.ts:1-537`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const CursorMarker: unique symbol = Symbol("CursorMarker");
export function isCursor(data: unknown): data is ITreeCursor {
	return (
		data !== null &&
		typeof data === "object" &&
		(data as Partial<ITreeCursor>)[CursorMarker] === true
	);
}
export interface ITreeCursor {
	readonly [CursorMarker]: true;
	readonly mode: CursorLocationType;
	readonly pending: boolean;
	nextField(): boolean;
	exitField(): void;
	skipPendingFields(): boolean;
	getFieldKey(): FieldKey;
	getFieldLength(): number;
	firstNode(): boolean;
	enterNode(childIndex: number): void;
	getFieldPath(prefix?: PathRootPrefix): FieldUpPath;
	getPath(prefix?: PathRootPrefix): UpPath | undefined;
	readonly fieldIndex: number;
	readonly chunkStart: number;
	readonly chunkLength: number;
	seekNodes(offset: number): boolean;
	nextNode(): boolean;
	exitNode(): void;
	firstField(): boolean;
	enterField(key: FieldKey): void;
	readonly type: TreeType;
	readonly value: Value;
}
export interface PathRootPrefix {
	parent?: UpPath | undefined;
	rootFieldOverride?: FieldKey;
	indexOffset?: number;
}
export const enum CursorLocationType {
	Nodes,
	Fields,
}
export interface ITreeCursorSynchronous extends ITreeCursor {
	readonly pending: false;
}
export function mapCursorFields<T, TCursor extends ITreeCursor = ITreeCursor>(
	cursor: TCursor,
	f: (cursor: TCursor) => T,
): T[] {
	const output: T[] = [];
	forEachField(cursor, (c) => {
		output.push(f(c));
	});
	return output;
}
export function forEachField<TCursor extends ITreeCursor = ITreeCursor>(
	cursor: TCursor,
	f: (cursor: TCursor) => void,
): void {
	assert(cursor.mode === CursorLocationType.Nodes, 0x411  );
	for (let inField = cursor.firstField(); inField; inField = cursor.nextField()) {
		f(cursor);
	}
}
export function mapCursorField<T, TCursor extends ITreeCursor = ITreeCursor>(
	cursor: TCursor,
	f: (cursor: TCursor) => T,
): T[] {
	const output: T[] = [];
	forEachNode(cursor, (c) => {
		output.push(f(c));
	});
	return output;
}
export function* iterateCursorField<T, TCursor extends ITreeCursor = ITreeCursor>(
	cursor: TCursor,
	f: (cursor: TCursor) => T,
): IterableIterator<T> {
	assert(cursor.mode === CursorLocationType.Fields, 0x7a8  );
	for (let inNodes = cursor.firstNode(); inNodes; inNodes = cursor.nextNode()) {
		yield f(cursor);
	}
}
export function forEachNode<TCursor extends ITreeCursor = ITreeCursor>(
	cursor: TCursor,
	f: (cursor: TCursor) => void,
): void {
	assert(cursor.mode === CursorLocationType.Fields, 0x3bd  );
	for (let inNodes = cursor.firstNode(); inNodes; inNodes = cursor.nextNode()) {
		f(cursor);
	}
}
export function forEachNodeSubsequence<TCursor extends ITreeCursor = ITreeCursor>(
	cursor: TCursor,
	startIndex: number,
	endIndex: number,
	f: (cursor: TCursor) => void,
): void {
	assert(cursor.mode === CursorLocationType.Fields, 0xce5  );
	assert(startIndex >= 0, 0xce6  );
	assert(endIndex >= startIndex, 0xce7  );
	const outputLength = endIndex - startIndex;
	if (outputLength === 0) {
		return;
	}
	cursor.enterNode(startIndex);
	for (let i = 0; i < outputLength; i++) {
		f(cursor);
		const hasNext = cursor.nextNode();
		if (!hasNext) {
			assert(i === outputLength - 1, 0xce8  );
			return;
		}
	}
	cursor.exitNode();
}
export function forEachNodeInSubtree<TCursor extends ITreeCursor = ITreeCursor>(
	cursor: TCursor,
	f: (cursor: TCursor) => void,
): void {
	if (cursor.mode === CursorLocationType.Nodes) {
		f(cursor);
		forEachField(cursor, (c) => forEachNodeInSubtree(c, f));
	} else {
		forEachNode(cursor, (c) => forEachNodeInSubtree(c, f));
	}
}
export function castCursorToSynchronous(cursor: ITreeCursor): ITreeCursorSynchronous {
	return cursor as ITreeCursorSynchronous;
}
export function inCursorField<T, TCursor extends ITreeCursor = ITreeCursor>(
	cursor: TCursor,
	field: FieldKey,
	f: (cursor: TCursor) => T,
): T {
	cursor.enterField(field);
	const result = f(cursor);
	cursor.exitField();
	return result;
}
export function inCursorNode<T, TCursor extends ITreeCursor = ITreeCursor>(
	cursor: TCursor,
	index: number,
	f: (cursor: TCursor) => T,
): T {
	cursor.enterNode(index);
	const result = f(cursor);
	cursor.exitNode();
	return result;
}
```

### Decision procedure: `core/tree/delta.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/delta.ts:1-253`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface Root<TTrees = ProtoNodes> {
	readonly fields?: FieldMap;
	readonly build?: readonly DetachedNodeBuild<TTrees>[];
	readonly destroy?: readonly DetachedNodeDestruction[];
	readonly refreshers?: readonly DetachedNodeBuild<TTrees>[];
	readonly global?: readonly DetachedNodeChanges[];
	readonly rename?: readonly DetachedNodeRename[];
}
export type ProtoNodes = TreeChunk;
export interface Mark {
	readonly count: number;
	readonly fields?: FieldMap;
	readonly detach?: DetachedNodeId;
	readonly attach?: DetachedNodeId;
}
export interface DetachedNodeId {
	readonly major?: RevisionTag;
	readonly minor: number;
}
export type FieldMap = ReadonlyMap<FieldKey, FieldChanges>;
export interface DetachedNodeChanges {
	readonly id: DetachedNodeId;
	readonly fields: FieldMap;
}
export interface DetachedNodeBuild<TTrees = ProtoNodes> {
	readonly id: DetachedNodeId;
	readonly trees: TTrees;
}
export interface DetachedNodeDestruction {
	readonly id: DetachedNodeId;
	readonly count: number;
}
export interface DetachedNodeRename {
	readonly count: number;
	readonly oldId: DetachedNodeId;
	readonly newId: DetachedNodeId;
}
export interface FieldChanges {
	readonly marks: readonly Mark[];
}
```

### Decision procedure: `core/tree/deltaUtil.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/deltaUtil.ts:1-150`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const emptyDelta: Root = {};
export function deltaForRootInitialization(content: TreeChunk): Root {
	if (content.topLevelLength === 0) {
		return emptyDelta;
	}
	const buildId = { minor: 0 };
	const delta: Root = {
		build: [{ id: buildId, trees: content }],
		fields: new Map<FieldKey, FieldChanges>([
			[rootFieldKey, { marks: [{ count: content.topLevelLength, attach: buildId }] }],
		]),
	};
	return delta;
}
export function makeDetachedNodeId(
	major: DetachedNodeId["major"],
	minor: DetachedNodeId["minor"],
): DetachedNodeId {
	const out: Mutable<DetachedNodeId> = { minor };
	if (major !== undefined) {
		out.major = major;
	}
	return out;
}
export function offsetDetachId(id: DetachedNodeId, offset: number): DetachedNodeId {
	return {
		...id,
		minor: id.minor + offset,
	};
}
export function offsetDetachIdOpt(id: DetachedNodeId, offset: number): DetachedNodeId;
export function offsetDetachIdOpt(
	id: DetachedNodeId | undefined,
	offset: number,
): DetachedNodeId | undefined;
export function offsetDetachIdOpt(
	id: DetachedNodeId | undefined,
	offset: number,
): DetachedNodeId | undefined {
	if (id === undefined) {
		return undefined;
	}
	return {
		...id,
		minor: id.minor + offset,
	};
}
export function subtractDetachedNodeId(a: DetachedNodeId, b: DetachedNodeId): number {
	const cmp = comparePartialRevisions(a.major, b.major);
	if (cmp !== 0) {
		return cmp * Number.POSITIVE_INFINITY;
	}
	return a.minor - b.minor;
}
export function areDetachedNodeIdsEqual(a: DetachedNodeId, b: DetachedNodeId): boolean {
	return a.major === b.major && a.minor === b.minor;
}
export interface DeltaChangeProfile {
	hasBuilds: boolean;
	hasDestroys: boolean;
	hasRenames: boolean;
	hasChangesInDocumentTree: boolean;
	hasChangesInDetachedTrees: boolean;
}
export function getDeltaChangeProfile(delta: Root): DeltaChangeProfile {
	const profile: DeltaChangeProfile = {
		hasBuilds: delta.build !== undefined && delta.build.length > 0,
		hasDestroys: delta.destroy !== undefined && delta.destroy.length > 0,
		hasRenames: delta.rename !== undefined && delta.rename.length > 0,
		hasChangesInDocumentTree: deltaFieldMapHasChanges(delta.fields),
		hasChangesInDetachedTrees:
			delta.global?.some((detachedNodeChanges) =>
				deltaFieldMapHasChanges(detachedNodeChanges.fields),
			) === true,
	};
	return profile;
}
export function deltaFieldMapHasChanges(fields: FieldMap | undefined): boolean {
	if (fields === undefined || fields.size === 0) {
		return false;
	}
	for (const [, fieldChanges] of fields) {
		if (deltaFieldChangesHaveChanges(fieldChanges)) {
			return true;
		}
	}
	return false;
}
export function deltaFieldChangesHaveChanges(fieldChanges: FieldChanges): boolean {
	for (const mark of fieldChanges.marks) {
		if (
			mark.attach !== undefined ||
			mark.detach !== undefined ||
			deltaFieldMapHasChanges(mark.fields)
		) {
			return true;
		}
	}
	return false;
}
```

### Decision procedure: `core/tree/detachedFieldIndex.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndex.ts:1-334`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface ReadOnlyDetachedFieldIndex {
	clone(): DetachedFieldIndex;
	toFieldKey(id: ForestRootId): FieldKey;
	tryGetEntry(id: Delta.DetachedNodeId): ForestRootId | undefined;
	getEntry(id: Delta.DetachedNodeId): ForestRootId;
}
export type DetachedFieldIndexCheckpoint = () => void;
export class DetachedFieldIndex implements ReadOnlyDetachedFieldIndex {
	private detachedNodeToField: NestedMap<Major, Minor, DetachedField> = new Map();
	private latestRelevantRevisionToFields: NestedMap<
		RevisionTag | undefined,
		ForestRootId,
		Delta.DetachedNodeId
	> = new Map();
	private isFullyLoaded = true;
	public constructor(
		private readonly name: string,
		private rootIdAllocator: IdAllocator<ForestRootId>,
	) {}
	public clone(): DetachedFieldIndex {
		const clone = new DetachedFieldIndex(
			this.name,
			idAllocatorFromMaxId(this.rootIdAllocator.getMaxId()) as IdAllocator<ForestRootId>,
		);
		populateNestedMap(this.detachedNodeToField, clone.detachedNodeToField, true);
		populateNestedMap(
			this.latestRelevantRevisionToFields,
			clone.latestRelevantRevisionToFields,
			true,
		);
		return clone;
	}
	public createCheckpoint(): DetachedFieldIndexCheckpoint {
		const clone = this.clone();
		return () => {
			this.purge();
			populateNestedMap(clone.detachedNodeToField, this.detachedNodeToField, true);
			populateNestedMap(
				clone.latestRelevantRevisionToFields,
				this.latestRelevantRevisionToFields,
				true,
			);
			this.rootIdAllocator = idAllocatorFromMaxId(
				clone.rootIdAllocator.getMaxId(),
			) as IdAllocator<ForestRootId>;
		};
	}
	public *entries(): Generator<{
		root: ForestRootId;
		latestRelevantRevision?: RevisionTag;
		id: Delta.DetachedNodeId;
	}> {
		for (const [major, innerMap] of this.detachedNodeToField) {
			if (major === undefined) {
				for (const [minor, { root, latestRelevantRevision }] of innerMap) {
					yield latestRelevantRevision === undefined
						? { id: { minor }, root }
						: { id: { minor }, root, latestRelevantRevision };
				}
			} else {
				for (const [minor, { root, latestRelevantRevision }] of innerMap) {
					yield latestRelevantRevision === undefined
						? { id: { major, minor }, root }
						: { id: { major, minor }, root, latestRelevantRevision };
				}
			}
		}
	}
	public purge(): void {
		this.detachedNodeToField.clear();
		this.latestRelevantRevisionToFields.clear();
	}
	public toFieldKey(id: ForestRootId): FieldKey {
		return brand(`${this.name}-${id}`);
	}
	public tryGetEntry(id: Delta.DetachedNodeId): ForestRootId | undefined {
		return tryGetFromNestedMap(this.detachedNodeToField, id.major, id.minor)?.root;
	}
	public getEntry(id: Delta.DetachedNodeId): ForestRootId {
		const key = this.tryGetEntry(id);
		assert(key !== undefined, 0x7aa  );
		return key;
	}
	public *getRootsLastTouchedByRevision(revision: RevisionTag): Iterable<ForestRootId> {
		const roots = this.latestRelevantRevisionToFields.get(revision);
		if (roots !== undefined) {
			yield* roots.keys();
		}
	}
	public deleteRootsLastTouchedByRevision(revision: RevisionTag): void {
		const entries = this.latestRelevantRevisionToFields.get(revision);
		if (entries === undefined) {
			return;
		}
		this.latestRelevantRevisionToFields.delete(revision);
		for (const detachedNodeId of entries.values()) {
			const found = deleteFromNestedMap(
				this.detachedNodeToField,
				detachedNodeId.major,
				detachedNodeId.minor,
			);
			assert(found, 0x9ba  );
		}
	}
	public deleteEntry(nodeId: Delta.DetachedNodeId): void {
		const entry = tryGetFromNestedMap(this.detachedNodeToField, nodeId.major, nodeId.minor);
		assert(entry !== undefined, 0x9bb  );
		deleteFromNestedMap(this.detachedNodeToField, nodeId.major, nodeId.minor);
		deleteFromNestedMap(
			this.latestRelevantRevisionToFields,
			entry.latestRelevantRevision,
			entry.root,
		);
	}
	public createEntry(
		nodeId?: Delta.DetachedNodeId,
		revision?: RevisionTag,
		count: number = 1,
	): ForestRootId {
		const root = this.rootIdAllocator.allocate(count);
		if (nodeId !== undefined) {
			for (let i = 0; i < count; i++) {
				assert(
					tryGetFromNestedMap(this.detachedNodeToField, nodeId.major, nodeId.minor + i) ===
						undefined,
					0x7ce  ,
				);
				setInNestedMap(this.detachedNodeToField, nodeId.major, nodeId.minor + i, {
					root: brand<ForestRootId>(root + i),
					latestRelevantRevision: revision,
				});
				setInNestedMap(this.latestRelevantRevisionToFields, revision, root + i, {
					major: nodeId.major,
					minor: nodeId.minor + i,
				});
			}
		}
		return root;
	}
	public updateLatestRevision(
		id: Delta.DetachedNodeId,
		revision: RevisionTag | undefined,
	): void {
		const fieldEntry = tryGetFromNestedMap(this.detachedNodeToField, id.major, id.minor);
		assert(
			fieldEntry !== undefined,
			0x9bc  ,
		);
		const { root, latestRelevantRevision: previousRevision } = fieldEntry;
		deleteFromNestedMap(this.latestRelevantRevisionToFields, previousRevision, root);
		setInNestedMap(this.latestRelevantRevisionToFields, revision, root, id);
		setInNestedMap(this.detachedNodeToField, id.major, id.minor, {
			root,
			latestRelevantRevision: revision,
		});
	}
	public getSummaryData(): DetachedFieldSummaryData {
		return {
			data: this.detachedNodeToField,
			maxId: this.rootIdAllocator.getMaxId(),
		};
	}
	public loadData(detachedFieldIndex: DetachedFieldSummaryData): void {
		this.rootIdAllocator = idAllocatorFromMaxId(
			detachedFieldIndex.maxId,
		) as IdAllocator<ForestRootId>;
		this.detachedNodeToField = new Map();
		this.latestRelevantRevisionToFields = new Map();
		this.isFullyLoaded = false;
		const rootMap = new Map<ForestRootId, Delta.DetachedNodeId>();
		forEachInNestedMap(detachedFieldIndex.data, ({ root }, major, minor) => {
			setInNestedMap(this.detachedNodeToField, major, minor, { root });
			rootMap.set(root, { major, minor });
		});
		this.latestRelevantRevisionToFields.set(undefined, rootMap);
	}
	public setRevisionsForLoadedData(latestRevision: RevisionTag): void {
		assert(
			!this.isFullyLoaded,
			0x9bd  ,
		);
		const newDetachedNodeToField: NestedMap<Major, Minor, DetachedField> = new Map();
		const rootMap = new Map();
		forEachInNestedMap(this.detachedNodeToField, ({ root }, major, minor) => {
			setInNestedMap(newDetachedNodeToField, major, minor, {
				root,
				latestRelevantRevision: latestRevision,
			});
			rootMap.set(root, { major, minor });
		});
		this.detachedNodeToField = newDetachedNodeToField;
		this.latestRelevantRevisionToFields.delete(undefined);
		this.latestRelevantRevisionToFields.set(latestRevision, rootMap);
		this.isFullyLoaded = true;
	}
}
```

### Decision procedure: `core/tree/detachedFieldIndexTypes.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexTypes.ts:1-52`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type Major = RevisionTag | undefined;
export type Minor = number;
export interface DetachedFieldSummaryData {
	readonly data: ReadonlyNestedMap<Major, Minor, DetachedField>;
	readonly maxId: ForestRootId;
}
export type ForestRootId = Brand<number, "tree.ForestRootId">;
export interface DetachedField {
	readonly root: ForestRootId;
	readonly latestRelevantRevision?: RevisionTag;
}
```

### Decision procedure: `core/tree/mapTree.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/mapTree.ts:1-77`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface MapTree extends NodeData {
	readonly fields: ReadonlyMap<FieldKey, readonly MapTree[]>;
}
export interface ExclusiveMapTree extends NodeData, MapTree {
	fields: Map<FieldKey, ExclusiveMapTree[]>;
}
export function deepCopyMapTree(mapTree: MinimalMapTreeNodeView): ExclusiveMapTree {
	type Next = [
		fields: ExclusiveMapTree["fields"],
		sourceFields: MinimalMapTreeNodeView["fields"],
	];
	function create(
		child: MinimalMapTreeNodeView,
		fields: ExclusiveMapTree["fields"],
	): ExclusiveMapTree {
		return {
			type: child.type,
			...(child.value === undefined ? {} : { value: child.value }),
			fields,
		};
	}
	const rootFields: ExclusiveMapTree["fields"] = new Map();
	const nexts: Next[] = [[rootFields, mapTree.fields]];
	for (let next = nexts.pop(); next !== undefined; next = nexts.pop()) {
		const [fields, sourceFields] = next;
		for (const [key, field] of sourceFields) {
			assert(field.length > 0, 0xbb3  );
			if (field.length > 0) {
				const newField: ExclusiveMapTree[] = [];
				for (const child of field) {
					const childClone = create(child, new Map());
					newField.push(childClone);
					nexts.push([childClone.fields, child.fields]);
				}
				fields.set(key, newField);
			}
		}
	}
	return create(mapTree, rootFields);
}
```

### Decision procedure: `core/tree/pathTree.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/pathTree.ts:1-279`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type UpPathDefault = UpPath;
export interface UpPath<TParent = UpPathDefault> {
	readonly parent: TParent | undefined;
	readonly parentField: FieldKey;
	readonly parentIndex: NodeIndex;
}
export type INormalizedUpPathDefault = INormalizedUpPath;
export interface INormalizedUpPath<TParent = INormalizedUpPathDefault>
	extends UpPath<TParent> {
	readonly detachedNodeId: DetachedNodeId | undefined;
}
export type NormalizedUpPath =
	| INormalizedUpPath<NormalizedUpPath>
	| NormalizedUpPathInterior<NormalizedUpPath>
	| NormalizedUpPathRoot;
export interface NormalizedUpPathRoot extends UpPath<undefined> {
	readonly detachedNodeId: DetachedNodeId | undefined;
}
export type NormalizedUpPathInteriorDefault = NormalizedUpPathInterior;
export interface NormalizedUpPathInterior<
	TParent = NormalizedUpPathInteriorDefault | NormalizedUpPathRoot,
> extends UpPath<TParent> {
	readonly parent: TParent;
}
export type NormalizedFieldUpPath<TParent = NormalizedUpPath> = FieldUpPath<TParent>;
export interface FieldUpPath<TUpPath = UpPath> {
	readonly parent: TUpPath | undefined;
	readonly field: FieldKey;
}
export function isDetachedUpPathRoot<T>(
	path: UpPath<T> | NormalizedUpPath,
): path is NormalizedUpPathRoot {
	return (path as NormalizedUpPathRoot).detachedNodeId !== undefined;
}
export interface Range {
	readonly start: PlaceIndex;
	readonly end: PlaceIndex;
}
export interface RangeUpPath<TUpPath extends UpPath = UpPath>
	extends FieldUpPath<TUpPath>,
		Range {}
export interface PlaceUpPath<TUpPath extends UpPath = UpPath> extends FieldUpPath<TUpPath> {
	readonly index: PlaceIndex;
}
export type NodeIndex = number;
export type PlaceIndex = number;
export function getDepth(path: UpPath): number {
	let depth = 0;
	let next = path.parent;
	while (next !== undefined) {
		depth += 1;
		next = next.parent;
	}
	return depth;
}
export function clonePath(path: UpPath): UpPath;
export function clonePath(path: UpPath | undefined): UpPath | undefined;
export function clonePath(path: UpPath | undefined): UpPath | undefined {
	if (path === undefined) {
		return undefined;
	}
	return {
		parent: clonePath(path.parent),
		parentField: path.parentField,
		parentIndex: path.parentIndex,
	};
}
export function topDownPath(path: UpPath | undefined): UpPath[] {
	const out: UpPath[] = [];
	let curr = path;
	while (curr !== undefined) {
		out.push(curr);
		curr = curr.parent;
	}
	out.reverse();
	return out;
}
export function compareUpPaths(a: UpPath | undefined, b: UpPath | undefined): boolean {
	if (a === b) {
		return true;
	}
	if (a === undefined || b === undefined) {
		return false;
	}
	if (a.parentField !== b.parentField || a.parentIndex !== b.parentIndex) {
		return false;
	}
	return compareUpPaths(a.parent, b.parent);
}
export function compareFieldUpPaths(a: FieldUpPath, b: FieldUpPath): boolean {
	if (a.field !== b.field) {
		return false;
	}
	return compareUpPaths(a.parent, b.parent);
}
export function getDetachedFieldContainingPath(path: UpPath): DetachedField {
	let currentPath = path;
	while (currentPath !== undefined) {
		if (currentPath.parent === undefined) {
			return keyAsDetachedField(currentPath.parentField);
		} else {
			currentPath = currentPath.parent;
		}
	}
	return keyAsDetachedField(path.parentField);
}
```

### Decision procedure: `core/tree/sparseTree.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/sparseTree.ts:1-163`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class SparseNode<TData> implements UpPath {
	public readonly children: Map<FieldKey, SparseNode<TData>[]> = new Map();
	public constructor(
		public parentField: FieldKey,
		public parentIndex: number,
		public parentPath: SparseNode<TData> | undefined,
		public data: TData,
	) {}
	private isRoot(): boolean {
		return this.parentPath === undefined;
	}
	public get parent(): SparseNode<TData> | undefined {
		assert(
			this.parentPath !== undefined,
			0x4a4  ,
		);
		if (this.parentPath.isRoot()) {
			return undefined;
		}
		return this.parentPath;
	}
	public getOrCreateChild(key: FieldKey, index: number, data: () => TData): SparseNode<TData> {
		let field = this.children.get(key);
		if (field === undefined) {
			field = [];
			this.children.set(key, field);
		}
		let child = field.find((c) => c.parentIndex === index);
		if (child === undefined) {
			child = new SparseNode(key, index, this, data());
			field.push(child);
			field.sort((a, b) => a.parentIndex - b.parentIndex);
		}
		return child;
	}
	public tryGetChild(key: FieldKey, index: number): SparseNode<TData> | undefined {
		const field = this.children.get(key);
		if (field === undefined) {
			return undefined;
		}
		return field.find((c) => c.parentIndex === index);
	}
	public removeChild(child: SparseNode<TData>): void {
		const key = child.parentField;
		const field = this.children.get(key);
		const childIndex = field?.indexOf(child) ?? -1;
		assert(childIndex !== -1, 0x4a5  );
		field?.splice(childIndex, 1);
		if (field?.length === 0) {
			this.afterEmptyField(key);
		}
	}
	public afterEmptyField(key: FieldKey): void {
		this.children.delete(key);
		if (this.children.size === 0) {
			this.disposeThis();
		}
	}
	private disposeThis(): void {
		this.parentPath?.removeChild(this);
	}
}
export function getDescendant<TData>(
	ancestor: SparseNode<TData>,
	path: UpPath | undefined,
): SparseNode<TData> {
	const topDown = topDownPath(path);
	let curr = ancestor;
	for (const hop of topDown) {
		const field = curr.children.get(hop.parentField);
		assert(field !== undefined, 0x4a6  );
		const child = field.find((c) => c.parentIndex === hop.parentIndex);
		assert(child !== undefined, 0x4a7  );
		curr = child;
	}
	return curr;
}
```

### Decision procedure: `core/tree/types.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/types.ts:1-157`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type TreeType = TreeNodeSchemaIdentifier;
export const EmptyKey: FieldKey = brand("");
export const rootFieldKey: FieldKey = brand("rootFieldKey");
export const rootField = keyAsDetachedField(rootFieldKey);
export interface ChildLocation {
	readonly container: ChildCollection;
	readonly index: number;
}
export interface RootField {
	readonly key: DetachedField;
}
export type ChildCollection = FieldKey | RootField;
export interface DetachedField extends Opaque<Brand<string, "tree.DetachedField">> {}
export function detachedFieldAsKey(field: DetachedField): FieldKey {
	return brand(extractFromOpaque(field));
}
export function keyAsDetachedField(key: FieldKey): DetachedField {
	return brand(key);
}
export interface FieldKind {
	readonly name: string;
	readonly description: string;
	readonly minimumChildren: number;
	readonly maximumChildren: number;
}
export type TreeValue<TSchema extends ValueSchema = ValueSchema> = [
	{
		[ValueSchema.Number]: number;
		[ValueSchema.String]: string;
		[ValueSchema.Boolean]: boolean;
		[ValueSchema.FluidHandle]: IFluidHandle;
		[ValueSchema.Null]: null;
	}[TSchema],
][_InlineTrick];
export type Value = undefined | TreeValue;
export interface NodeData {
	readonly value?: TreeValue;
	readonly type: TreeNodeSchemaIdentifier;
}
export const aboveRootPlaceholder: TreeNodeSchemaIdentifier = brand(
	"com.fluidframework.placeholder.aboveRoot",
);
```

### Decision procedure: `core/tree/visitDelta.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/visitDelta.ts:1-575`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function visitDelta(
	delta: Delta.Root,
	visitor: DeltaVisitor,
	detachedFieldIndex: DetachedFieldIndex,
	latestRevision: RevisionTag | undefined,
): void {
	const detachPassRoots: Map<ForestRootId, Delta.FieldMap> = new Map();
	const attachPassRoots: Map<ForestRootId, Delta.FieldMap> = new Map();
	const rootTransfers: Delta.DetachedNodeRename[] = [];
	const rootDestructions: Delta.DetachedNodeDestruction[] = [];
	const refreshers: NestedMap<Major, Minor, ITreeCursorSynchronous> = new Map();
	for (const {
		id: { major, minor },
		trees,
	} of delta.refreshers ?? []) {
		const treeCursors = nodeCursorsFromChunk(trees);
		for (let i = 0; i < trees.topLevelLength; i += 1) {
			const offsettedId = minor + i;
			setInNestedMap(refreshers, major, offsettedId, treeCursors[i]);
		}
	}
	const detachConfig: PassConfig = {
		func: detachPass,
		latestRevision,
		refreshers,
		detachedFieldIndex,
		detachPassRoots,
		attachPassRoots,
		rootTransfers,
		rootDestructions,
	};
	processBuilds(delta.build, detachConfig, visitor);
	processGlobal(delta.global, detachConfig, visitor);
	processRename(delta.rename, detachConfig);
	visitFieldMarks(delta.fields, visitor, detachConfig);
	fixedPointVisitOfRoots(visitor, detachPassRoots, detachConfig);
	transferRoots(
		rootTransfers,
		attachPassRoots,
		detachedFieldIndex,
		visitor,
		refreshers,
		latestRevision,
	);
	const attachConfig: PassConfig = {
		func: attachPass,
		latestRevision,
		refreshers,
		detachedFieldIndex,
		detachPassRoots,
		attachPassRoots,
		rootTransfers,
		rootDestructions,
	};
	visitFieldMarks(delta.fields, visitor, attachConfig);
	fixedPointVisitOfRoots(visitor, attachPassRoots, attachConfig);
	collectDestroys(delta.destroy, attachConfig);
	for (const { id, count } of rootDestructions) {
		for (let i = 0; i < count; i += 1) {
			const offsetId = offsetDetachId(id, i);
			const root = detachedFieldIndex.getEntry(offsetId);
			const field = detachedFieldIndex.toFieldKey(root);
			visitor.destroy(field, 1);
			detachedFieldIndex.deleteEntry(offsetId);
		}
	}
}
function fixedPointVisitOfRoots(
	visitor: DeltaVisitor,
	roots: Map<ForestRootId, Delta.FieldMap>,
	config: PassConfig,
): void {
	while (roots.size > 0) {
		for (const [root, modifications] of roots) {
			roots.delete(root);
			const field = config.detachedFieldIndex.toFieldKey(root);
			visitor.enterField(field);
			visitNode(0, modifications, visitor, config);
			visitor.exitField(field);
		}
	}
}
function transferRoots(
	rootTransfers: readonly Delta.DetachedNodeRename[],
	mapToUpdate: Map<ForestRootId, unknown>,
	detachedFieldIndex: DetachedFieldIndex,
	visitor: DeltaVisitor,
	refreshers: NestedMap<Major, Minor, ITreeCursorSynchronous>,
	revision?: RevisionTag,
): void {
	type AtomizedNodeRename = Omit<Delta.DetachedNodeRename, "count">;
	let nextBatch = rootTransfers.flatMap(({ oldId, newId, count }) => {
		const atomized: AtomizedNodeRename[] = [];
		if (!areDetachedNodeIdsEqual(oldId, newId)) {
			for (let i = 0; i < count; i += 1) {
				atomized.push({ oldId: offsetDetachId(oldId, i), newId: offsetDetachId(newId, i) });
			}
		}
		return atomized;
	});
	while (nextBatch.length > 0) {
		const delayed: AtomizedNodeRename[] = [];
		const priorSize = nextBatch.length;
		for (const { oldId, newId } of nextBatch) {
			let oldRootId = detachedFieldIndex.tryGetEntry(oldId);
			if (oldRootId === undefined) {
				const tree = tryGetFromNestedMap(refreshers, oldId.major, oldId.minor);
				if (tree !== undefined) {
					buildTrees(oldId, [tree], detachedFieldIndex, revision, visitor);
					oldRootId = detachedFieldIndex.getEntry(oldId);
				}
			}
			if (oldRootId === undefined) {
				delayed.push({ oldId, newId });
				continue;
			}
			let newRootId = detachedFieldIndex.tryGetEntry(newId);
			if (newRootId !== undefined) {
				delayed.push({ oldId, newId });
				continue;
			}
			newRootId = detachedFieldIndex.createEntry(newId, revision);
			const fields = mapToUpdate.get(oldRootId);
			if (fields !== undefined) {
				mapToUpdate.delete(oldRootId);
				mapToUpdate.set(newRootId, fields);
			}
			const oldField = detachedFieldIndex.toFieldKey(oldRootId);
			const newField = detachedFieldIndex.toFieldKey(newRootId);
			visitor.enterField(oldField);
			visitor.detach({ start: 0, end: 1 }, newField, newId, false);
			visitor.exitField(oldField);
			detachedFieldIndex.deleteEntry(oldId);
		}
		assert(delayed.length < priorSize, 0x7cf  );
		nextBatch = delayed;
	}
}
export interface DeltaVisitor {
	free(): void;
	create(content: readonly ITreeCursorSynchronous[], destination: FieldKey): void;
	destroy(detachedField: FieldKey, count: number): void;
	attach(source: FieldKey, count: number, destination: PlaceIndex): void;
	detach(
		source: Range,
		destination: FieldKey,
		id: Delta.DetachedNodeId,
		isReplaced: boolean,
	): void;
	enterNode(index: NodeIndex): void;
	exitNode(index: NodeIndex): void;
	enterField(key: FieldKey): void;
	exitField(key: FieldKey): void;
	fieldMarks?(marks: readonly Delta.Mark[]): void;
}
interface PassConfig {
	readonly func: Pass;
	readonly latestRevision: RevisionTag | undefined;
	readonly detachedFieldIndex: DetachedFieldIndex;
	readonly refreshers: NestedMap<Major, Minor, ITreeCursorSynchronous>;
	readonly detachPassRoots: Map<ForestRootId, Delta.FieldMap>;
	readonly attachPassRoots: Map<ForestRootId, Delta.FieldMap>;
	readonly rootTransfers: Delta.DetachedNodeRename[];
	readonly rootDestructions: Delta.DetachedNodeDestruction[];
}
type Pass = (delta: Delta.FieldChanges, visitor: DeltaVisitor, config: PassConfig) => void;
function visitFieldMarks(
	fields: Delta.FieldMap | undefined,
	visitor: DeltaVisitor,
	config: PassConfig,
): void {
	if (fields !== undefined) {
		for (const [key, field] of fields) {
			visitor.enterField(key);
			config.func(field, visitor, config);
			visitor.exitField(key);
		}
	}
}
function visitNode(
	index: number,
	fields: Delta.FieldMap | undefined,
	visitor: DeltaVisitor,
	config: PassConfig,
): void {
	if (fields !== undefined) {
		visitor.enterNode(index);
		visitFieldMarks(fields, visitor, config);
		visitor.exitNode(index);
	}
}
function detachPass(
	fieldChanges: Delta.FieldChanges,
	visitor: DeltaVisitor,
	config: PassConfig,
): void {
	visitor.fieldMarks?.(fieldChanges.marks);
	let index = 0;
	for (const mark of fieldChanges.marks) {
		if (mark.fields !== undefined) {
			assert(
				mark.attach === undefined || mark.detach !== undefined,
				0x7d0  ,
			);
			visitNode(index, mark.fields, visitor, config);
		}
		if (mark.detach !== undefined) {
			for (let i = 0; i < mark.count; i += 1) {
				const id = offsetDetachId(mark.detach, i);
				const root = config.detachedFieldIndex.createEntry(id, config.latestRevision);
				if (mark.fields !== undefined) {
					config.attachPassRoots.set(root, mark.fields);
				}
				const field = config.detachedFieldIndex.toFieldKey(root);
				visitor.detach({ start: index, end: index + 1 }, field, id, mark.attach !== undefined);
			}
		}
		if (mark.detach === undefined && mark.attach === undefined) {
			index += mark.count;
		}
	}
}
function buildTrees(
	id: Delta.DetachedNodeId,
	trees: readonly ITreeCursorSynchronous[],
	detachedFieldIndex: DetachedFieldIndex,
	latestRevision: RevisionTag | undefined,
	visitor: DeltaVisitor,
): void {
	for (const [i, tree] of trees.entries()) {
		const offsettedId = offsetDetachId(id, i);
		let root = detachedFieldIndex.tryGetEntry(offsettedId);
		assert(root === undefined, 0x929  );
		root = detachedFieldIndex.createEntry(offsettedId, latestRevision);
		const field = detachedFieldIndex.toFieldKey(root);
		visitor.create([tree], field);
	}
}
function processBuilds(
	builds: readonly Delta.DetachedNodeBuild[] | undefined,
	config: PassConfig,
	visitor: DeltaVisitor,
): void {
	if (builds !== undefined) {
		for (const { id, trees } of builds) {
			buildTrees(
				id,
				nodeCursorsFromChunk(trees),
				config.detachedFieldIndex,
				config.latestRevision,
				visitor,
			);
		}
	}
}
function processGlobal(
	global: readonly Delta.DetachedNodeChanges[] | undefined,
	config: PassConfig,
	visitor: DeltaVisitor,
): void {
	if (global !== undefined) {
		for (const { id, fields } of global) {
			let root = config.detachedFieldIndex.tryGetEntry(id);
			if (root === undefined) {
				const tree = tryGetFromNestedMap(config.refreshers, id.major, id.minor);
				assert(tree !== undefined, 0x928  );
				buildTrees(id, [tree], config.detachedFieldIndex, config.latestRevision, visitor);
				root = config.detachedFieldIndex.getEntry(id);
			}
			config.detachedFieldIndex.updateLatestRevision(id, config.latestRevision);
			config.detachPassRoots.set(root, fields);
			config.attachPassRoots.set(root, fields);
		}
	}
}
function processRename(
	rename: readonly Delta.DetachedNodeRename[] | undefined,
	config: PassConfig,
): void {
	if (rename !== undefined) {
		config.rootTransfers.push(...rename);
	}
}
function collectDestroys(
	destroys: readonly Delta.DetachedNodeDestruction[] | undefined,
	config: PassConfig,
): void {
	if (destroys !== undefined) {
		config.rootDestructions.push(...destroys);
	}
}
function attachPass(
	fieldChanges: Delta.FieldChanges,
	visitor: DeltaVisitor,
	config: PassConfig,
): void {
	let index = 0;
	for (const mark of fieldChanges.marks) {
		if (mark.attach !== undefined) {
			for (let i = 0; i < mark.count; i += 1) {
				const offsetAttachId = offsetDetachId(mark.attach, i);
				let sourceRoot = config.detachedFieldIndex.tryGetEntry(offsetAttachId);
				if (sourceRoot === undefined) {
					const tree = tryGetFromNestedMap(
						config.refreshers,
						offsetAttachId.major,
						offsetAttachId.minor,
					);
					assert(tree !== undefined, 0x92a  );
					buildTrees(
						offsetAttachId,
						[tree],
						config.detachedFieldIndex,
						config.latestRevision,
						visitor,
					);
					sourceRoot = config.detachedFieldIndex.getEntry(offsetAttachId);
				}
				const sourceField = config.detachedFieldIndex.toFieldKey(sourceRoot);
				const offsetIndex = index + i;
				visitor.attach(sourceField, 1, offsetIndex);
				config.detachedFieldIndex.deleteEntry(offsetAttachId);
				const fields = config.attachPassRoots.get(sourceRoot);
				if (fields !== undefined) {
					config.attachPassRoots.delete(sourceRoot);
					visitNode(offsetIndex, fields, visitor, config);
				}
			}
		}
		if (mark.detach === undefined && mark.fields !== undefined) {
			visitNode(index, mark.fields, visitor, config);
		}
		if (mark.detach === undefined || mark.attach !== undefined) {
			index += mark.count;
		}
	}
}
function nodeCursorsFromChunk(trees: TreeChunk): ITreeCursorSynchronous[] {
	return mapCursorField(trees.cursor(), (c) => c.fork());
}
```

### Decision procedure: `core/tree/visitorUtils.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/visitorUtils.ts:1-220`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function makeDetachedFieldIndex(prefix: string = "Temp"): DetachedFieldIndex {
	return new DetachedFieldIndex(prefix, idAllocatorFromMaxId() as IdAllocator<ForestRootId>);
}
export function applyDelta(
	delta: Root,
	latestRevision: RevisionTag | undefined,
	deltaProcessor: { acquireVisitor: () => DeltaVisitor },
	detachedFieldIndex: DetachedFieldIndex,
): void {
	const visitor = deltaProcessor.acquireVisitor();
	visitDelta(delta, visitor, detachedFieldIndex, latestRevision);
	visitor.free();
}
export interface CombinedVisitor extends DeltaVisitor {
	readonly type: "Combined";
	readonly visitors: readonly CombinableVisitor[];
}
export type CombinableVisitor =
	| (DeltaVisitor & { type?: never })
	| AnnouncedVisitor
	| CombinedVisitor;
export function makeBreakingVisitor(
	visitor: DeltaVisitor & { readonly type?: never },
	breaker: Breakable,
): DeltaVisitor & { readonly type?: never } {
	return {
		free: () => breaker.run(() => visitor.free()),
		create: (...args) => breaker.run(() => visitor.create(...args)),
		destroy: (...args) => breaker.run(() => visitor.destroy(...args)),
		attach: (...args) => breaker.run(() => visitor.attach(...args)),
		detach: (...args) => breaker.run(() => visitor.detach(...args)),
		enterNode: (...args) => breaker.run(() => visitor.enterNode(...args)),
		exitNode: (...args) => breaker.run(() => visitor.exitNode(...args)),
		enterField: (...args) => breaker.run(() => visitor.enterField(...args)),
		exitField: (...args) => breaker.run(() => visitor.exitField(...args)),
		fieldMarks: (...args) => breaker.run(() => visitor.fieldMarks?.(...args)),
	};
}
export function combineVisitors(visitors: readonly CombinableVisitor[]): CombinedVisitor {
	const allVisitors = visitors.flatMap((v) => (v.type === "Combined" ? v.visitors : [v]));
	const announcedVisitors = allVisitors.filter(
		(v): v is AnnouncedVisitor => v.type === "Announced",
	);
	return {
		type: "Combined",
		visitors: allVisitors,
		free: () => {
			for (const v of visitors) {
				v.free();
			}
		},
		create: (...args) => {
			for (const v of allVisitors) {
				v.create(...args);
			}
			for (const v of announcedVisitors) {
				v.afterCreate(...args);
			}
		},
		destroy: (...args) => {
			for (const v of announcedVisitors) {
				v.beforeDestroy(...args);
			}
			for (const v of allVisitors) {
				v.destroy(...args);
			}
		},
		attach: (source: FieldKey, count: number, destination: PlaceIndex) => {
			for (const v of announcedVisitors) {
				v.beforeAttach(source, count, destination);
			}
			for (const v of allVisitors) {
				v.attach(source, count, destination);
			}
			for (const v of announcedVisitors) {
				v.afterAttach(source, {
					start: destination,
					end: destination + count,
				});
			}
		},
		detach: (
			source: Range,
			destination: FieldKey,
			id: DetachedNodeId,
			isReplaced: boolean,
		) => {
			for (const v of announcedVisitors) {
				v.beforeDetach(source, destination, isReplaced);
			}
			for (const v of allVisitors) {
				v.detach(source, destination, id, isReplaced);
			}
			for (const v of announcedVisitors) {
				v.afterDetach(source.start, source.end - source.start, destination, isReplaced);
			}
		},
		enterNode: (...args) => {
			for (const v of allVisitors) {
				v.enterNode(...args);
			}
		},
		exitNode: (...args) => {
			for (const v of allVisitors) {
				v.exitNode(...args);
			}
		},
		enterField: (...args) => {
			for (const v of allVisitors) {
				v.enterField(...args);
			}
		},
		exitField: (...args) => {
			for (const v of allVisitors) {
				v.exitField(...args);
			}
		},
		fieldMarks: (marks) => {
			for (const v of allVisitors) {
				v.fieldMarks?.(marks);
			}
		},
	};
}
export interface AnnouncedVisitor extends DeltaVisitor {
	readonly type: "Announced";
	afterCreate(content: readonly ITreeCursorSynchronous[], destination: FieldKey): void;
	beforeDestroy(field: FieldKey, count: number): void;
	beforeAttach(source: FieldKey, count: number, destination: PlaceIndex): void;
	afterAttach(source: FieldKey, destination: Range): void;
	beforeDetach(source: Range, destination: FieldKey, isReplaced: boolean): void;
	afterDetach(
		source: PlaceIndex,
		count: number,
		destination: FieldKey,
		isReplaced: boolean,
	): void;
}
const noOp = (): void => {};
export function createAnnouncedVisitor(
	visitorFunctions: Partial<AnnouncedVisitor>,
): AnnouncedVisitor {
	return {
		type: "Announced",
		free: visitorFunctions.free ?? noOp,
		create: visitorFunctions.create ?? noOp,
		afterCreate: visitorFunctions.afterCreate ?? noOp,
		beforeDestroy: visitorFunctions.beforeDestroy ?? noOp,
		destroy: visitorFunctions.destroy ?? noOp,
		beforeAttach: visitorFunctions.beforeAttach ?? noOp,
		attach: visitorFunctions.attach ?? noOp,
		afterAttach: visitorFunctions.afterAttach ?? noOp,
		beforeDetach: visitorFunctions.beforeDetach ?? noOp,
		detach: visitorFunctions.detach ?? noOp,
		afterDetach: visitorFunctions.afterDetach ?? noOp,
		enterNode: visitorFunctions.enterNode ?? noOp,
		exitNode: visitorFunctions.exitNode ?? noOp,
		enterField: visitorFunctions.enterField ?? noOp,
		exitField: visitorFunctions.exitField ?? noOp,
	};
}
```

### Decision procedure: `core/forest/editableForest.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/forest/editableForest.ts:1-50`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface IEditableForest extends IForestSubscription {
	acquireVisitor(): DeltaVisitor;
}
export type ForestLocation = ITreeSubscriptionCursor | Anchor;
export interface TreeLocation {
	readonly range: FieldLocation | DetachedField;
	readonly index: number;
}
export function isFieldLocation(range: FieldLocation | DetachedField): range is FieldLocation {
	return typeof range === "object";
}
export interface FieldLocation {
	readonly key: FieldKey;
	readonly parent: ForestLocation;
}
```

### Decision procedure: `core/forest/forest.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/core/forest/forest.ts:1-295`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface ForestEvents {
	afterRootFieldCreated(key: FieldKey): void;
	beforeChange(): void;
}
export interface IForestSubscription extends WithBreakable {
	readonly events: Listenable<ForestEvents>;
	readonly anchors: AnchorSet;
	clone(schema: TreeStoredSchemaSubscription, breaker?: Breakable): IEditableForest;
	chunkField(cursor: ITreeCursorSynchronous): TreeChunk[];
	allocateCursor(source?: string): ITreeSubscriptionCursor;
	forgetAnchor(anchor: Anchor): void;
	tryMoveCursorToNode(
		destination: Anchor,
		cursorToMove: ITreeSubscriptionCursor,
	): TreeNavigationResult;
	tryMoveCursorToField(
		destination: FieldAnchor,
		cursorToMove: ITreeSubscriptionCursor,
	): TreeNavigationResult;
	moveCursorToPath(destination: UpPath, cursorToMove: ITreeSubscriptionCursor): void;
	getCursorAboveDetachedFields(): ITreeCursorSynchronous;
	readonly isEmpty: boolean;
	registerAnnouncedVisitor(visitor: () => AnnouncedVisitor): void;
	deregisterAnnouncedVisitor(visitor: () => AnnouncedVisitor): void;
}
export function rootAnchor(field: DetachedField = rootField): FieldAnchor {
	return {
		parent: undefined,
		fieldKey: detachedFieldAsKey(field),
	};
}
export function moveToDetachedField(
	forest: IForestSubscription,
	cursorToMove: ITreeSubscriptionCursor,
	field: DetachedField = rootField,
): void {
	const result = forest.tryMoveCursorToField(rootAnchor(field), cursorToMove);
	assert(
		result === TreeNavigationResult.Ok,
		0x42d  ,
	);
}
export interface FieldAnchor {
	parent: Anchor | undefined;
	fieldKey: FieldKey;
}
export interface ITreeSubscriptionCursor extends ITreeCursor {
	fork(source?: string): ITreeSubscriptionCursor;
	free(): void;
	clear(): void;
	buildAnchor(): Anchor;
	buildFieldAnchor(): FieldAnchor;
	readonly state: ITreeSubscriptionCursorState;
}
export enum ITreeSubscriptionCursorState {
	Current,
	Cleared,
	Freed,
}
export const enum TreeNavigationResult {
	NotFound = -1,
	Pending = 0,
	Ok = 1,
}
export type SynchronousNavigationResult =
	| TreeNavigationResult.Ok
	| TreeNavigationResult.NotFound;
```

### Decision procedure: `feature-libraries/detachedFieldIndexSummarizer.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/detachedFieldIndexSummarizer.ts:1-135`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const detachedFieldIndexBlobKey = "DetachedFieldIndexBlob";
export const enum DetachedFieldIndexSummaryFormatVersion {
	v1 = 1,
	v2 = 2,
	vLatest = v2,
}
const supportedVersions = new Set<DetachedFieldIndexSummaryFormatVersion>([
	DetachedFieldIndexSummaryFormatVersion.v1,
	DetachedFieldIndexSummaryFormatVersion.v2,
]);
function minVersionToDetachedFieldIndexSummaryFormatVersion(
	version: OldestSupportedClientVersion,
): DetachedFieldIndexSummaryFormatVersion {
	return DetachedFieldIndexSummaryFormatVersion.v2;
}
export class DetachedFieldIndexSummarizer
	extends VersionedSummarizer<DetachedFieldIndexSummaryFormatVersion>
	implements Summarizable
{
	private readonly codec: IJsonCodec<DetachedFieldSummaryData>;
	public constructor(
		private readonly detachedFieldIndex: DetachedFieldIndex,
		revisionTagCodec: RevisionTagCodec,
		idCompressor: IIdCompressor,
		options?: CodecWriteOptions,
	) {
		const normalizedOptions = options ?? {
			jsonValidator: FormatValidatorNoOp,
			minVersionForCollab: FluidClientVersion.v2_0,
		};
		super(
			"DetachedFieldIndex",
			minVersionToDetachedFieldIndexSummaryFormatVersion(
				normalizedOptions.minVersionForCollab,
			),
			supportedVersions,
			true,
		);
		this.codec = detachedFieldIndexCodecBuilder.build({
			...normalizedOptions,
			revisionTagCodec,
			idCompressor,
		});
	}
	protected summarizeInternal(props: {
		stringify: SummaryElementStringifier;
		fullTree?: boolean;
		trackState?: boolean;
		telemetryContext?: ITelemetryContext;
		incrementalSummaryContext?: IExperimentalIncrementalSummaryContext;
		builder: SummaryTreeBuilder;
	}): void {
		const { stringify, builder } = props;
		const data = this.codec.encode(this.detachedFieldIndex.getSummaryData());
		builder.addBlob(detachedFieldIndexBlobKey, stringify(data));
	}
	protected async loadInternal(
		services: IChannelStorageService,
		parse: SummaryElementParser,
	): Promise<void> {
		if (await services.contains(detachedFieldIndexBlobKey)) {
			const detachedFieldIndexBuffer = await services.readBlob(detachedFieldIndexBlobKey);
			const treeBufferString = bufferToString(detachedFieldIndexBuffer, "utf8");
			const parsed = parse(treeBufferString) as JsonCompatibleReadOnly;
			const decoded = this.codec.decode(parsed);
			this.detachedFieldIndex.loadData(decoded);
		}
	}
}
```

## 5. Invariants and asserts

0x88d rejects non-root string revision; 0x88f/0x890 require final numeric IDs in V1 detached index; 0xbfd validates root/stable/final V2 majors. 0x7cf rejects a rename dependency cycle/missing source with no progress. Delta count with nested edits must refer to exactly one old node; do not interpret zero count as a real edit. Anchors reject using disposed paths (0x409) or adding refs to non-live nodes (0x40a). `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/revisionTagCodec.ts:34` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecV1.ts:49` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecV2.ts:40` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/visitDelta.ts:222` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/anchorSet.ts:1161`

Rebase debug validation is configurable Cheap/Strict and can be optimized out; setting nonzero level in optimized builds throws UsageError. Do not accidentally make debug-only equivalence checks wire admission requirements. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/rebaseValidation.ts:117`

## 6. JS-semantics hazards

`undefined` revision sorts before defined values in partial comparators; numeric revision order is NOT chronology (revision metadata provides chronology). Compare atoms by both components. Preserve Map insertion order for summaries. Paths/anchors and graph commits depend on reference identity; a Swift value copy cannot replace shared identity casually. Tree null leaf is distinct from absent value. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/types.ts:96` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/rebase/types.ts:157` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/anchorSet.ts:1095` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/tree/detachedFieldIndexCodecCommon.ts:39`

## 7. Test assets to reuse

Port core tree anchor/delta/detached-index tests and revision codec cases; snapshot detached-field-index formats. Use source test implementations as assets, not inferred laws: `reference/fluidframework-3.11.0/packages/dds/tree/src/test/core/tree/anchorSet.spec.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/test/core/tree/detachedFieldIndex.spec.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/test/core/tree/visitDelta.spec.ts:1`

## 8. Open questions

None about supported formats. No Swift representation is prescribed for intrusive PathNode lifetimes; it must preserve the identity and notification behavior above.

