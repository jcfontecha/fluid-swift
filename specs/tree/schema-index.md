# Schema Index — Fluid Framework 3.11.0

## 1. Role

Schema-index serializes stored schema and supplies its summary component. Schema compatibility policy is supplied by default-schema, not inferred by this codec. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/codec.ts:100`

## 2. Surface used by other packages

schemaCodecBuilder, SchemaSummarizer and format schemas. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/index.ts:6`

## 3. Wire and persisted formats

Schema v1 baseline and v2 at minimum 2.43; both read. Emit `{version,nodes,root}`. nodes is a null-prototype JSON object of node schema names; names inserted in JS lexical sorted order, then JSON integer-key ordering still applies. v1 node value singleton union `{object:recordOfFieldSchema}` / `{map:fieldSchema}` / `{leaf:enum}`. v2 node value `{kind:union,metadata?}` and fields gain metadata. Field `{kind,types,metadata?}`; types are sorted by JavaScript default string sort (UTF-16 lexicographic order). Enum leaf numbers 0 number,1 string,2 boolean,3 handle,4 null. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/codec.ts:25` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/codec.ts:51` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/formatV1.ts:49` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/formatV2.ts:26`

Summary subtree `Schema`, layout v2 always written; `.metadata` version 2 and `SchemaString` blob containing JSON schema payload. Accept layout v1/2 and pre-metadata layout. Payload version independent of layout. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/schemaSummarizer.ts:32` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/schemaSummarizer.ts:60`


### Decision procedure: `feature-libraries/schema-index/codec.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/codec.ts:1-119`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
function encodeRepoV1(repo: TreeStoredSchema): FormatV1 {
	const nodeSchema = encodeNodeSchema(repo, (schema) => schema.encodeV1());
	const rootFieldSchema = encodeFieldSchemaV1(repo.rootFieldSchema);
	return {
		version: SchemaFormatVersion.v1,
		nodes: nodeSchema,
		root: rootFieldSchema,
	};
}
function encodeRepoV2(repo: TreeStoredSchema): FormatV2 {
	const nodeSchema = encodeNodeSchema(repo, (schema) => schema.encodeV2());
	const rootFieldSchema = encodeFieldSchemaV2(repo.rootFieldSchema);
	return {
		version: SchemaFormatVersion.v2,
		nodes: nodeSchema,
		root: rootFieldSchema,
	};
}
function encodeNodeSchema<TFormat>(
	repo: TreeStoredSchema,
	encodeValue: (schema: TreeNodeStoredSchema) => TFormat,
): Record<string, TFormat> {
	const nodeSchema: Record<string, TFormat> = Object.create(null) as Record<string, TFormat>;
	for (const name of [...repo.nodeSchema.keys()].sort()) {
		const schema = repo.nodeSchema.get(name) ?? fail(0xb28  );
		Object.defineProperty(nodeSchema, name, {
			enumerable: true,
			configurable: true,
			writable: true,
			value: encodeValue(schema),
		});
	}
	return nodeSchema;
}
function decodeV1(f: FormatV1): TreeStoredSchema {
	const nodeSchema: Map<TreeNodeSchemaIdentifier, TreeNodeStoredSchema> = new Map();
	for (const [key, schema] of Object.entries(f.nodes)) {
		const storedSchemaDecoder = storedSchemaDecodeDispatcher.dispatch(schema);
		nodeSchema.set(brand(key), storedSchemaDecoder(undefined));
	}
	return {
		rootFieldSchema: decodeFieldSchema(f.root),
		nodeSchema,
	};
}
function decodeV2(f: FormatV2): TreeStoredSchema {
	const nodeSchema: Map<TreeNodeSchemaIdentifier, TreeNodeStoredSchema> = new Map();
	for (const [key, schema] of Object.entries(f.nodes)) {
		const storedSchemaDecoder = storedSchemaDecodeDispatcher.dispatch(schema.kind);
		nodeSchema.set(brand(key), storedSchemaDecoder(schema.metadata));
	}
	return {
		rootFieldSchema: decodeFieldSchema(f.root),
		nodeSchema,
	};
}
export const schemaCodecBuilder = VersionDispatchingCodecBuilder.build("Schema", [
	{
		minVersionForCollab: lowestMinVersionForCollab,
		formatVersion: SchemaFormatVersion.v1,
		codec: {
			encode: (data: TreeStoredSchema) => encodeRepoV1(data),
			decode: (data: FormatV1) => decodeV1(data),
			schema: FormatV1,
		},
	},
	{
		minVersionForCollab: FluidClientVersion.v2_43,
		formatVersion: SchemaFormatVersion.v2,
		codec: {
			encode: (data: TreeStoredSchema) => encodeRepoV2(data),
			decode: (data: FormatV2) => decodeV2(data),
			schema: FormatV2,
		},
	},
]);
```

### Decision procedure: `feature-libraries/schema-index/formatV1.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/formatV1.ts:1-31`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
export const Format = Type.Object(
	{
		version: Type.Literal(SchemaFormatVersion.v1),
		nodes: Type.Record(Type.String(), schemaFormatV1.TreeNodeSchemaDataFormat),
		root: schemaFormatV1.FieldSchemaFormat,
	},
	noAdditionalProps,
);
export type Format = Static<typeof Format>;
```

### Decision procedure: `feature-libraries/schema-index/formatV2.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/formatV2.ts:1-31`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
export const Format = Type.Object(
	{
		version: Type.Literal(SchemaFormatVersion.v2),
		nodes: Type.Record(Type.String(), schemaFormatV2.TreeNodeSchemaDataFormat),
		root: schemaFormatV2.FieldSchemaFormat,
	},
	noAdditionalProps,
);
export type Format = Static<typeof Format>;
```

### Literal schema examples

Empty v1 repository: `{"version":1,"nodes":{},"root":{"kind":"Forbidden","types":[]}}`. Empty v2 repository has the identical body except `"version":2`. A v1 leaf type N with a single root value is `{"version":1,"nodes":{"N":{"leaf":0}},"root":{"kind":"Value","types":["N"]}}`; v2 wraps N as `{"kind":{"leaf":0}}`. Metadata, when present, is appended after kind in nodes and after types in fields. Object field names and allowed-type lists are sorted by UTF-16 lexical order before emission, with JS integer-property ordering applied when JSON is written. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/codec.ts:25-98` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/schema.ts:232-275` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/schema.ts:386-406`

## 4. Behavior

Encode node schema names sorted, obtain schema or fail 0xb28, define enumerable own property safely (handles names like __proto__), encode root. Decode Object.entries in JS property order, dispatch node kind; v1 metadata undefined; v2 use node metadata. Decode field types into Set. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/codec.ts:51` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/codec.ts:69`

Schema repository apply emits beforeSchemaChange, replaces root/node collection, emits afterSchemaChange (the repository decision procedure includes the exact event calls). Summarizer records current collab sequence on afterSchemaChange. Reuse prior SchemaString blob handle only if !fullTree, incremental context present, known last-changed seq and latestSummarySequenceNumber >= last change; otherwise encode fresh blob. Load requires empty schema, decodes UTF-8 JSON then apply and sets last-change seq=0. `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/storedSchemaRepository.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/schemaSummarizer.ts:88` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/schemaSummarizer.ts:104`

### Algorithm notation and completeness

The following decision procedures are part of this specification, not external reading assignments. They preserve exact predicates, allocation order, collection traversal, return shapes and synchronous event calls. `undefined` means absent; `null` is a value; object spread is right-biased; `delete` removes a property; `Map`/`Set` iterate in insertion order. TypeBox `Optional(T)` permits absence, not null; tuples are fixed-order JSON arrays; singleton discriminated unions have exactly one case property. Assertions stop execution at the displayed short code. Helpers in another area use that area's same-named procedure; generic collection utilities retain JavaScript order. These are reference algorithms to translate into Swift, not a proposal to embed TypeScript in the client.

### Decision procedure: `feature-libraries/schema-index/schemaSummarizer.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/schemaSummarizer.ts:1-141`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const schemaStringKey = "SchemaString";
export const enum SchemaSummaryFormatVersion {
	v1 = 1,
	v2 = 2,
	vLatest = v2,
}
const supportedVersions = new Set<SchemaSummaryFormatVersion>([
	SchemaSummaryFormatVersion.v1,
	SchemaSummaryFormatVersion.v2,
]);
function minVersionToSchemaSummaryFormatVersion(
	version: OldestSupportedClientVersion,
): SchemaSummaryFormatVersion {
	return SchemaSummaryFormatVersion.v2;
}
export class SchemaSummarizer
	extends VersionedSummarizer<SchemaSummaryFormatVersion>
	implements Summarizable
{
	private schemaIndexLastChangedSeq: number | undefined;
	public constructor(
		private readonly schema: MutableTreeStoredSchema,
		collabWindow: CollabWindow,
		private readonly codec: IJsonCodec<TreeStoredSchema>,
		minVersionForCollab: OldestSupportedClientVersion,
	) {
		super(
			"Schema",
			minVersionToSchemaSummaryFormatVersion(minVersionForCollab),
			supportedVersions,
			true  ,
		);
		this.schema.events.on("afterSchemaChange", () => {
			this.schemaIndexLastChangedSeq = collabWindow.getCurrentSeq();
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
		const { builder, incrementalSummaryContext, stringify, fullTree = false } = props;
		if (
			!fullTree &&
			incrementalSummaryContext !== undefined &&
			this.schemaIndexLastChangedSeq !== undefined &&
			incrementalSummaryContext.latestSummarySequenceNumber >= this.schemaIndexLastChangedSeq
		) {
			builder.addHandle(
				schemaStringKey,
				SummaryType.Blob,
				`${incrementalSummaryContext.summaryPath}/${schemaStringKey}`,
			);
		} else {
			const dataString = stringify(this.codec.encode(this.schema));
			builder.addBlob(schemaStringKey, dataString);
		}
	}
	protected async loadInternal(
		services: IChannelStorageService,
		parse: SummaryElementParser,
	): Promise<void> {
		const schemaBuffer: ArrayBufferLike = await services.readBlob(schemaStringKey);
		assert(
			schemaDataIsEmpty(this.schema),
			0x3da  ,
		);
		const schemaString = bufferToString(schemaBuffer, "utf8");
		const decoded = this.codec.decode(JSON.parse(schemaString));
		this.schema.apply(decoded);
		this.schemaIndexLastChangedSeq = 0;
	}
}
```

## 5. Invariants and asserts

0x3da rejects loading over existing schema. Unknown node kind rejected by discriminated union dispatcher. Metadata is persisted but not a change to structural field multiplicity. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/schemaSummarizer.ts:130` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/codec.ts:69`

## 6. JS-semantics hazards

Use UTF-16 JS lexical sort, not locale or Unicode-scalar order. JS object integer-looking keys reorder on stringify after insertion; Swift ordered dictionary alone is insufficient. `Object.create(null)`/defineProperty avoids prototype pollution and includes own schema names literally. Omit undefined metadata, preserve null inside JSON metadata. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-index/codec.ts:55` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/formatV2.ts:19`

## 7. Test assets to reuse

Reuse schema codec/summarizer snapshots and stored-schema tests; cover keys __proto__, numeric-looking names, supplementary/lone-surrogate sort ordering, and both payload versions. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/feature-libraries/schema-index/codec.spec.ts:1`

## 8. Open questions

None.

