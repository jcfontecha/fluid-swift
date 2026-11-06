# Chunked Forest — Fluid Framework 3.11.0

## 1. Role

ChunkedForest implements IEditableForest with reference-counted chunks and copy-on-write editing. FieldBatch codec serializes forest content and modular detached builds; it is not the op change codec. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/chunkedForest.ts:153` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/codecs.ts:237`

## 2. Surface used by other packages

ChunkedForest/build forest, chunkField/chunkTree and policy, BasicChunk/UniformChunk/SequenceChunk/emptyChunk cursors, fieldBatchCodecBuilder, FieldBatchDecodingContext, IncrementalEncoder/Decoder. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/index.ts:6`

## 3. Wire and persisted formats

### All registered field-batch versions

JSON emission is built by the encoding pipeline; envelope carries `version`, `identifiers:string[]`, `shapes:Shape[]`, `data:any[][]`. Each data member is ONE field encoded through the any-shape decoder (first token selects a shape). Dictionary indexes are zero-based. Registered versions 1 (baseline), 2 (minimum 2.73), and string `"text"` (explicit potentially-incompatible override only). V1 shapes a–d, v2 a–e, text a–f. Decoder dispatches explicit version independently of write version. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/codecs.ts:319` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/format/versions.ts:21` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkDecodingGeneric.ts:20`

| shape union key | payload | stream consumed |
| --- | --- | --- |
| a | shapeIndex | one nested token: array consumed until exhausted, OR number repetitions for zero-token element shape |
| b | `{length,shape}` | exactly length elements decoded inline |
| c | node shape `{type?,value?,fields?,extraFields?}` | optional runtime type, value tokens, fixed fields in shape order, optional extra-fields nested array |
| d | literal 0 | next token is shape index, then decode selected shape |
| e (v2/text) | literal 0 | chunk reference ID, delegated to incremental decoder |
| f (text) | `{base,fields?,value?,extraFields?}` | normalize specialized node shape, then same stream as c |

Fixed fields are `[keyOrIdentifierIndex,shapeIndex]` tuples. IdentifierOrIndex is literal string or nonnegative dictionary index, never a compressed node identifier. Missing node type reads identifier token; fixed type consumes none. Missing value shape reads boolean and then value iff true; `true` consumes value; `false` consumes none; `[constant]` consumes none; numeric SpecialField.Identifier=0 consumes string/op-space ID and resolves/decompresses using ID context. Despite an outdated format comment, Identifier DOES consume a token. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/format/formatV1.ts:15` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkDecoding.ts:243`

Text specialization: resolve base transitively (must be c/f); inherited type is immutable. Existing field override replaces shape in original field position; new key appends after inherited fields. Missing value/extraFields inherits, null explicitly clears, any other value replaces. Reject cycles and duplicate keys. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkDecoding.ts:93`

### Exact byte-producing codec procedures

Section 4 includes schema selection, identifier/shape dictionary construction and encoding/decoding branches. A semantically equivalent dictionary allocation is not byte-equivalent. No binary chunk format is registered here: values can include Fluid handles serialized by the containing summary serializer. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/compressedEncode.ts:57` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/uncompressedEncode.ts:6`


### Decision procedure: `feature-libraries/chunked-forest/codec/chunkCodecUtilities.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkCodecUtilities.ts:1-183`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class Counter<T> {
	private readonly counts: Map<T, number> = new Map();
	public add(t: T, count = 1): void {
		const old = this.counts.get(t) ?? 0;
		this.counts.set(t, old + count);
	}
	public buildTable(filter: CounterFilter<T> = (): boolean => true): DeduplicationTable<T> {
		const data: T[] = [...this.counts.keys()];
		data.sort((a, b) => (this.counts.get(b) ?? 0) - (this.counts.get(a) ?? 0));
		const filtered: T[] = [];
		for (const t of data) {
			const include = filter(t, filtered.length, this.counts.get(t) ?? 0);
			if (include) {
				filtered.push(t);
			}
		}
		return {
			indexToValue: filtered,
			valueToIndex: new Map(filtered.map((t, index) => [t, index])),
		};
	}
}
export type CounterFilter<T> = (t: T, value: number, count: number) => boolean;
export interface DeduplicationTable<T> {
	readonly valueToIndex: ReadonlyMap<T, number>;
	readonly indexToValue: readonly T[];
}
export function jsonMinimizingFilter(s: string, value: number, count: number): boolean {
	const quotedAndEscaped = JSON.stringify(s);
	const lengthUsingTable = String(value).length * count + quotedAndEscaped.length + 1;
	const lengthWithoutTable = quotedAndEscaped.length * count;
	return lengthUsingTable < lengthWithoutTable;
}
export function getChecked<T>(data: readonly T[], index: number): T {
	assertValidIndex(index, data);
	return data[index] ?? oob();
}
export interface StreamCursor {
	readonly data: readonly FluidSerializableReadOnly[];
	offset: number;
}
export function readStream(stream: StreamCursor): FluidSerializableReadOnly {
	const content = getChecked(stream.data, stream.offset);
	stream.offset++;
	return content;
}
export function readStreamNumber(stream: StreamCursor): number {
	const content = readStream(stream);
	assert(typeof content === "number", 0x730  );
	return content;
}
export function readStreamBoolean(stream: StreamCursor): boolean {
	const content = readStream(stream);
	assert(typeof content === "boolean", 0x731  );
	return content;
}
export function readStreamValue(stream: StreamCursor): TreeValue {
	const content = readStream(stream);
	assertAllowedValue(content);
	return content;
}
export function readStreamStream(stream: StreamCursor): StreamCursor {
	const content = readStream(stream);
	assert(Array.isArray(content), 0x732  );
	return { data: content, offset: 0 };
}
export interface ChunkDecoder {
	decode(decoders: readonly ChunkDecoder[], stream: StreamCursor): TreeChunk;
}
```

### Decision procedure: `feature-libraries/chunked-forest/codec/codecs.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/codecs.ts:1-353`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type ChunkReferenceId = Brand<number, "forest.ChunkReferenceId">;
const ChunkReferenceId = brandedIntegerType<ChunkReferenceId>({ minimum: 0 });
export interface IncrementalEncoder {
	shouldEncodeIncrementally: IncrementalEncodingPolicy;
	encodeIncrementalField(
		cursor: ITreeCursorSynchronous,
		chunkEncoder: (chunk: TreeChunk) => EncodedFieldBatchAnyVersion,
	): ChunkReferenceId[];
}
export interface IncrementalDecoder {
	decodeIncrementalChunk(
		referenceId: ChunkReferenceId,
		chunkDecoder: (encoded: EncodedFieldBatchAnyVersion) => TreeChunk,
	): TreeChunk;
}
export interface IncrementalEncoderDecoder extends IncrementalEncoder, IncrementalDecoder {}
export interface FieldBatchEncodingContext {
	readonly encodeType: TreeCompressionStrategy;
	readonly idCompressor: IIdCompressor;
	readonly schema?: SchemaAndPolicy;
	readonly incrementalEncoder?: IncrementalEncoder;
	readonly isSummary: boolean;
}
export class FieldBatchDecodingContext {
	private constructor(
		public readonly idDecodingContext: IdDecodingContext,
		public readonly incrementalDecoder?: IncrementalDecoder,
	) {}
	public static forOp(options: IdDecoderOptionsWithOriginator): FieldBatchDecodingContext {
		return new FieldBatchDecodingContext(new IdDecodingContext(options));
	}
	public static forSummary(
		options: IdDecoderOptionsOriginatorless | IdDecoderOptionsWithOriginator,
	): FieldBatchDecodingContext {
		return new FieldBatchDecodingContext(new IdDecodingContext(options));
	}
	public withIncrementalDecoder(
		incrementalDecoder: IncrementalDecoder,
	): FieldBatchDecodingContext {
		assert(
			!this.idDecodingContext.hasOriginatorSessionId,
			0xd0c  ,
		);
		return new FieldBatchDecodingContext(this.idDecodingContext, incrementalDecoder);
	}
}
export type FieldBatchCodec = VersionDispatchingCodec<
	FieldBatch,
	FieldBatchEncodingContext,
	FieldBatchFormatVersion,
	FieldBatchDecodingContext
>;
function makeFieldBatchCodecForVersion(
	version: FieldBatchFormatVersion,
	uncompressedEncodeFn: (batch: FieldBatch) => EncodedFieldBatchAnyVersion,
	schemaCompressedEncodeFn: (
		schema: StoredSchemaCollection,
		policy: SchemaPolicy,
		fieldBatch: FieldBatch,
		idCompressor: IIdCompressor,
		incrementalEncoder: IncrementalEncoder | undefined,
		isSummary: boolean,
	) => EncodedFieldBatchAnyVersion,
	encodedFieldBatchType: TSchema,
): CodecAndSchema<FieldBatch, FieldBatchEncodingContext, FieldBatchDecodingContext> {
	return {
		encode: (
			data: FieldBatch,
			context: FieldBatchEncodingContext,
		): EncodedFieldBatchAnyVersion => {
			for (const cursor of data) {
				assert(
					cursor.mode === CursorLocationType.Fields,
					0x8a3  ,
				);
			}
			let encoded: EncodedFieldBatchAnyVersion;
			let incrementalEncoder: IncrementalEncoder | undefined;
			switch (context.encodeType) {
				case TreeCompressionStrategy.Uncompressed: {
					encoded = uncompressedEncodeFn(data);
					break;
				}
				case TreeCompressionStrategy.CompressedIncremental: {
					assert(
						supportsIncrementalEncoding(version),
						0xca0  ,
					);
					incrementalEncoder = context.incrementalEncoder;
				}
				case TreeCompressionStrategy.Compressed: {
					if (context.schema === undefined) {
						encoded = uncompressedEncodeFn(data);
					} else {
						encoded = schemaCompressedEncodeFn(
							context.schema.schema,
							context.schema.policy,
							data,
							context.idCompressor,
							incrementalEncoder,
							context.isSummary,
						);
					}
					break;
				}
				default: {
					unreachableCase(context.encodeType);
				}
			}
			return encoded;
		},
		decode: (
			data: EncodedFieldBatchAnyVersion,
			context: FieldBatchDecodingContext,
		): FieldBatch => {
			return decode(data, context.idDecodingContext, context.incrementalDecoder).map((chunk) =>
				chunk.cursor(),
			);
		},
		schema: encodedFieldBatchType,
	};
}
export const fieldBatchCodecBuilder = VersionDispatchingCodecBuilder.build("FieldBatch", [
	{
		minVersionForCollab: lowestMinVersionForCollab,
		formatVersion: FieldBatchFormatVersion.v1,
		codec: makeFieldBatchCodecForVersion(
			FieldBatchFormatVersion.v1,
			uncompressedEncodeV1,
			schemaCompressedEncodeV1,
			EncodedFieldBatchV1,
		),
	},
	{
		minVersionForCollab: FluidClientVersion.v2_73,
		formatVersion: FieldBatchFormatVersion.v2,
		codec: makeFieldBatchCodecForVersion(
			FieldBatchFormatVersion.v2,
			uncompressedEncodeV2,
			schemaCompressedEncodeV2,
			EncodedFieldBatchV2,
		),
	},
	{
		minVersionForCollab: undefined,
		formatVersion: FieldBatchFormatVersion.vTextExperimental,
		codec: makeFieldBatchCodecForVersion(
			FieldBatchFormatVersion.vTextExperimental,
			uncompressedEncodeVTextExperimental,
			schemaCompressedEncodeVTextExperimental,
			EncodedFieldBatchVTextExperimental,
		),
	},
]);
```

### Decision procedure: `feature-libraries/chunked-forest/codec/format/formatGeneric.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/format/formatGeneric.ts:1-68`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const IdentifierOrIndex = Type.Union([Type.String(), Type.Integer({ minimum: 0 })]);
export type IdentifierOrIndex = Static<typeof IdentifierOrIndex>;
export const ShapeIndex = Type.Integer({ minimum: 0 });
export type ShapeIndex = Static<typeof ShapeIndex>;
export const Count = Type.Integer({ minimum: 0 });
const EncodedFieldBatchBase = Type.Object(
	{
		identifiers: Type.Array(Type.String()),
		data: Type.Array(Type.Array(Type.Any())),
	},
	{ additionalProperties: false },
);
export const EncodedFieldBatchGeneric = <TShapeSchema extends TSchema>(
	version: FieldBatchFormatVersion,
	shape: TShapeSchema,
) =>
	Type.Composite(
		[
			EncodedFieldBatchBase,
			Type.Object({
				version: Type.Literal(version),
				shapes: Type.Array(shape),
			}),
		],
		{ additionalProperties: false },
	);
export interface EncodedFieldBatchGeneric<TEncodedShape>
	extends Static<typeof EncodedFieldBatchBase> {
	shapes: TEncodedShape[];
	version: FieldBatchFormatVersion;
}
```

### Decision procedure: `feature-libraries/chunked-forest/codec/format/formatV1.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/format/formatV1.ts:1-173`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type EncodedNestedArrayShape = Static<typeof EncodedNestedArrayShape>;
export const EncodedNestedArrayShape = ShapeIndex;
export type EncodedInlineArrayShape = Static<typeof EncodedInlineArrayShape>;
export const EncodedInlineArrayShape = Type.Object(
	{
		length: Count,
		shape: ShapeIndex,
	},
	{ additionalProperties: false },
);
export type EncodedAnyShape = Static<typeof EncodedAnyShape>;
export const EncodedAnyShape = Type.Literal(0);
export type EncodedFieldShape = Static<typeof EncodedFieldShape>;
export const EncodedFieldShape = Type.Tuple([
	IdentifierOrIndex,
	ShapeIndex,
]);
export enum SpecialField {
	Identifier = 0,
}
export const EncodedValueShape = Type.Union([
	Type.Boolean(),
	Type.Array(Type.Any(), { minItems: 1, maxItems: 1 }),
	Type.Enum(SpecialField),
]);
export type EncodedValueShape = undefined | Static<typeof EncodedValueShape>;
export type EncodedNodeShape = Static<typeof EncodedNodeShape>;
export const EncodedNodeShape = Type.Object(
	{
		type: Type.Optional(IdentifierOrIndex),
		value: Type.Optional(EncodedValueShape),
		fields: Type.Optional(Type.Array(EncodedFieldShape)),
		extraFields: Type.Optional(ShapeIndex),
	},
	{ additionalProperties: false },
);
export const shapesV1 = {
	a: Type.Optional(EncodedNestedArrayShape),
	b: Type.Optional(EncodedInlineArrayShape),
	c: Type.Optional(EncodedNodeShape),
	d: Type.Optional(EncodedAnyShape),
} as const;
export type EncodedChunkShapeV1 = Static<typeof EncodedChunkShapeV1>;
export const EncodedChunkShapeV1 = Type.Object(
	{ ...shapesV1, e: Type.Optional(Type.Never()) },
	unionOptions,
);
```

### Decision procedure: `feature-libraries/chunked-forest/codec/format/formatV2.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/format/formatV2.ts:1-42`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type EncodedIncrementalChunkShape = Static<typeof EncodedIncrementalChunkShape>;
export const EncodedIncrementalChunkShape = Type.Literal(0);
export const shapesV2 = {
	...shapesV1,
	e: Type.Optional(EncodedIncrementalChunkShape),
} as const;
export type EncodedChunkShapeV2 = Static<typeof EncodedChunkShapeV2>;
export const EncodedChunkShapeV2 = Type.Object(
	{ ...shapesV2, f: Type.Optional(Type.Never()) },
	unionOptions,
);
```

### Decision procedure: `feature-libraries/chunked-forest/codec/format/formatVText.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/format/formatVText.ts:1-84`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type EncodedSpecializedNodeShape = Static<typeof EncodedSpecializedNodeShape>;
export const EncodedSpecializedNodeShape = Type.Object(
	{
		base: ShapeIndex,
		fields: Type.Optional(Type.Array(EncodedFieldShape)),
		value: Type.Optional(Type.Union([EncodedValueShape, Type.Null()])),
		extraFields: Type.Optional(Type.Union([ShapeIndex, Type.Null()])),
	},
	{ additionalProperties: false },
);
export type EncodedChunkShapeVTextExperimental = Static<
	typeof EncodedChunkShapeVTextExperimental
>;
export const EncodedChunkShapeVTextExperimental = Type.Object(
	{
		...shapesV2,
		f: Type.Optional(EncodedSpecializedNodeShape),
	},
	unionOptions,
);
```

### Concrete encoder outputs and dictionary tie-breaking

Uncompressed encoding of a batch with zero fields emits `{"version":1,"identifiers":[],"shapes":[{"c":{"extraFields":1}},{"a":0}],"data":[]}`. One empty field emits the same header with `"data":[[1,[]]]`. One field containing a leaf of type N with numeric value 5 emits `{"version":1,"identifiers":[],"shapes":[{"c":{"extraFields":1}},{"a":0}],"data":[[1,["N",true,5,[]]]]}`. For v2 and text the uncompressed algorithm produces exactly these bodies with version `2` or `"text"`. No-schema compressed mode takes this same path. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/uncompressedEncode.ts:57-107`

For compressed dictionaries: count usages in discovery order; stable-sort descending by count (equal counts retain first-discovery order); shapes always enter the table, while identifier membership uses the prospective *filtered output index*. Include identifier s iff `String(index).length*count + JSON.stringify(s).length + 1 < JSON.stringify(s).length*count`. Equality excludes it. Lengths are UTF-16, not UTF-8 bytes or Swift grapheme counts. Consequently a different stable-sort or escaping implementation changes every later dictionary index. Shapes deduplicate by object identity, not deep equality. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkCodecUtilities.ts:20-104` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkEncodingGeneric.ts:53-137`

Shape e is a reference whose contents live in a summary child subtree, not a compressed ID or inline tree. Text f may inherit c or f, but not array/any/reference shapes. Disabling the text writer override does not remove previously acknowledged text chunks reused by incremental summary handles. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/codecs.ts:340-353` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkDecoding.ts:93-190`

## 4. Behavior

### Forest storage/editing

Root is a synthetic BasicChunk above detached fields. BasicChunk holds type/value/field chunks; UniformChunk factors out a common tree shape and packs values; SequenceChunk combines ranges. Empty and singleton sequences normalize away; no nested SequenceChunk. Clone shares chunks with reference increments, but creates separate anchors; edit traverses mutable path and copies shared/immutable chunks before changing. Acquire only one DeltaVisitor. Each create/destroy/attach/detach emits beforeChange immediately before mutation; create also emits afterRootFieldCreated. Attach consumes entire source detached field; detach creates a new destination root. Anchor visitor and announced visitors observe the same traversal, not a later asynchronous replay. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/chunkedForest.ts:205` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/chunkedForest.ts:235` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/basicChunk.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/uniformChunk.ts:6`

### Codec control flow

Every input cursor must be in field mode. Uncompressed strategy directly uses generic encoding. CompressedIncremental requires v2/text then falls through to compressed encoding; without schema, compressed strategies use uncompressed encoding. With schema select fixed node shape for single allowed node type, specialize field encoder using multiplicity, and use polymorphic generic encoder where required. Dictionaries are discovered and emitted with the actual counters/dedup policy, then buffered IdentifierToken/shape references are replaced with indexes or inline identifiers. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/codecs.ts:250` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/schemaBasedEncode.ts:150` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkEncodingGeneric.ts:53`

Decode builds lazy shape decoders, applies any decoder to each field stream, validates stream exhaustion, aggregates chunks, returns chunk cursors. Nested zero-data arrays use numeric count so repeated constant-shaped nodes do not disappear. ID compression has distinct op vs summary originator handling. Incremental decoding must use originatorless summary context; do not fabricate a local originator for cached summary blobs. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkDecodingGeneric.ts:20` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkDecoding.ts:341` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/codecs.ts:196`

The extracts below preserve exact token order, shapes, identifier dictionary allocation, and specialization. They are TypeScript decision procedures: port collection and number semantics faithfully, not the syntax.

### Algorithm notation and completeness

The following decision procedures are part of this specification, not external reading assignments. They preserve exact predicates, allocation order, collection traversal, return shapes and synchronous event calls. `undefined` means absent; `null` is a value; object spread is right-biased; `delete` removes a property; `Map`/`Set` iterate in insertion order. TypeBox `Optional(T)` permits absence, not null; tuples are fixed-order JSON arrays; singleton discriminated unions have exactly one case property. Assertions stop execution at the displayed short code. Helpers in another area use that area's same-named procedure; generic collection utilities retain JavaScript order. These are reference algorithms to translate into Swift, not a proposal to embed TypeScript in the client.

### Decision procedure: `feature-libraries/chunked-forest/basicChunk.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/basicChunk.ts:1-646`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class BasicChunk extends ReferenceCountedBase implements TreeChunk {
	public readonly topLevelLength: number = 1;
	public constructor(
		public type: TreeNodeSchemaIdentifier,
		public fields: Map<FieldKey, TreeChunk[]>,
		public value?: TreeValue,
	) {
		super();
	}
	public clone(): BasicChunk {
		const fields = new Map<FieldKey, TreeChunk[]>();
		for (const [k, v] of this.fields) {
			const field = v.map((child) => {
				child.referenceAdded();
				return child;
			});
			fields.set(k, field);
		}
		return new BasicChunk(this.type, fields, this.value);
	}
	public cursor(): ChunkedCursor {
		return new BasicChunkCursor([this], [], [], [], [], [dummyRoot], 0, 0, 0, undefined);
	}
	protected onUnreferenced(): void {
		for (const v of this.fields.values()) {
			for (const child of v) {
				child.referenceRemoved();
			}
		}
	}
}
export type SiblingsOrKey = readonly TreeChunk[] | readonly FieldKey[];
export class BasicChunkCursor extends SynchronousCursor implements ChunkedCursor {
	public constructor(
		protected root: readonly TreeChunk[],
		protected readonly siblingStack: SiblingsOrKey[],
		protected readonly indexStack: number[],
		protected readonly indexOfChunkStack: number[],
		protected readonly indexWithinChunkStack: number[],
		protected siblings: SiblingsOrKey,
		protected index: number,
		protected indexOfChunk: number,
		protected indexWithinChunk: number,
		protected nestedCursor: ChunkedCursor | undefined,
	) {
		super();
	}
	public get [cursorChunk](): TreeChunk | undefined {
		if (this.nestedCursor !== undefined) {
			return this.nestedCursor[cursorChunk];
		}
		assert(this.mode === CursorLocationType.Nodes, 0x57a  );
		return (this.siblings as TreeChunk[])[this.indexOfChunk];
	}
	public atChunkRoot(): boolean {
		return (
			this.siblingStack.length < 2 &&
			(this.nestedCursor === undefined || this.nestedCursor.atChunkRoot())
		);
	}
	public fork(): BasicChunkCursor {
		return new BasicChunkCursor(
			this.root,
			[...this.siblingStack],
			[...this.indexStack],
			[...this.indexOfChunkStack],
			[...this.indexWithinChunkStack],
			this.siblings,
			this.index,
			this.indexOfChunk,
			this.indexWithinChunk,
			this.nestedCursor?.fork(),
		);
	}
	public get mode(): CursorLocationType {
		if (this.nestedCursor !== undefined) {
			return this.nestedCursor.mode;
		}
		this.assertChunkStacksMatchNodeDepth();
		return this.siblingStack.length % 2 === 0
			? CursorLocationType.Fields
			: CursorLocationType.Nodes;
	}
	private assertChunkStacksMatchNodeDepth(): void {
		const halfHeight = this.getNodeOnlyHeightFromHeight();
		assert(
			this.indexOfChunkStack.length === halfHeight,
			0x51c  ,
		);
		assert(
			this.indexWithinChunkStack.length === halfHeight,
			0x51d  ,
		);
	}
	public getFieldKey(): FieldKey {
		if (this.nestedCursor !== undefined) {
			return this.nestedCursor.getFieldKey();
		}
		assert(this.mode === CursorLocationType.Fields, 0x51e  );
		return this.siblings[this.index] as FieldKey;
	}
	private getStackedFieldKey(height: number): FieldKey {
		assert(height % 2 === 0, 0x51f  );
		return this.siblingStack[height]![this.indexStack[height]!] as FieldKey;
	}
	private getStackedNodeIndex(height: number): number {
		assert(height % 2 === 1, 0x520  );
		assert(height >= 0, 0x521  );
		return this.indexStack[height] ?? oob();
	}
	private getStackedChunkIndex(height: number): number {
		assert(height % 2 === 1, 0xcf3  );
		assert(height >= 0, 0xcf4  );
		return this.indexOfChunkStack[this.getNodeOnlyHeightFromHeight(height)] ?? oob();
	}
	private getStackedChunk(height: number): BasicChunk {
		const index = this.getStackedChunkIndex(height);
		const chunk = (this.siblingStack[height] as readonly TreeChunk[])[index];
		debugAssert(() => chunk instanceof BasicChunk || "only basic chunks are expected");
		return chunk as BasicChunk;
	}
	private getNodeOnlyHeightFromHeight(height: number = this.siblingStack.length): number {
		return height >> 1;
	}
	public getFieldLength(): number {
		if (this.nestedCursor !== undefined) {
			return this.nestedCursor.getFieldLength();
		}
		assert(this.mode === CursorLocationType.Fields, 0x522  );
		let total = 0;
		for (const chunk of this.getField()) {
			total += chunk.topLevelLength;
		}
		return total;
	}
	public enterNode(index: number): void {
		if (this.nestedCursor !== undefined) {
			this.nestedCursor.enterNode(index);
			return;
		}
		const found = this.firstNode() && this.seekNodes(index);
		assert(found, 0x523  );
	}
	public getPath(prefix?: PathRootPrefix): UpPath {
		if (this.nestedCursor !== undefined) {
			return (
				this.nestedCursor.getPath(this.nestedPathPrefix(prefix)) ??
				fail(0xaee  )
			);
		}
		assert(this.mode === CursorLocationType.Nodes, 0x524  );
		const path = this.getOffsetPath(0, prefix);
		assert(path !== undefined, 0x55c  );
		return path;
	}
	private nestedPathPrefix(prefix?: PathRootPrefix): PathRootPrefix {
		const rootPath: UpPath =
			this.getOffsetPath(0, prefix) ?? fail(0xaef  );
		return {
			indexOffset: rootPath.parentIndex - this.indexWithinChunk,
			rootFieldOverride: rootPath.parentField,
			parent: rootPath.parent,
		};
	}
	public getFieldPath(prefix?: PathRootPrefix): FieldUpPath {
		if (this.nestedCursor !== undefined) {
			return this.nestedCursor.getFieldPath(this.nestedPathPrefix(prefix));
		}
		assert(this.mode === CursorLocationType.Fields, 0x525  );
		return {
			field:
				this.indexStack.length === 1
					? (prefix?.rootFieldOverride ?? this.getFieldKey())
					: this.getFieldKey(),
			parent: this.getOffsetPath(1, prefix),
		};
	}
	private getOffsetPath(
		offset: number,
		prefix: PathRootPrefix | undefined,
	): UpPath | undefined {
		const length = this.indexStack.length - offset;
		if (length === -1) {
			return prefix?.parent;
		}
		assert(length > 0, 0x526  );
		assert(length % 2 === 1, 0x527  );
		let path: UpPath | undefined;
		function updatePath(newPath: UpPath): void {
			path = path === undefined ? prefixPath(prefix, newPath) : newPath;
		}
		for (let height = 1; height < length; height += 2) {
			const key = this.getStackedFieldKey(height - 1);
			updatePath({
				parent: path,
				parentIndex: this.getStackedNodeIndex(height),
				parentField: key,
			});
		}
		updatePath({
			parent: path,
			parentIndex: offset === 0 ? this.index : this.getStackedNodeIndex(length),
			parentField: this.getStackedFieldKey(length - 1),
		});
		return path;
	}
	public enterField(key: FieldKey): void {
		if (this.nestedCursor !== undefined) {
			this.nestedCursor.enterField(key);
			return;
		}
		assert(this.mode === CursorLocationType.Nodes, 0x528  );
		this.siblingStack.push(this.siblings);
		this.indexStack.push(this.index);
		this.indexOfChunkStack.push(this.indexOfChunk);
		this.indexWithinChunkStack.push(this.indexWithinChunk);
		this.index = 0;
		this.siblings = [key];
		this.assertChunkStacksMatchNodeDepth();
	}
	public nextField(): boolean {
		if (this.nestedCursor !== undefined) {
			return this.nestedCursor.nextField();
		}
		this.index += 1;
		if (this.index === (this.siblings as []).length) {
			this.exitField();
			return false;
		}
		return true;
	}
	public firstField(): boolean {
		if (this.nestedCursor !== undefined) {
			return this.nestedCursor.firstField();
		}
		const fields = this.getNode().fields;
		if (fields.size === 0) {
			return false;
		}
		this.siblingStack.push(this.siblings);
		this.indexStack.push(this.index);
		this.indexOfChunkStack.push(this.indexOfChunk);
		this.indexWithinChunkStack.push(this.indexWithinChunk);
		this.index = 0;
		this.siblings = [...fields.keys()];
		this.assertChunkStacksMatchNodeDepth();
		return true;
	}
	public seekNodes(offset: number): boolean {
		if (this.nestedCursor !== undefined) {
			const atRoot = this.nestedCursor.atChunkRoot();
			const stillIn = this.nestedCursor.seekNodes(offset);
			if (!atRoot) {
				return stillIn;
			}
			if (!stillIn) {
				this.nestedCursor = undefined;
			}
		}
		assert(
			this.mode === CursorLocationType.Nodes,
			0x529  ,
		);
		assert(this.indexOfChunk < this.siblings.length, 0x52a  );
		this.indexWithinChunk += offset;
		if (offset >= 0) {
			const chunks = (this.siblings as TreeChunk[]) ?? oob();
			while (this.indexWithinChunk >= chunks[this.indexOfChunk]!.topLevelLength) {
				this.indexWithinChunk -= chunks[this.indexOfChunk]!.topLevelLength;
				this.indexOfChunk++;
				if (this.indexOfChunk === chunks.length) {
					this.exitNode();
					return false;
				}
				assert(
					this.indexOfChunk < this.siblings.length,
					0x52b  ,
				);
			}
		} else {
			const chunks = this.siblings as TreeChunk[];
			while (this.indexWithinChunk < 0) {
				if (this.indexOfChunk === 0) {
					this.exitNode();
					return false;
				}
				this.indexOfChunk--;
				this.indexWithinChunk += chunks[this.indexOfChunk]!.topLevelLength;
			}
		}
		this.index += offset;
		this.initNestedCursor();
		return true;
	}
	public firstNode(): boolean {
		if (this.nestedCursor !== undefined) {
			return this.nestedCursor.firstNode();
		}
		const siblings = this.getField();
		if (siblings.length === 0) {
			return false;
		}
		this.siblingStack.push(this.siblings);
		this.indexStack.push(this.index);
		this.index = 0;
		this.siblings = siblings;
		this.indexOfChunk = 0;
		this.indexWithinChunk = 0;
		this.assertChunkStacksMatchNodeDepth();
		this.initNestedCursor();
		return true;
	}
	public nextNode(): boolean {
		if (this.nestedCursor !== undefined) {
			const atRoot = this.nestedCursor.atChunkRoot();
			const stillIn = this.nestedCursor.nextNode();
			if (!atRoot) {
				return stillIn;
			}
			if (!stillIn) {
				this.nestedCursor = undefined;
			}
		}
		assert(
			this.mode === CursorLocationType.Nodes,
			0x52c  ,
		);
		this.indexWithinChunk++;
		if (
			this.indexWithinChunk ===
			(this.siblings as TreeChunk[])[this.indexOfChunk]!.topLevelLength
		) {
			this.indexOfChunk++;
			if (this.indexOfChunk === (this.siblings as TreeChunk[]).length) {
				this.exitNode();
				return false;
			}
			this.indexWithinChunk = 0;
			this.initNestedCursor();
		}
		this.index++;
		return true;
	}
	private initNestedCursor(): void {
		assert(
			this.mode === CursorLocationType.Nodes,
			0x55d  ,
		);
		const chunk = (this.siblings as TreeChunk[])[this.indexOfChunk] ?? oob();
		this.nestedCursor = chunk instanceof BasicChunk ? undefined : chunk.cursor();
		this.nestedCursor?.enterNode(this.indexWithinChunk);
	}
	public exitField(): void {
		if (this.nestedCursor !== undefined) {
			return this.nestedCursor.exitField();
		}
		assert(
			this.mode === CursorLocationType.Fields,
			0x52d  ,
		);
		this.siblings =
			this.siblingStack.pop() ?? fail(0xaf0  );
		this.index = this.indexStack.pop() ?? fail(0xaf1  );
		this.indexOfChunk =
			this.indexOfChunkStack.pop() ?? fail(0xcf5  );
		this.indexWithinChunk =
			this.indexWithinChunkStack.pop() ??
			fail(0xcf6  );
		this.assertChunkStacksMatchNodeDepth();
	}
	public exitNode(): void {
		if (this.nestedCursor !== undefined) {
			if (!this.nestedCursor.atChunkRoot()) {
				return this.nestedCursor.exitNode();
			}
			this.nestedCursor = undefined;
		}
		assert(
			this.mode === CursorLocationType.Nodes,
			0x52e  ,
		);
		this.siblings =
			this.siblingStack.pop() ?? fail(0xaf2  );
		this.index = this.indexStack.pop() ?? fail(0xaf3  );
		this.indexOfChunk = 0;
		this.indexWithinChunk = 0;
		this.assertChunkStacksMatchNodeDepth();
	}
	private getNode(): BasicChunk {
		assert(this.mode === CursorLocationType.Nodes, 0x52f  );
		const chunk = (this.siblings as TreeChunk[])[this.indexOfChunk];
		debugAssert(() => chunk instanceof BasicChunk || "only basic chunks are expected");
		return chunk as BasicChunk;
	}
	private getField(): readonly TreeChunk[] {
		if (this.siblingStack.length === 0) {
			return this.root;
		}
		assert(
			this.mode === CursorLocationType.Fields,
			0x530  ,
		);
		const parent = this.getStackedChunk(this.siblingStack.length - 1);
		const key: FieldKey = this.getFieldKey();
		const field = parent.fields.get(key) ?? [];
		return field;
	}
	public get value(): Value {
		if (this.nestedCursor !== undefined) {
			return this.nestedCursor.value;
		}
		return this.getNode().value;
	}
	public get type(): TreeType {
		if (this.nestedCursor !== undefined) {
			return this.nestedCursor.type;
		}
		return this.getNode().type;
	}
	public get fieldIndex(): number {
		assert(
			this.mode === CursorLocationType.Nodes,
			0x531  ,
		);
		if (this.nestedCursor !== undefined) {
			if (this.nestedCursor.atChunkRoot()) {
				return this.nestedCursor.fieldIndex + this.nestedOffset();
			}
			return this.nestedCursor.fieldIndex;
		}
		return this.index;
	}
	private nestedOffset(): number {
		assert(this.nestedCursor !== undefined, 0x55e  );
		assert(
			!this.nestedCursor.atChunkRoot() ||
				this.indexWithinChunk === this.nestedCursor.fieldIndex,
			0x55f  ,
		);
		return this.index - this.indexWithinChunk;
	}
	public get chunkStart(): number {
		if (this.nestedCursor !== undefined) {
			if (this.nestedCursor.atChunkRoot()) {
				return this.nestedCursor.chunkStart + this.nestedOffset();
			}
			return this.nestedCursor.chunkStart;
		}
		return this.fieldIndex;
	}
	public get chunkLength(): number {
		if (this.nestedCursor !== undefined) {
			return this.nestedCursor.chunkLength;
		}
		return 1;
	}
}
```

### Decision procedure: `feature-libraries/chunked-forest/chunkTree.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/chunkTree.ts:1-932`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface Disposable {
	dispose(): void;
}
export function makeTreeChunker(
	schema: TreeStoredSchemaSubscription,
	policy: SchemaPolicy,
	shouldEncodeIncrementally: IncrementalEncodingPolicy,
): IChunker {
	return new Chunker(
		schema,
		policy,
		defaultChunkPolicy.sequenceChunkInlineThreshold,
		defaultChunkPolicy.sequenceChunkInlineThreshold,
		defaultChunkPolicy.uniformChunkNodeCount,
		defaultChunkPolicy.uniformChunkNodeCountDynamicTargetMax,
		(
			type: TreeNodeSchemaIdentifier,
			shapes: Map<TreeNodeSchemaIdentifier, ShapeInfo>,
			chunkerSchema: TreeStoredSchema,
		) =>
			tryShapeFromNodeSchema(
				{
					schema: chunkerSchema,
					policy,
					shouldEncodeIncrementally,
					shapes,
				},
				type,
			),
	);
}
export interface IChunker extends ChunkPolicy, Disposable {
	readonly schema: TreeStoredSchemaSubscription;
	clone(schema: TreeStoredSchemaSubscription): IChunker;
}
export class Polymorphic {}
export const polymorphic = new Polymorphic();
export type ShapeInfo = TreeShape | Polymorphic;
export class Chunker implements IChunker {
	private readonly typeShapes: Map<TreeNodeSchemaIdentifier, ShapeInfo> = new Map();
	private unregisterSchemaCallback: (() => void) | undefined;
	public constructor(
		public readonly schema: TreeStoredSchemaSubscription,
		public readonly policy: SchemaPolicy,
		public readonly sequenceChunkSplitThreshold: number,
		public readonly sequenceChunkInlineThreshold: number,
		public readonly uniformChunkNodeCount: number,
		public readonly uniformChunkNodeCountDynamicTargetMax: number,
		private readonly tryShapeWithSchema: (
			type: TreeNodeSchemaIdentifier,
			shapes: Map<TreeNodeSchemaIdentifier, ShapeInfo>,
			chunkerSchema: TreeStoredSchema,
		) => ShapeInfo,
	) {}
	public clone(schema: TreeStoredSchemaSubscription): IChunker {
		return new Chunker(
			schema,
			this.policy,
			this.sequenceChunkSplitThreshold,
			this.sequenceChunkInlineThreshold,
			this.uniformChunkNodeCount,
			this.uniformChunkNodeCountDynamicTargetMax,
			this.tryShapeWithSchema,
		);
	}
	public shapeFromSchema(schema: TreeNodeSchemaIdentifier): ShapeInfo {
		const cached = this.typeShapes.get(schema);
		if (cached !== undefined) {
			debugAssert(
				() =>
					this.unregisterSchemaCallback !== undefined ||
					"Must not hit cache when invalidation is not set up",
			);
			return cached;
		}
		this.unregisterSchemaCallback ??= this.schema.events.on("afterSchemaChange", () =>
			this.schemaChanged(),
		);
		const result = this.tryShapeWithSchema(schema, this.typeShapes, this.schema);
		debugAssert(
			() =>
				!this.typeShapes.has(schema) ||
				this.typeShapes.get(schema) === result ||
				"Returned shape does not match cached shape",
		);
		this.typeShapes.set(schema, result);
		return result;
	}
	public dispose(): void {
		this.schemaChanged();
	}
	private schemaChanged(): void {
		this.typeShapes.clear();
		if (this.unregisterSchemaCallback) {
			this.unregisterSchemaCallback();
			this.unregisterSchemaCallback = undefined;
		}
	}
}
export function chunkTree(cursor: ITreeCursorSynchronous, policy: ChunkCompressor): TreeChunk {
	return chunkRange(cursor, policy, 1, true)[0] ?? oob();
}
export function chunkField(
	cursor: ITreeCursorSynchronous,
	policy: ChunkCompressor,
): TreeChunk[] {
	const length = cursor.getFieldLength();
	const started = cursor.firstNode();
	debugAssert(
		() => started === (length !== 0) || "only 0 length fields should not have nodes",
	);
	return chunkRange(cursor, policy, length, false);
}
export function chunkFieldSingle(
	cursor: ITreeCursorSynchronous,
	policy: ChunkCompressor,
): TreeChunk {
	const chunks = chunkField(cursor, policy);
	return combineChunks(chunks);
}
export function combineChunks(chunks: TreeChunk[]): TreeChunk {
	if (chunks.length === 1) {
		return chunks[0] ?? oob();
	}
	return new SequenceChunk(chunks);
}
export function basicChunkTree(
	cursor: ITreeCursorSynchronous,
	policy: ChunkCompressor,
): BasicChunk {
	const chunk = tryGetChunk(cursor);
	if (chunk instanceof BasicChunk) {
		chunk.referenceAdded();
		return chunk;
	}
	return newBasicChunkTree(cursor, policy);
}
export function makePolicy(policy?: Partial<ChunkPolicy>): ChunkPolicy {
	const withDefaults = { ...defaultChunkPolicy, ...policy };
	assert(
		withDefaults.sequenceChunkSplitThreshold >= 2,
		0x57d  ,
	);
	return withDefaults;
}
export interface ShapeFromSchemaParameters extends SchemaAndPolicy {
	readonly shouldEncodeIncrementally: IncrementalEncodingPolicy;
	readonly shapes: Map<TreeNodeSchemaIdentifier, ShapeInfo>;
}
export interface FieldSchemaWithContext {
	readonly fieldSchema: TreeFieldStoredSchema;
	readonly parentNodeSchema?: TreeNodeSchemaIdentifier;
	readonly key: FieldKey;
}
export function tryShapeFromNodeSchema(
	context: ShapeFromSchemaParameters,
	nodeSchema: TreeNodeSchemaIdentifier,
): ShapeInfo {
	const { schema, shapes } = context;
	return getOrCreate(shapes, nodeSchema, () => {
		const treeSchema = schema.nodeSchema.get(nodeSchema) ?? fail(0xaf9  );
		if (treeSchema instanceof LeafNodeStoredSchema) {
			return treeSchema.leafValue === ValueSchema.String
				? new TreeShape(nodeSchema, true, [], true)
				: new TreeShape(nodeSchema, true, [], false);
		}
		if (treeSchema instanceof ObjectNodeStoredSchema) {
			const fieldsArray: FieldShape[] = [];
			for (const [key, fieldSchema] of treeSchema.objectNodeFields) {
				const fieldShape = tryShapeFromFieldSchema(context, {
					fieldSchema,
					parentNodeSchema: nodeSchema,
					key,
				});
				if (fieldShape === undefined) {
					return polymorphic;
				}
				fieldsArray.push(fieldShape);
			}
			return new TreeShape(nodeSchema, false, fieldsArray);
		}
		return polymorphic;
	});
}
export function tryShapeFromFieldSchema(
	context: ShapeFromSchemaParameters,
	fieldSchemaWithContext: FieldSchemaWithContext,
): FieldShape | undefined {
	const { schema, policy, shouldEncodeIncrementally, shapes } = context;
	const { fieldSchema, parentNodeSchema, key } = fieldSchemaWithContext;
	if (shouldEncodeIncrementally(parentNodeSchema, key)) {
		return undefined;
	}
	const kind = policy.fieldKinds.get(fieldSchema.kind) ?? fail(0xafa  );
	if (kind.multiplicity !== Multiplicity.Single) {
		return undefined;
	}
	if (fieldSchema.types?.size !== 1) {
		return undefined;
	}
	const childType = [...fieldSchema.types][0] ?? oob();
	const childShape = tryShapeFromNodeSchema(
		{
			schema,
			policy,
			shouldEncodeIncrementally,
			shapes,
		},
		childType,
	);
	if (childShape instanceof Polymorphic) {
		return undefined;
	}
	return [key, childShape, 1];
}
export const defaultChunkPolicy: ChunkPolicy = {
	sequenceChunkSplitThreshold: Number.POSITIVE_INFINITY,
	sequenceChunkInlineThreshold: Number.POSITIVE_INFINITY,
	uniformChunkNodeCount: 400,
	uniformChunkNodeCountDynamicTargetMax: 25,
	shapeFromSchema: () => polymorphic,
};
export const basicOnlyChunkPolicy: ChunkPolicy = {
	sequenceChunkSplitThreshold: Number.POSITIVE_INFINITY,
	sequenceChunkInlineThreshold: Number.POSITIVE_INFINITY,
	uniformChunkNodeCount: 0,
	uniformChunkNodeCountDynamicTargetMax: 0,
	shapeFromSchema: () => polymorphic,
};
export interface ChunkPolicy {
	readonly sequenceChunkSplitThreshold: number;
	readonly sequenceChunkInlineThreshold: number;
	readonly uniformChunkNodeCount: number;
	readonly uniformChunkNodeCountDynamicTargetMax: number;
	shapeFromSchema(schema: TreeNodeSchemaIdentifier): ShapeInfo;
}
export interface ChunkCompressor {
	readonly policy: ChunkPolicy;
	readonly idCompressor: IIdCompressor | undefined;
}
function newBasicChunkTree(
	cursor: ITreeCursorSynchronous,
	policy: ChunkCompressor,
): BasicChunk {
	return new BasicChunk(
		cursor.type,
		new Map(mapCursorFields(cursor, () => [cursor.getFieldKey(), chunkField(cursor, policy)])),
		cursor.value,
	);
}
export function chunkRange(
	cursor: ITreeCursorSynchronous,
	chunkCompressor: ChunkCompressor,
	length: number,
	skipLastNavigation: boolean,
): TreeChunk[] {
	assert(
		!(skipLastNavigation && length === 0),
		0xb58  ,
	);
	assert(
		(cursor.mode === CursorLocationType.Nodes) === length > 0,
		0xb59  ,
	);
	let output: TreeChunk[] = [];
	let remaining = length;
	while (remaining > 0) {
		assert(cursor.mode === CursorLocationType.Nodes, 0x57f  );
		const start = cursor.chunkStart;
		let reusedChunk = false;
		if (start === cursor.fieldIndex) {
			const chunkLength = cursor.chunkLength;
			if (chunkLength <= remaining) {
				const chunk = tryGetChunk(cursor);
				if (chunk !== undefined) {
					if (
						chunk instanceof SequenceChunk &&
						chunk.subChunks.length <= chunkCompressor.policy.sequenceChunkInlineThreshold
					) {
						for (const subChunk of chunk.subChunks) {
							subChunk.referenceAdded();
							output.push(subChunk);
						}
					}
					chunk.referenceAdded();
					output.push(chunk);
					remaining -= chunkLength;
					reusedChunk = true;
					let seek = chunkLength;
					if (skipLastNavigation && remaining === 0) {
						seek -= 1;
					}
					cursor.seekNodes(seek);
				}
			}
		}
		if (!reusedChunk) {
			assert(cursor.mode === CursorLocationType.Nodes, 0x580  );
			const type = cursor.type;
			const shape = chunkCompressor.policy.shapeFromSchema(type);
			if (shape instanceof TreeShape) {
				const nodesPerTopLevelNode = shape.positions.length;
				const maxTopLevelLength = Math.max(
					1,
					Math.floor(chunkCompressor.policy.uniformChunkNodeCount / nodesPerTopLevelNode),
				);
				const maxLength = Math.min(maxTopLevelLength, remaining);
				const newChunk = uniformChunkFromCursor(
					cursor,
					shape,
					maxLength,
					maxLength === remaining && skipLastNavigation,
					chunkCompressor.idCompressor,
				);
				remaining -= newChunk.topLevelLength;
				output.push(newChunk);
			} else {
				output.push(newBasicChunkTree(cursor, chunkCompressor));
				remaining -= 1;
				if (!skipLastNavigation || remaining !== 0) {
					cursor.nextNode();
				}
			}
		}
	}
	while (output.length > chunkCompressor.policy.sequenceChunkSplitThreshold) {
		const chunkCount = Math.ceil(
			output.length / chunkCompressor.policy.sequenceChunkSplitThreshold,
		);
		const newOutput: TreeChunk[] = [];
		const chunkSize = Math.floor(output.length / chunkCount);
		const extra = output.length % chunkCount;
		let previousEnd = 0;
		for (let index = 0; index < chunkCount; index++) {
			const end = previousEnd + chunkSize + (index < extra ? 1 : 0);
			newOutput.push(new SequenceChunk(output.slice(previousEnd, end)));
			previousEnd = end;
		}
		assert(previousEnd === output.length, 0x581  );
		output = newOutput;
	}
	return output;
}
export function splitFieldAtIndex(
	chunks: TreeChunk[],
	nodeIndex: number,
	policy: ChunkCompressor,
): number {
	assertNonNegativeSafeInteger(nodeIndex);
	const bisectThreshold = policy.policy.uniformChunkNodeCountDynamicTargetMax;
	let remaining = nodeIndex;
	let chunkIndex = 0;
	while (chunkIndex < chunks.length) {
		if (remaining === 0) {
			return chunkIndex;
		}
		const chunk = chunks[chunkIndex] ?? oob();
		const total = chunk.topLevelLength;
		if (remaining >= total) {
			remaining -= total;
			chunkIndex++;
			continue;
		}
		const splitPoint = total > bisectThreshold ? Math.floor(total / 2) : remaining;
		const cursor = chunk.cursor();
		cursor.firstNode();
		const before = chunkRange(cursor, policy, splitPoint, false);
		const after = chunkRange(cursor, policy, total - splitPoint, true);
		chunks.splice(chunkIndex, 1, ...before, ...after);
		chunk.referenceRemoved();
	}
	assert(remaining === 0, 0xcf9  );
	return chunks.length;
}
export function coalesceUniformChunks(
	chunks: TreeChunk[],
	policy: ChunkPolicy,
	range?: IndexRange,
): void {
	const rangeStart = range?.start ?? 0;
	const rangeEnd = range?.end ?? chunks.length;
	validateIndexRange(rangeStart, rangeEnd, chunks, "coalesceUniformChunks");
	if (rangeEnd - rangeStart < 2) {
		return;
	}
	const result: TreeChunk[] = [chunks[rangeStart] ?? oob()];
	let mutated = false;
	for (let chunkIndex = rangeStart + 1; chunkIndex < rangeEnd; chunkIndex++) {
		const current = chunks[chunkIndex] ?? oob();
		const previous = result.at(-1) ?? oob();
		const coalesced = tryCoalesceUniformChunks(previous, current, policy);
		if (coalesced === undefined) {
			result.push(current);
		} else {
			result[result.length - 1] = coalesced;
			mutated = true;
		}
	}
	if (mutated) {
		replaceArrayRange(chunks, rangeStart, rangeEnd, result);
	}
}
export function tryCoalesceUniformChunks(
	left: TreeChunk,
	right: TreeChunk,
	policy: ChunkPolicy,
): UniformChunk | undefined {
	if (!(left instanceof UniformChunk) || !(right instanceof UniformChunk)) {
		return undefined;
	}
	const leftTreeShape = left.shape.treeShape;
	const rightTreeShape = right.shape.treeShape;
	if (!leftTreeShape.equals(rightTreeShape)) {
		return undefined;
	}
	const leftCompressor = left.idCompressor;
	const rightCompressor = right.idCompressor;
	assert(
		leftCompressor === undefined ||
			rightCompressor === undefined ||
			leftCompressor === rightCompressor,
		0xd50  ,
	);
	const combinedTopLevel = left.topLevelLength + right.topLevelLength;
	if (combinedTopLevel > policy.uniformChunkNodeCountDynamicTargetMax) {
		return undefined;
	}
	if (!left.isShared()) {
		left.values.push(...right.values);
		left.shape = leftTreeShape.withTopLevelLength(combinedTopLevel);
		left.idCompressor ??= rightCompressor;
		right.referenceRemoved();
		return left;
	}
	const merged = new UniformChunk(
		leftTreeShape.withTopLevelLength(combinedTopLevel),
		[...left.values, ...right.values],
		leftCompressor ?? rightCompressor,
	);
	left.referenceRemoved();
	right.referenceRemoved();
	return merged;
}
export function insertValues(
	cursor: ITreeCursorSynchronous,
	shape: TreeShape,
	values: Value[],
	idCompressor?: IIdCompressor,
): void {
	assert(shape.type === cursor.type, 0x582  );
	if (shape.hasValue) {
		if (
			shape.mayContainCompressedIds &&
			typeof cursor.value === "string" &&
			idCompressor !== undefined &&
			isStableNodeIdentifier(cursor.value)
		) {
			values.push(idCompressor.tryRecompress(cursor.value) ?? cursor.value);
		} else {
			values.push(cursor.value);
		}
	}
	for (const [key, childShape, length] of shape.fieldsArray) {
		cursor.enterField(key);
		let count = 0;
		for (let inNodes = cursor.firstNode(); inNodes; inNodes = cursor.nextNode()) {
			insertValues(cursor, childShape, values, idCompressor);
			count++;
		}
		cursor.exitField();
		assert(length === count, 0x583  );
	}
}
export function uniformChunkFromCursor(
	cursor: ITreeCursorSynchronous,
	shape: TreeShape,
	maxTopLevelLength: number,
	skipLastNavigation: boolean,
	idCompressor?: IIdCompressor,
): UniformChunk {
	const values: TreeValue[] = [];
	let topLevelLength = 1;
	while (topLevelLength <= maxTopLevelLength) {
		insertValues(cursor, shape, values, idCompressor);
		if (topLevelLength === maxTopLevelLength) {
			if (!skipLastNavigation) {
				cursor.nextNode();
			}
			break;
		}
		cursor.nextNode();
		if (cursor.type !== shape.type) {
			break;
		}
		topLevelLength += 1;
	}
	return new UniformChunk(shape.withTopLevelLength(topLevelLength), values, idCompressor);
}
```

### Decision procedure: `feature-libraries/chunked-forest/chunkedForest.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/chunkedForest.ts:1-679`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
function makeRoot(): BasicChunk {
	return new BasicChunk(aboveRootPlaceholder, new Map());
}
function getFieldLength(field: readonly TreeChunk[]): number {
	return field.reduce((length, chunk) => length + chunk.topLevelLength, 0);
}
export function locateNodeInChunks(
	chunks: readonly TreeChunk[],
	index: number,
): { chunk: TreeChunk; indexOfChunk: number; indexWithinChunk: number } {
	assertNonNegativeSafeInteger(index);
	let indexWithinChunk = index;
	let indexOfChunk = 0;
	while (true) {
		const chunk = chunks[indexOfChunk] ?? oob();
		if (indexWithinChunk < chunk.topLevelLength) {
			return { chunk, indexOfChunk, indexWithinChunk };
		}
		indexWithinChunk -= chunk.topLevelLength;
		indexOfChunk++;
		if (indexOfChunk === chunks.length) {
			fail(0xaf7  );
		}
	}
}
export function ensureExclusiveBasicChunk(
	chunks: TreeChunk[],
	index: number,
	compressor: ChunkCompressor,
): BasicChunk {
	const { chunk, indexOfChunk, indexWithinChunk } = locateNodeInChunks(chunks, index);
	let finalIndexOfChunk: number;
	let basicChunk: BasicChunk;
	if (chunk instanceof BasicChunk) {
		basicChunk = chunk;
		finalIndexOfChunk = indexOfChunk;
	} else {
		const newChunks = mapCursorField(chunk.cursor(), (cursor) =>
			basicChunkTree(cursor, compressor),
		);
		chunks.splice(indexOfChunk, 1, ...newChunks);
		chunk.referenceRemoved();
		debugAssert(
			() =>
				newChunks[indexWithinChunk] === chunks[indexOfChunk + indexWithinChunk] ||
				"bad chunk indexing",
		);
		basicChunk = newChunks[indexWithinChunk] ?? oob();
		finalIndexOfChunk = indexOfChunk + indexWithinChunk;
	}
	debugAssert(() => chunks[finalIndexOfChunk] === basicChunk || "bad child index");
	let exclusiveChunk: BasicChunk;
	if (basicChunk.isShared()) {
		exclusiveChunk = chunks[finalIndexOfChunk] = basicChunk.clone();
		basicChunk.referenceRemoved();
	} else {
		exclusiveChunk = basicChunk;
	}
	return exclusiveChunk;
}
interface StackNode {
	mutableChunk: BasicChunk;
	key: FieldKey;
}
export class ChunkedForest implements IEditableForest, WithBreakable {
	private activeVisitor?: DeltaVisitor;
	private readonly deltaVisitors: Set<() => AnnouncedVisitor> = new Set();
	readonly #events = createEmitter<ForestEvents>();
	public readonly events: Listenable<ForestEvents> = this.#events;
	public constructor(
		public roots: BasicChunk,
		public readonly schema: TreeStoredSchemaSubscription,
		public readonly chunker: IChunker,
		public readonly anchors: AnchorSet = new AnchorSet(),
		public readonly idCompressor?: IIdCompressor,
		public readonly breaker: Breakable = new Breakable("ChunkedForest"),
	) {}
	public get isEmpty(): boolean {
		this.breaker.use();
		return this.roots.fields.size === 0;
	}
	public clone(schema: TreeStoredSchemaSubscription, breaker?: Breakable): ChunkedForest {
		this.breaker.use();
		this.roots.referenceAdded();
		return new ChunkedForest(
			this.roots,
			schema,
			this.chunker.clone(schema),
			undefined,
			this.idCompressor,
			breaker ?? this.breaker,
		);
	}
	public chunkField(cursor: ITreeCursorSynchronous): TreeChunk[] {
		this.breaker.use();
		return chunkField(cursor, { idCompressor: this.idCompressor, policy: this.chunker });
	}
	public forgetAnchor(anchor: Anchor): void {
		this.anchors.forget(anchor);
	}
	public registerAnnouncedVisitor(visitor: () => AnnouncedVisitor): void {
		this.deltaVisitors.add(visitor);
	}
	public deregisterAnnouncedVisitor(visitor: () => AnnouncedVisitor): void {
		this.deltaVisitors.delete(visitor);
	}
	public acquireVisitor(): DeltaVisitor {
		this.breaker.use();
		assert(
			this.activeVisitor === undefined,
			0x76a  ,
		);
		if (this.roots.isShared()) {
			const oldRoots = this.roots;
			this.roots = oldRoots.clone();
			oldRoots.referenceRemoved();
		}
		const forestVisitor = {
			forest: this,
			mutableChunkStack: [] as StackNode[],
			mutableChunk: this.roots as BasicChunk | undefined,
			getParent(): StackNode {
				assert(hasSome(this.mutableChunkStack), 0x532  );
				return getLast(this.mutableChunkStack);
			},
			free(): void {
				this.mutableChunk = undefined;
				this.mutableChunkStack.length = 0;
				assert(
					this.forest.activeVisitor !== undefined,
					0x76b  ,
				);
				this.forest.activeVisitor = undefined;
			},
			destroy(detachedField: FieldKey, count: number): void {
				this.forest.#events.emit("beforeChange");
				const field = this.forest.roots.fields.get(detachedField);
				assert(field !== undefined, 0xd1d  );
				assert(
					getFieldLength(field) === count,
					0xd1e  ,
				);
				this.forest.roots.fields.delete(detachedField);
				for (const chunk of field) {
					chunk.referenceRemoved();
				}
			},
			create(content: readonly ITreeCursorSynchronous[], destination: FieldKey): void {
				this.forest.#events.emit("beforeChange");
				assert(
					!this.forest.roots.fields.has(destination),
					0xd1f  ,
				);
				const chunks: TreeChunk[] = content.map((c) =>
					chunkTree(c, {
						policy: this.forest.chunker,
						idCompressor: this.forest.idCompressor,
					}),
				);
				this.forest.roots.fields.set(destination, chunks);
				this.forest.#events.emit("afterRootFieldCreated", destination);
			},
			attach(source: FieldKey, count: number, destination: PlaceIndex): void {
				this.attachEdit(source, count, destination);
			},
			detach(source: Range, destination: FieldKey, id: DeltaDetachedNodeId): void {
				this.detachEdit(source, destination);
			},
			attachEdit(source: FieldKey, count: number, destination: PlaceIndex): void {
				this.forest.#events.emit("beforeChange");
				const parent = this.getParent();
				assert(
					parent.mutableChunk !== this.forest.roots || parent.key !== source,
					0xd20  ,
				);
				const sourceField = this.forest.roots.fields.get(source);
				assert(sourceField !== undefined, 0xd21  );
				assert(
					getFieldLength(sourceField) === count,
					0xd22  ,
				);
				const destinationField = getOrAddEmptyToMap(parent.mutableChunk.fields, parent.key);
				assert(
					destination <= getFieldLength(destinationField),
					0xd23  ,
				);
				const destinationChunkIndex = splitFieldAtIndex(destinationField, destination, {
					policy: this.forest.chunker,
					idCompressor: this.forest.idCompressor,
				});
				this.forest.roots.fields.delete(source);
				destinationField.splice(destinationChunkIndex, 0, ...sourceField);
				const coalesceStart = Math.max(0, destinationChunkIndex - 1);
				const coalesceEnd = Math.min(
					destinationField.length,
					destinationChunkIndex + sourceField.length + 1,
				);
				coalesceUniformChunks(destinationField, this.forest.chunker, {
					start: coalesceStart,
					end: coalesceEnd,
				});
			},
			detachEdit(source: Range, destination: FieldKey | undefined): void {
				this.forest.#events.emit("beforeChange");
				const parent = this.getParent();
				const sourceField = parent.mutableChunk.fields.get(parent.key) ?? [];
				assert(source.start <= source.end, 0xd24  );
				assert(
					source.end <= getFieldLength(sourceField),
					0xd25  ,
				);
				if (destination !== undefined) {
					assert(
						parent.mutableChunk !== this.forest.roots || parent.key !== destination,
						0xd26  ,
					);
					assert(
						!this.forest.roots.fields.has(destination),
						0xd27  ,
					);
				}
				const policy: ChunkCompressor = {
					policy: this.forest.chunker,
					idCompressor: this.forest.idCompressor,
				};
				const startChunkIndex = splitFieldAtIndex(sourceField, source.start, policy);
				const endChunkIndex = splitFieldAtIndex(sourceField, source.end, policy);
				const newField = sourceField.splice(startChunkIndex, endChunkIndex - startChunkIndex);
				const coalesceStart = Math.max(0, startChunkIndex - 1);
				const coalesceEnd = Math.min(sourceField.length, startChunkIndex + 1);
				coalesceUniformChunks(sourceField, this.forest.chunker, {
					start: coalesceStart,
					end: coalesceEnd,
				});
				if (destination === undefined) {
					for (const child of newField) {
						child.referenceRemoved();
					}
				} else {
					if (newField.length > 0) {
						this.forest.roots.fields.set(destination, newField);
					}
				}
				if (sourceField.length === 0) {
					parent.mutableChunk.fields.delete(parent.key);
				}
			},
			enterNode(index: number): void {
				assert(this.mutableChunk === undefined, 0x535  );
				const parent = this.getParent();
				const chunks =
					parent.mutableChunk.fields.get(parent.key) ?? fail(0xaf6  );
				this.mutableChunk = ensureExclusiveBasicChunk(chunks, index, {
					policy: this.forest.chunker,
					idCompressor: this.forest.idCompressor,
				});
			},
			exitNode(index: number): void {
				assert(this.mutableChunk !== undefined, 0x537  );
				this.mutableChunk = undefined;
			},
			enterField(key: FieldKey): void {
				assert(this.mutableChunk !== undefined, 0x538  );
				this.mutableChunkStack.push({ key, mutableChunk: this.mutableChunk });
				this.mutableChunk = undefined;
			},
			exitField(key: FieldKey): void {
				const top = this.mutableChunkStack.pop() ?? fail(0xaf8  );
				assert(this.mutableChunk === undefined, 0x539  );
				this.mutableChunk = top.mutableChunk;
			},
		};
		const announcedVisitors: AnnouncedVisitor[] = [];
		for (const getVisitor of this.deltaVisitors) {
			announcedVisitors.push(getVisitor());
		}
		const visitor = combineVisitors([
			makeBreakingVisitor(forestVisitor, this.breaker),
			...announcedVisitors,
		]);
		this.activeVisitor = visitor;
		return visitor;
	}
	private nextDetachedFieldIdentifier = 0;
	public newDetachedField(): DetachedField {
		const field: DetachedField = brand(String(this.nextDetachedFieldIdentifier));
		assert(
			!this.roots.fields.has(detachedFieldAsKey(field)),
			0x53a  ,
		);
		this.nextDetachedFieldIdentifier += 1;
		return field;
	}
	public allocateCursor(): Cursor {
		this.breaker.use();
		return new Cursor(
			this,
			ITreeSubscriptionCursorState.Cleared,
			[],
			[],
			[],
			[],
			[],
			[],
			0,
			0,
			0,
			undefined,
		);
	}
	public tryMoveCursorToNode(
		destination: Anchor,
		cursorToMove: ITreeSubscriptionCursor,
	): TreeNavigationResult {
		this.breaker.use();
		const path = this.anchors.locate(destination);
		if (path === undefined) {
			return TreeNavigationResult.NotFound;
		}
		this.moveCursorToPath(path, cursorToMove);
		return TreeNavigationResult.Ok;
	}
	public tryMoveCursorToField(
		destination: FieldAnchor,
		cursorToMove: ITreeSubscriptionCursor,
	): TreeNavigationResult {
		this.breaker.use();
		assert(
			cursorToMove instanceof Cursor,
			0x53b  ,
		);
		if (destination.parent === undefined) {
			cursorToMove.setToDetachedSequence(destination.fieldKey);
			return TreeNavigationResult.Ok;
		}
		const result = this.tryMoveCursorToNode(destination.parent, cursorToMove);
		if (result !== TreeNavigationResult.Ok) {
			return result;
		}
		cursorToMove.enterField(destination.fieldKey);
		return TreeNavigationResult.Ok;
	}
	public moveCursorToPath(destination: UpPath, cursorToMove: ITreeSubscriptionCursor): void {
		this.breaker.use();
		assert(
			cursorToMove instanceof Cursor,
			0x53c  ,
		);
		assert(
			cursorToMove.forest === this,
			0x53d  ,
		);
		const indexStack: number[] = [];
		const keyStack: FieldKey[] = [];
		let path: UpPath | undefined = destination;
		while (path !== undefined) {
			indexStack.push(path.parentIndex);
			keyStack.push(path.parentField);
			path = path.parent;
		}
		cursorToMove.clear();
		while (keyStack.length > 0) {
			const key = keyStack.pop()!;
			if (cursorToMove.state === ITreeSubscriptionCursorState.Cleared) {
				cursorToMove.setToDetachedSequence(key);
				cursorToMove.state = ITreeSubscriptionCursorState.Current;
			} else {
				cursorToMove.enterField(key);
			}
			cursorToMove.enterNode(indexStack.pop()!);
		}
	}
	public getCursorAboveDetachedFields(): ITreeCursorSynchronous {
		this.breaker.use();
		const rootCursor = this.roots.cursor();
		rootCursor.enterNode(0);
		return rootCursor;
	}
}
class Cursor extends BasicChunkCursor implements ITreeSubscriptionCursor {
	public constructor(
		public readonly forest: ChunkedForest,
		public state: ITreeSubscriptionCursorState,
		root: readonly TreeChunk[],
		siblingStack: SiblingsOrKey[],
		indexStack: number[],
		indexOfChunkStack: number[],
		indexWithinChunkStack: number[],
		siblings: SiblingsOrKey,
		index: number,
		indexOfChunk: number,
		indexWithinChunk: number,
		nestedCursor: ChunkedCursor | undefined,
	) {
		super(
			root,
			siblingStack,
			indexStack,
			indexOfChunkStack,
			indexWithinChunkStack,
			siblings,
			index,
			indexOfChunk,
			indexWithinChunk,
			nestedCursor,
		);
	}
	public setToDetachedSequence(key: FieldKey): void {
		this.root = (this.forest.roots.fields.get(key) ?? []) as BasicChunk[];
		this.siblingStack.length = 0;
		this.indexStack.length = 0;
		this.indexOfChunkStack.length = 0;
		this.indexWithinChunkStack.length = 0;
		this.siblings = [key];
		this.index = 0;
		this.indexOfChunk = 0;
		this.indexWithinChunk = 0;
		this.nestedCursor = undefined;
	}
	public override fork(): Cursor {
		return new Cursor(
			this.forest,
			this.state,
			this.root,
			[...this.siblingStack],
			[...this.indexStack],
			[...this.indexOfChunkStack],
			[...this.indexWithinChunkStack],
			this.siblings,
			this.index,
			this.indexOfChunk,
			this.indexWithinChunk,
			this.nestedCursor?.fork(),
		);
	}
	public buildFieldAnchor(): FieldAnchor {
		const path = this.getFieldPath();
		const anchor =
			path.parent === undefined ? undefined : this.forest.anchors.track(path.parent);
		return { parent: anchor, fieldKey: path.field };
	}
	public free(): void {
		this.state = ITreeSubscriptionCursorState.Freed;
	}
	public buildAnchor(): Anchor {
		return this.forest.anchors.track(this.getPath());
	}
	public clear(): void {
		this.state = ITreeSubscriptionCursorState.Cleared;
		this.setToDetachedSequence(rootFieldKey);
	}
}
export function buildChunkedForest(
	chunker: IChunker,
	anchors?: AnchorSet,
	idCompressor?: IIdCompressor,
	breaker?: Breakable,
): ChunkedForest {
	return new ChunkedForest(
		makeRoot(),
		chunker.schema,
		chunker,
		anchors,
		idCompressor,
		breaker,
	);
}
```

### Decision procedure: `feature-libraries/chunked-forest/emptyChunk.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/emptyChunk.ts:1-118`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const emptyChunk: TreeChunk = {
	topLevelLength: 0,
	cursor(): ChunkedCursor {
		return emptyCursor;
	},
	referenceAdded(): void {},
	referenceRemoved(): void {},
	isShared(): boolean {
		return false;
	},
};
const emptyPath: FieldUpPath = {
	parent: undefined,
	field: dummyRoot,
};
export const emptyCursor: ChunkedCursor = {
	[CursorMarker]: true,
	pending: false,
	mode: CursorLocationType.Fields,
	[cursorChunk]: emptyChunk,
	nextField(): boolean {
		fail(0xafb  );
	},
	exitField(): void {
		fail(0xafc  );
	},
	skipPendingFields(): boolean {
		return true;
	},
	getFieldKey(): FieldKey {
		return emptyPath.field;
	},
	getFieldLength(): number {
		return 0;
	},
	firstNode(): boolean {
		return false;
	},
	enterNode(childIndex: number): void {
		fail(0xafd  );
	},
	getFieldPath(prefix?: PathRootPrefix): FieldUpPath {
		return prefixFieldPath(prefix, emptyPath);
	},
	getPath(): UpPath | undefined {
		fail(0xafe  );
	},
	get fieldIndex(): never {
		return fail(0xaff  );
	},
	get chunkStart(): never {
		return fail(0xb00  );
	},
	get chunkLength(): never {
		return fail(0xb01  );
	},
	seekNodes(offset: number): boolean {
		fail(0xb02  );
	},
	nextNode(): boolean {
		fail(0xb03  );
	},
	exitNode(): void {
		fail(0xb04  );
	},
	firstField(): boolean {
		fail(0xb05  );
	},
	enterField(key: FieldKey): void {
		fail(0xb06  );
	},
	get type(): never {
		return fail(0xb07  );
	},
	get value(): never {
		return fail(0xb08  );
	},
	atChunkRoot(): boolean {
		return true;
	},
	fork(): ChunkedCursor {
		return emptyCursor;
	},
};
```

### Decision procedure: `feature-libraries/chunked-forest/sequenceChunk.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/sequenceChunk.ts:1-63`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class SequenceChunk extends ReferenceCountedBase implements TreeChunk {
	public get topLevelLength(): number {
		let total = 0;
		for (const child of this.subChunks) {
			total += child.topLevelLength;
		}
		return total;
	}
	public constructor(public readonly subChunks: TreeChunk[]) {
		super();
	}
	public clone(): SequenceChunk {
		const subChunks = this.subChunks.map((child) => {
			child.referenceAdded();
			return child;
		});
		return new SequenceChunk(subChunks);
	}
	public cursor(): ChunkedCursor {
		return new BasicChunkCursor(
			this.subChunks,
			[],
			[],
			[],
			[],
			[dummyRoot],
			0,
			0,
			0,
			undefined,
		);
	}
	protected onUnreferenced(): void {
		for (const child of this.subChunks) {
			child.referenceRemoved();
		}
	}
}
```

### Decision procedure: `feature-libraries/chunked-forest/uniformChunk.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/uniformChunk.ts:1-712`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function uniformChunk(shape: ChunkShape, values: TreeValue[]): TreeChunk {
	return new UniformChunk(shape, values);
}
export class UniformChunk extends ReferenceCountedBase implements TreeChunk {
	public idCompressor: undefined | IIdCompressor;
	public constructor(
		public shape: ChunkShape,
		public values: TreeValue[],
		idCompressor?: IIdCompressor,
	) {
		super();
		this.idCompressor = shape.treeShape.mayContainCompressedIds ? idCompressor : undefined;
		assert(
			shape.treeShape.valuesPerTopLevelNode * shape.topLevelLength === values.length,
			0x4c3  ,
		);
	}
	public get topLevelLength(): number {
		return this.shape.topLevelLength;
	}
	public clone(): UniformChunk {
		return new UniformChunk(this.shape, [...this.values]);
	}
	public cursor(): Cursor {
		return new Cursor(this);
	}
	protected onUnreferenced(): void {}
}
export type FieldShape = readonly [FieldKey, TreeShape, number];
const chunkShapeCacheLimit = 8;
export class TreeShape {
	public readonly fields: ReadonlyMap<FieldKey, OffsetShape>;
	public readonly fieldsOffsetArray: readonly OffsetShape[];
	public readonly valuesPerTopLevelNode: number;
	public readonly positions: readonly NodePositionInfo[];
	public readonly mayContainCompressedIds: boolean;
	private readonly chunkShapeCache: Map<number, ChunkShape> = new Map();
	public constructor(
		public readonly type: TreeNodeSchemaIdentifier,
		public readonly hasValue: boolean,
		public readonly fieldsArray: readonly FieldShape[],
		maybeCompressedIdLeaf: boolean = false,
	) {
		assert(
			hasValue === false || fieldsArray.length === 0,
			0xcef  ,
		);
		if (maybeCompressedIdLeaf) {
			assert(
				hasValue && type === "com.fluidframework.leaf.string",
				0xcf0  ,
			);
		}
		this.mayContainCompressedIds =
			maybeCompressedIdLeaf || fieldsArray.some(([, shape]) => shape.mayContainCompressedIds);
		const fields: Map<FieldKey, OffsetShape> = new Map();
		let numberOfValues = hasValue ? 1 : 0;
		const infos: NodePositionInfo[] = [
			new NodePositionInfo(undefined, dummyRoot, 0, undefined, undefined, this, 1, 0),
		];
		let fieldIndex = 0;
		for (const [k, f, length] of fieldsArray) {
			assert(!fields.has(k), 0x4c5  );
			const offset = new OffsetShape(f, length, infos.length, k, fieldIndex);
			fields.set(k, offset);
			clonePositions(0, [k, f, length], fieldIndex, numberOfValues, infos);
			numberOfValues += f.valuesPerTopLevelNode * length;
			fieldIndex++;
		}
		this.fields = fields;
		this.valuesPerTopLevelNode = numberOfValues;
		this.positions = infos;
		this.fieldsOffsetArray = [...fields.values()];
	}
	public equals(other: TreeShape): boolean {
		if (this === other) {
			return true;
		}
		if (this.type !== other.type) {
			return false;
		}
		if (
			!compareArrays(
				this.fieldsArray,
				other.fieldsArray,
				([k, f, l], [k2, f2, l2]) => k === k2 && l === l2 && f.equals(f2),
			)
		) {
			return false;
		}
		return (
			this.hasValue === other.hasValue &&
			this.mayContainCompressedIds === other.mayContainCompressedIds
		);
	}
	public withTopLevelLength(topLevelLength: number): ChunkShape {
		if (topLevelLength < chunkShapeCacheLimit) {
			return getOrCreate(
				this.chunkShapeCache,
				topLevelLength,
				() => new ChunkShape(this, topLevelLength),
			);
		}
		return new ChunkShape(this, topLevelLength);
	}
}
function clonePositions(
	indexOfParentInOutput: number | undefined,
	[key, shape, copies]: FieldShape,
	indexOfParentField: number,
	valueOffset: number,
	outputInto: NodePositionInfo[] | (NodePositionInfo | undefined)[],
): void {
	const offset = outputInto.length;
	for (let index = 0; index < copies; index++) {
		for (const inner of shape.positions) {
			const wasRoot = inner.indexOfParentPosition === undefined;
			const parentPositionIndex = wasRoot
				? indexOfParentInOutput
				: inner.indexOfParentPosition + index * shape.positions.length + offset;
			outputInto.push(
				new NodePositionInfo(
					parentPositionIndex === undefined ? undefined : outputInto[parentPositionIndex],
					inner.parentField === dummyRoot ? key : inner.parentField,
					wasRoot ? index : inner.parentIndex,
					inner.indexOfParentField ?? indexOfParentField,
					parentPositionIndex,
					inner.shape,
					wasRoot ? copies : inner.topLevelLength,
					inner.valueOffset + valueOffset + shape.valuesPerTopLevelNode * index,
				),
			);
		}
	}
}
export class ChunkShape {
	public constructor(
		public readonly treeShape: TreeShape,
		public readonly topLevelLength: number,
	) {
		assert(topLevelLength > 0, 0x4c6  );
	}
	public equals(other: ChunkShape): boolean {
		return this.topLevelLength === other.topLevelLength && this.treeShape === other.treeShape;
	}
}
class OffsetShape {
	public constructor(
		public readonly shape: TreeShape,
		public readonly topLevelLength: number,
		public readonly offset: number,
		public readonly key: FieldKey,
		public readonly indexOfParentField: number | undefined,
	) {}
}
class NodePositionInfo implements UpPath {
	public constructor(
		public readonly parent: NodePositionInfo | undefined,
		public readonly parentField: FieldKey,
		public readonly parentIndex: number,
		public readonly indexOfParentField: number | undefined,
		public readonly indexOfParentPosition: number | undefined,
		public readonly shape: TreeShape,
		public readonly topLevelLength: number,
		public readonly valueOffset: number,
	) {}
}
class Cursor extends SynchronousCursor implements ChunkedCursor {
	private positionIndex!: number;
	private nodePositionInfo: NodePositionInfo | undefined;
	private topLevelIndex: number = 0;
	private readonly shape: ChunkShape;
	private readonly treeShape: TreeShape;
	private readonly nodeLength: number;
	private readonly stride: number;
	public mode: CursorLocationType = CursorLocationType.Fields;
	private fieldKey?: FieldKey;
	private indexOfField: number = 0;
	public constructor(private readonly chunk: UniformChunk) {
		super();
		this.shape = this.chunk.shape;
		this.treeShape = this.shape.treeShape;
		this.nodeLength = this.treeShape.positions.length;
		this.stride = this.treeShape.valuesPerTopLevelNode;
		this.fieldKey = dummyRoot;
		this.moveToPosition(0);
	}
	public get [cursorChunk](): UniformChunk | undefined {
		return this.atChunkRoot() ? this.chunk : undefined;
	}
	public atChunkRoot(): boolean {
		assert(
			(this.fieldKey === undefined) === (this.mode === CursorLocationType.Nodes),
			0x560  ,
		);
		return (
			this.nodePositionInfo === undefined ||
			(this.nodePositionInfo.parent === undefined && this.fieldKey === undefined)
		);
	}
	public fork(): Cursor {
		const cursor = new Cursor(this.chunk);
		cursor.mode = this.mode;
		cursor.fieldKey = this.fieldKey;
		cursor.indexOfField = this.indexOfField;
		cursor.moveToPosition(this.positionIndex);
		return cursor;
	}
	private moveToPosition(positionIndex: number): void {
		this.positionIndex = positionIndex;
		if (positionIndex === 0) {
			this.nodePositionInfo = undefined;
			assert(this.mode === CursorLocationType.Fields, 0x562  );
			return;
		}
		const decoded = this.decodePosition(positionIndex);
		this.topLevelIndex = decoded.topLevelIndex;
		this.nodePositionInfo = decoded.info;
	}
	private decodePosition(positionIndex: number): {
		withinTree: number;
		topLevelIndex: number;
		info: NodePositionInfo;
	} {
		const offset = positionIndex - 1;
		const withinTree = offset % this.nodeLength;
		const topLevelIndex = (offset - withinTree) / this.nodeLength;
		const info = this.treeShape.positions[withinTree] ?? oob();
		return { withinTree, topLevelIndex, info };
	}
	private materializePath(positionIndex: number): UpPath | undefined {
		if (positionIndex === 0) {
			return undefined;
		}
		const { withinTree, topLevelIndex, info } = this.decodePosition(positionIndex);
		if (info.parent === undefined) {
			return { parent: undefined, parentField: info.parentField, parentIndex: topLevelIndex };
		}
		return {
			parent: this.materializePath(
				positionIndex - withinTree + (info.indexOfParentPosition ?? oob()),
			),
			parentField: info.parentField,
			parentIndex: info.parentIndex,
		};
	}
	private nodeInfo(requiredMode: CursorLocationType): NodePositionInfo {
		assert(this.mode === requiredMode, 0x4c8  );
		assert(
			this.nodePositionInfo !== undefined,
			0x53e  ,
		);
		return this.nodePositionInfo;
	}
	public nextField(): boolean {
		this.indexOfField++;
		const fields = this.nodeInfo(CursorLocationType.Fields).shape.fieldsArray;
		if (this.indexOfField < fields.length) {
			const fieldArr = fields[this.indexOfField] ?? oob();
			this.fieldKey = fieldArr[0];
			return true;
		}
		this.exitField();
		return false;
	}
	public exitField(): void {
		assert(this.mode === CursorLocationType.Fields, 0x4c9  );
		assert(this.nodePositionInfo !== undefined, 0x563  );
		this.fieldKey = undefined;
		this.mode = CursorLocationType.Nodes;
	}
	public getFieldKey(): FieldKey {
		return this.fieldKey ?? fail(0xb09  );
	}
	public getFieldLength(): number {
		assert(
			this.mode === CursorLocationType.Fields,
			0x53f  ,
		);
		if (this.nodePositionInfo === undefined) {
			return this.shape.topLevelLength;
		}
		const fieldInfo = this.nodePositionInfo.shape.fieldsArray[this.indexOfField];
		if (fieldInfo === undefined) {
			return 0;
		}
		return fieldInfo[2];
	}
	public firstNode(): boolean {
		assert(
			this.mode === CursorLocationType.Fields,
			0x540  ,
		);
		if (this.nodePositionInfo === undefined) {
			this.enterRootNodeInner(0);
			return true;
		} else {
			return this.enterNodeInner(this.nodePositionInfo, 0);
		}
	}
	public enterNode(childIndex: number): void {
		assert(
			this.mode === CursorLocationType.Fields,
			0x541  ,
		);
		assert(childIndex >= 0, 0x4ca  );
		if (this.nodePositionInfo === undefined) {
			assert(
				childIndex < this.shape.topLevelLength,
				0x542  ,
			);
			this.enterRootNodeInner(childIndex);
		} else {
			const moved = this.enterNodeInner(this.nodePositionInfo, childIndex);
			assert(moved, 0x4cb  );
		}
	}
	private enterNodeInner(currentPosition: NodePositionInfo, childIndex: number): boolean {
		const shape = currentPosition.shape;
		const fields = shape.fieldsOffsetArray;
		if (this.indexOfField >= fields.length) {
			return false;
		}
		const f = shape.fieldsOffsetArray[this.indexOfField] ?? oob();
		if (childIndex >= f.topLevelLength) {
			return false;
		}
		this.mode = CursorLocationType.Nodes;
		this.fieldKey = undefined;
		this.moveToPosition(this.positionIndex + f.offset + childIndex * f.shape.positions.length);
		assert(this.fieldIndex === childIndex, 0x4cc  );
		return true;
	}
	private enterRootNodeInner(childIndex: number): void {
		this.mode = CursorLocationType.Nodes;
		this.fieldKey = undefined;
		this.moveToPosition(1 + childIndex * this.nodeLength);
		assert(this.fieldIndex === childIndex, 0x543  );
	}
	public getFieldPath(prefix?: PathRootPrefix): FieldUpPath {
		return prefixFieldPath(prefix, {
			field: this.getFieldKey(),
			parent: this.materializePath(this.positionIndex),
		});
	}
	public getPath(prefix?: PathRootPrefix): UpPath | undefined {
		this.nodeInfo(CursorLocationType.Nodes);
		return prefixPath(prefix, this.materializePath(this.positionIndex));
	}
	public get fieldIndex(): number {
		const info = this.nodeInfo(CursorLocationType.Nodes);
		return info.parent === undefined ? this.topLevelIndex : info.parentIndex;
	}
	public readonly chunkStart: number = 0;
	private siblingCount(info: NodePositionInfo): number {
		return info.parent === undefined ? this.shape.topLevelLength : info.topLevelLength;
	}
	public get chunkLength(): number {
		return this.siblingCount(this.nodeInfo(CursorLocationType.Nodes));
	}
	public seekNodes(offset: number): boolean {
		const info = this.nodeInfo(CursorLocationType.Nodes);
		const index = offset + this.fieldIndex;
		if (index >= 0 && index < this.siblingCount(info)) {
			this.moveToPosition(this.positionIndex + offset * info.shape.positions.length);
			return true;
		}
		this.exitNode();
		return false;
	}
	public nextNode(): boolean {
		const info = this.nodeInfo(CursorLocationType.Nodes);
		const index = this.fieldIndex + 1;
		if (index === this.siblingCount(info)) {
			this.exitNode();
			return false;
		}
		this.moveToPosition(this.positionIndex + info.shape.positions.length);
		return true;
	}
	public exitNode(): void {
		const info = this.nodeInfo(CursorLocationType.Nodes);
		const withinTree = this.positionIndex - 1 - this.topLevelIndex * this.nodeLength;
		this.indexOfField = info.indexOfParentField ?? 0;
		this.fieldKey = info.parentField;
		this.mode = CursorLocationType.Fields;
		this.moveToPosition(
			info.indexOfParentPosition === undefined
				? 0
				: this.positionIndex - withinTree + info.indexOfParentPosition,
		);
	}
	public firstField(): boolean {
		const fieldsArray = this.nodeInfo(CursorLocationType.Nodes).shape.fieldsArray;
		if (!hasSome(fieldsArray)) {
			return false;
		}
		this.indexOfField = 0;
		this.mode = CursorLocationType.Fields;
		const fields = fieldsArray[0];
		this.fieldKey = fields[0];
		return true;
	}
	public enterField(key: FieldKey): void {
		const fieldMap = this.nodeInfo(CursorLocationType.Nodes).shape.fields;
		const fieldInfo = fieldMap.get(key);
		this.indexOfField =
			fieldInfo === undefined
				? fieldMap.size
				: (fieldInfo.indexOfParentField ?? fail(0xb0c  ));
		this.fieldKey = key;
		this.mode = CursorLocationType.Fields;
	}
	public get type(): TreeNodeSchemaIdentifier {
		return this.nodeInfo(CursorLocationType.Nodes).shape.type;
	}
	public get value(): Value {
		const info = this.nodeInfo(CursorLocationType.Nodes);
		if (info.shape.hasValue) {
			const value = this.chunk.values[info.valueOffset + this.topLevelIndex * this.stride];
			if (info.shape.mayContainCompressedIds && typeof value === "number") {
				const idCompressor = this.chunk.idCompressor;
				assert(
					idCompressor !== undefined,
					0xcf1  ,
				);
				return idCompressor.decompress(value as SessionSpaceCompressedId);
			}
			return value;
		}
		return undefined;
	}
}
```

### Decision procedure: `feature-libraries/chunked-forest/codec/chunkDecoding.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkDecoding.ts:1-509`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function decode(
	chunk: EncodedFieldBatchAnyVersion,
	idDecodingContext: IdDecodingContext,
	incrementalDecoder?: IncrementalDecoder,
): TreeChunk[] {
	return genericDecode(
		decoderLibrary,
		new DecoderContext<EncodedChunkShape>(
			chunk.identifiers,
			chunk.shapes,
			idDecodingContext,
			incrementalDecoder,
		),
		chunk,
		anyDecoder,
	);
}
export function normalizeToNodeShape(
	input: EncodedNodeShape | EncodedSpecializedNodeShape,
	context: DecoderContext<EncodedChunkShape>,
	pendingResolution: Set<ShapeIndex> = new Set(),
): EncodedNodeShape {
	if (!("base" in input)) {
		return input;
	}
	const baseIndex = input.base;
	assert(!pendingResolution.has(baseIndex), 0xcfb  );
	pendingResolution.add(baseIndex);
	const encoded = context.shapes[baseIndex];
	assert(encoded !== undefined, 0xcfc  );
	const baseShape = encoded.c ?? ("f" in encoded ? encoded.f : undefined);
	assert(
		baseShape !== undefined,
		0xcfd  ,
	);
	return applySpecialization(
		normalizeToNodeShape(baseShape, context, pendingResolution),
		input,
		context,
	);
}
export function applySpecialization(
	base: EncodedNodeShape,
	overrides: EncodedSpecializedNodeShape,
	context: DecoderContext<EncodedChunkShape>,
): EncodedNodeShape {
	const fields = [...(base.fields ?? [])];
	const indexFromKey = new Map<FieldKey, number>();
	for (const [i, [keyEncoded]] of fields.entries()) {
		const key = context.identifier<FieldKey>(keyEncoded);
		assert(!indexFromKey.has(key), 0xcfe  );
		indexFromKey.set(key, i);
	}
	const seenOverrideKeys = new Set<FieldKey>();
	for (const [keyEncoded, shapeIndex] of overrides.fields ?? []) {
		const key = context.identifier<FieldKey>(keyEncoded);
		assert(
			!seenOverrideKeys.has(key),
			0xcff  ,
		);
		seenOverrideKeys.add(key);
		const existingIndex = indexFromKey.get(key);
		if (existingIndex === undefined) {
			fields.push([keyEncoded, shapeIndex]);
		} else {
			const index = fields[existingIndex];
			assert(index !== undefined, 0xd00  );
			fields[existingIndex] = [index[0], shapeIndex];
		}
	}
	return {
		type: base.type,
		value: resolveOverride(overrides.value, base.value),
		fields: fields.length > 0 ? fields : undefined,
		extraFields: resolveOverride(overrides.extraFields, base.extraFields),
	};
}
function resolveOverride<T>(
	override: T | null | undefined,
	baseValue: T | undefined,
): T | undefined {
	if (override === undefined) {
		return baseValue;
	}
	if (override === null) {
		return undefined;
	}
	return override;
}
export class SpecializedNodeDecoder implements ChunkDecoder {
	private readonly inner: NodeDecoder;
	public constructor(
		shape: EncodedSpecializedNodeShape,
		context: DecoderContext<EncodedChunkShape>,
	) {
		this.inner = new NodeDecoder(normalizeToNodeShape(shape, context), context);
	}
	public decode(decoders: readonly ChunkDecoder[], stream: StreamCursor): TreeChunk {
		return this.inner.decode(decoders, stream);
	}
}
const decoderLibrary = new DiscriminatedUnionDispatcher<
	EncodedChunkShape,
	[context: DecoderContext<EncodedChunkShape>],
	ChunkDecoder
>({
	a(shape: EncodedNestedArrayShape, context): ChunkDecoder {
		return new NestedArrayDecoder(shape);
	},
	b(shape: EncodedInlineArrayShape, context): ChunkDecoder {
		return new InlineArrayDecoder(shape);
	},
	c(shape: EncodedNodeShape, context): ChunkDecoder {
		return new NodeDecoder(shape, context);
	},
	d(shape: EncodedAnyShape): ChunkDecoder {
		return anyDecoder;
	},
	e(
		shape: EncodedIncrementalChunkShape,
		context: DecoderContext<EncodedChunkShape>,
	): ChunkDecoder {
		return new IncrementalChunkDecoder(context);
	},
	f(
		shape: EncodedSpecializedNodeShape,
		context: DecoderContext<EncodedChunkShape>,
	): ChunkDecoder {
		return new SpecializedNodeDecoder(shape, context);
	},
});
export function readValue(
	stream: StreamCursor,
	shape: EncodedValueShape,
	idDecodingContext: IdDecodingContext,
): Value {
	if (shape === undefined) {
		return readStreamBoolean(stream) ? readStreamValue(stream) : undefined;
	} else {
		if (shape === true) {
			return readStreamValue(stream);
		} else if (shape === false) {
			return undefined;
		} else if (Array.isArray(shape)) {
			assert(shape.length === 1, 0x734  );
			return shape[0] as Value;
		} else if (shape === SpecialField.Identifier) {
			const streamValue = readStream(stream);
			assert(
				typeof streamValue === "number" || typeof streamValue === "string",
				0x997  ,
			);
			const sessionIdOrString: SessionSpaceCompressedId | string =
				typeof streamValue === "string"
					? streamValue
					: idDecodingContext.resolveEncodedId(streamValue as OpSpaceCompressedId);
			return decompressIdentifierIfNeeded(sessionIdOrString, idDecodingContext.idCompressor);
		} else {
			unreachableCase(shape, "decoding values as deltas is not yet supported");
		}
	}
}
export function deaggregateChunks(chunk: TreeChunk): TreeChunk[] {
	if (chunk === emptyChunk) {
		return [];
	}
	if (chunk instanceof SequenceChunk) {
		assert(chunk.subChunks.length > 0, 0x735  );
		assert(chunk.subChunks.length > 1, 0x736  );
		for (const sub of chunk.subChunks) {
			assert(!(sub instanceof SequenceChunk), 0x737  );
			assert(sub !== emptyChunk, 0x738  );
			sub.referenceAdded();
		}
		chunk.referenceRemoved();
		return chunk.subChunks;
	} else {
		return [chunk];
	}
}
export function aggregateChunks(input: TreeChunk[]): TreeChunk {
	const chunks = input.flatMap(deaggregateChunks);
	switch (chunks.length) {
		case 0: {
			return emptyChunk;
		}
		case 1: {
			return chunks[0] ?? oob();
		}
		default: {
			return new SequenceChunk(chunks);
		}
	}
}
export class NestedArrayDecoder implements ChunkDecoder {
	public constructor(private readonly shape: EncodedNestedArrayShape) {}
	public decode(decoders: readonly ChunkDecoder[], stream: StreamCursor): TreeChunk {
		const decoder = decoders[this.shape] ?? oob();
		const chunks: TreeChunk[] = [];
		const data = readStream(stream);
		if (typeof data === "number") {
			const inner = { data: [], offset: 0 };
			for (let index = 0; index < data; index++) {
				chunks.push(decoder.decode(decoders, inner));
			}
		} else {
			assert(
				Array.isArray(data),
				0x739  ,
			);
			const inner = { data, offset: 0 };
			while (inner.offset !== inner.data.length) {
				chunks.push(decoder.decode(decoders, inner));
			}
		}
		return aggregateChunks(chunks);
	}
}
export class InlineArrayDecoder implements ChunkDecoder {
	public constructor(private readonly shape: EncodedInlineArrayShape) {}
	public decode(decoders: readonly ChunkDecoder[], stream: StreamCursor): TreeChunk {
		const length = this.shape.length;
		const decoder = decoders[this.shape.shape] ?? oob();
		const chunks: TreeChunk[] = [];
		for (let index = 0; index < length; index++) {
			chunks.push(decoder.decode(decoders, stream));
		}
		return aggregateChunks(chunks);
	}
}
export class IncrementalChunkDecoder implements ChunkDecoder {
	public constructor(private readonly context: DecoderContext<EncodedChunkShape>) {}
	public decode(_: readonly ChunkDecoder[], stream: StreamCursor): TreeChunk {
		assert(
			this.context.incrementalDecoder !== undefined,
			0xc27  ,
		);
		const chunkDecoder = (batch: EncodedFieldBatchAnyVersion): TreeChunk => {
			assert(
				supportsIncrementalEncoding(batch.version),
				0xc9f  ,
			);
			const context = new DecoderContext<EncodedChunkShape>(
				batch.identifiers,
				batch.shapes,
				this.context.idDecodingContext,
				this.context.incrementalDecoder,
			);
			const chunks = genericDecode(decoderLibrary, context, batch, anyDecoder);
			return aggregateChunks(chunks);
		};
		const chunkReferenceId = readStreamNumber(stream);
		return this.context.incrementalDecoder.decodeIncrementalChunk(
			brand(chunkReferenceId),
			chunkDecoder,
		);
	}
}
export const anyDecoder: ChunkDecoder = {
	decode(decoders: readonly ChunkDecoder[], stream: StreamCursor): TreeChunk {
		const shapeIndex = readStreamNumber(stream);
		const decoder = getChecked(decoders, shapeIndex);
		return decoder.decode(decoders, stream);
	},
};
type BasicFieldDecoder = (
	decoders: readonly ChunkDecoder[],
	stream: StreamCursor,
) => [FieldKey, TreeChunk];
function fieldDecoder(
	context: DecoderContext<EncodedChunkShape>,
	key: FieldKey,
	shape: number,
): BasicFieldDecoder {
	assertValidIndex(shape, context.shapes);
	return (decoders, stream) => {
		const decoder = decoders[shape] ?? oob();
		return [key, decoder.decode(decoders, stream)];
	};
}
export class NodeDecoder implements ChunkDecoder {
	private readonly type?: TreeNodeSchemaIdentifier;
	private readonly fieldDecoders: readonly BasicFieldDecoder[];
	public constructor(
		private readonly shape: EncodedNodeShape,
		private readonly context: DecoderContext<EncodedChunkShape>,
	) {
		this.type = shape.type === undefined ? undefined : context.identifier(shape.type);
		const fieldDecoders: BasicFieldDecoder[] = [];
		for (const [fieldKey, fieldShape] of shape.fields ?? []) {
			const key: FieldKey = context.identifier(fieldKey);
			fieldDecoders.push(fieldDecoder(context, key, fieldShape));
		}
		this.fieldDecoders = fieldDecoders;
	}
	public decode(decoders: readonly ChunkDecoder[], stream: StreamCursor): TreeChunk {
		const type: TreeNodeSchemaIdentifier =
			this.type ?? readStreamIdentifier(stream, this.context);
		const value = readValue(stream, this.shape.value, this.context.idDecodingContext);
		const fields: Map<FieldKey, TreeChunk[]> = new Map();
		function addField(key: FieldKey, data: TreeChunk): void {
			const chunks = deaggregateChunks(data);
			if (chunks.length > 0) {
				fields.set(key, chunks);
			}
		}
		for (const decoder of this.fieldDecoders) {
			const [key, content] = decoder(decoders, stream);
			addField(key, content);
		}
		if (this.shape.extraFields !== undefined) {
			const decoder = decoders[this.shape.extraFields] ?? oob();
			const inner = readStreamStream(stream);
			while (inner.offset !== inner.data.length) {
				const key: FieldKey = readStreamIdentifier(inner, this.context);
				addField(key, decoder.decode(decoders, inner));
			}
		}
		return new BasicChunk(type, fields, value);
	}
}
```

### Decision procedure: `feature-libraries/chunked-forest/codec/chunkDecodingGeneric.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkDecodingGeneric.ts:1-91`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function decode<TEncodedShape extends object, TContext>(
	decoderLibrary: DiscriminatedUnionDispatcher<
		TEncodedShape,
		[context: TContext],
		ChunkDecoder
	>,
	context: TContext,
	batch: EncodedFieldBatchGeneric<TEncodedShape>,
	rootDecoder: ChunkDecoder,
): TreeChunk[] {
	const decoders = batch.shapes.map((shape) => decoderLibrary.dispatch(shape, context));
	const chunks: TreeChunk[] = [];
	for (const field of batch.data) {
		const stream = { data: field, offset: 0 };
		const result = rootDecoder.decode(decoders, stream);
		assert(
			stream.offset === stream.data.length,
			0x73a  ,
		);
		chunks.push(result);
	}
	return chunks;
}
export class DecoderContext<TEncodedShape = unknown> {
	public constructor(
		public readonly identifiers: readonly string[],
		public readonly shapes: readonly TEncodedShape[],
		public readonly idDecodingContext: IdDecodingContext,
		public readonly incrementalDecoder: IncrementalDecoder | undefined,
	) {}
	public identifier<T extends string & BrandedType<string, string>>(
		encoded: IdentifierOrIndex,
	): T {
		if (typeof encoded === "string") {
			return encoded as T;
		}
		return getChecked(this.identifiers, encoded) as T;
	}
}
export function readStreamIdentifier<T extends string & BrandedType<string, string>>(
	stream: StreamCursor,
	context: DecoderContext,
): T {
	const content = readStream(stream);
	assert(
		typeof content === "number" || typeof content === "string",
		0x73b  ,
	);
	return context.identifier(content);
}
```

### Decision procedure: `feature-libraries/chunked-forest/codec/chunkEncodingGeneric.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkEncodingGeneric.ts:1-186`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class IdentifierToken {
	public constructor(public readonly identifier: string) {}
}
export type BufferFormat<TEncodedShape> = (
	| FluidSerializableReadOnly
	| Shape<TEncodedShape>
	| IdentifierToken
	| BufferFormat<TEncodedShape>
)[];
export function updateShapesAndIdentifiersEncoding<TEncodedShape>(
	version: FieldBatchFormatVersion,
	buffer: BufferFormat<TEncodedShape>[],
	identifierFilter: CounterFilter<string> = jsonMinimizingFilter,
): EncodedFieldBatchGeneric<TEncodedShape> {
	const identifiers = new Counter<string>();
	const shapes = new Counter<Shape<TEncodedShape>>();
	const shapesSeen = new Set<Shape<TEncodedShape>>();
	const shapeToCount: Shape<TEncodedShape>[] = [];
	const shapeDiscovered = (shape: Shape<TEncodedShape>): void => {
		shapes.add(shape);
		if (!shapesSeen.has(shape)) {
			shapesSeen.add(shape);
			shapeToCount.push(shape);
		}
	};
	const arrays: BufferFormat<TEncodedShape>[] = [buffer];
	for (const array of arrays) {
		for (const item of array) {
			if (item instanceof IdentifierToken) {
				identifiers.add(item.identifier);
			} else if (item instanceof Shape) {
				shapeDiscovered(item);
			} else if (Array.isArray(item)) {
				arrays.push(item);
			} else if (
				item !== null &&
				typeof item === "object" &&
				(item as Record<string, unknown>).shape instanceof Shape
			) {
				fail(0xb4b  );
			}
		}
	}
	{
		let shape: Shape<TEncodedShape> | undefined;
		while ((shape = shapeToCount.pop()) !== undefined) {
			shape.countReferencedShapesAndIdentifiers(identifiers, shapeDiscovered);
		}
	}
	const identifierTable = identifiers.buildTable(identifierFilter);
	const shapeTable = shapes.buildTable();
	for (const array of arrays) {
		for (let index = 0; index < array.length; index++) {
			const item = array[index];
			if (item instanceof IdentifierToken) {
				array[index] = identifierTable.valueToIndex.get(item.identifier) ?? item.identifier;
			} else if (item instanceof Shape) {
				array[index] = shapeTable.valueToIndex.get(item) ?? fail(0xb4c  );
			}
		}
	}
	const encodedShapes = shapeTable.indexToValue.map((shape) =>
		shape.encodeShape(identifierTable, shapeTable),
	);
	return {
		version,
		identifiers: identifierTable.indexToValue as string[],
		shapes: encodedShapes,
		data: buffer as TreeValue[][],
	};
}
export abstract class Shape<TEncodedShape> {
	public abstract countReferencedShapesAndIdentifiers(
		identifiers: Counter<string>,
		shapeDiscovered: (shape: Shape<TEncodedShape>) => void,
	): void;
	public abstract encodeShape(
		identifiers: DeduplicationTable<string>,
		shapes: DeduplicationTable<Shape<TEncodedShape>>,
	): TEncodedShape;
}
```

### Decision procedure: `feature-libraries/chunked-forest/codec/compressedEncode.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/compressedEncode.ts:1-638`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function compressedEncode(
	fieldBatch: FieldBatch,
	context: EncoderContext,
): EncodedFieldBatchAnyVersion {
	const batchBuffer: BufferFormat[] = [];
	for (const cursor of fieldBatch) {
		const buffer: BufferFormat = [];
		anyFieldEncoder.encodeField(cursor, context, buffer);
		batchBuffer.push(buffer);
	}
	return updateShapesAndIdentifiersEncoding(context.version, batchBuffer);
}
export type BufferFormat = BufferFormatGeneric<EncodedChunkShape>;
export type Shape = ShapeGeneric<EncodedChunkShape>;
export interface KeyedFieldEncoder {
	readonly key: FieldKey;
	readonly encoder: FieldEncoder;
}
export interface Encoder {
	readonly shape: Shape;
}
export interface NodeEncoder extends Encoder {
	encodeNode(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat,
	): void;
}
export interface NodesEncoder extends Encoder {
	encodeNodes(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat,
	): void;
}
export interface FieldEncoder extends Encoder {
	encodeField(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat,
	): void;
}
export function asFieldEncoder(encoder: NodeEncoder): FieldEncoder {
	return {
		encodeField(
			cursor: ITreeCursorSynchronous,
			context: EncoderContext,
			outputBuffer: BufferFormat,
		): void {
			forEachNode(cursor, () => encoder.encodeNode(cursor, context, outputBuffer));
		},
		shape: encoder.shape,
	};
}
export function asNodesEncoder(encoder: NodeEncoder): NodesEncoder {
	return {
		encodeNodes(
			cursor: ITreeCursorSynchronous,
			context: EncoderContext,
			outputBuffer: BufferFormat,
		): void {
			encoder.encodeNode(cursor, context, outputBuffer);
			cursor.nextNode();
		},
		shape: encoder.shape,
	};
}
export class AnyShape extends ShapeGeneric<EncodedChunkShape> {
	private constructor() {
		super();
	}
	public static readonly instance = new AnyShape();
	public encodeShape(
		identifiers: DeduplicationTable<string>,
		shapes: DeduplicationTable<Shape>,
	): EncodedChunkShapeV1 {
		const encodedAnyShape: EncodedAnyShape = 0;
		return { d: encodedAnyShape };
	}
	public countReferencedShapesAndIdentifiers(
		identifiers: Counter<string>,
		shapeDiscovered: (shape: Shape) => void,
	): void {}
	public static encodeField(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat,
		encoder: FieldEncoder,
	): void {
		outputBuffer.push(encoder.shape);
		encoder.encodeField(cursor, context, outputBuffer);
	}
	public static encodeNode(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat,
		encoder: NodeEncoder,
	): void {
		outputBuffer.push(encoder.shape);
		encoder.encodeNode(cursor, context, outputBuffer);
	}
	public static encodeNodes(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat,
		encoder: NodesEncoder,
	): void {
		outputBuffer.push(encoder.shape);
		encoder.encodeNodes(cursor, context, outputBuffer);
	}
}
export const anyNodeEncoder: NodeEncoder = {
	encodeNode(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat,
	): void {
		const nodeEncoder = context.nodeEncoderFromSchema(cursor.type);
		AnyShape.encodeNode(cursor, context, outputBuffer, nodeEncoder);
	},
	shape: AnyShape.instance,
};
export const anyFieldEncoder: FieldEncoder = {
	encodeField(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat,
	): void {
		if (cursor.getFieldLength() === 0) {
			const shape = InlineArrayEncoder.empty;
			AnyShape.encodeField(cursor, context, outputBuffer, shape);
		} else if (cursor.getFieldLength() === 1) {
			cursor.enterNode(0);
			anyNodeEncoder.encodeNode(cursor, context, outputBuffer);
			cursor.exitNode();
		} else {
			const shape = context.nestedArrayEncoder(anyNodeEncoder);
			AnyShape.encodeField(cursor, context, outputBuffer, shape);
		}
	},
	shape: AnyShape.instance,
};
export class InlineArrayEncoder
	extends ShapeGeneric<EncodedChunkShape>
	implements NodesEncoder, FieldEncoder
{
	public static readonly empty: InlineArrayEncoder = new InlineArrayEncoder(0, {
		get shape() {
			return InlineArrayEncoder.empty;
		},
		encodeNodes(
			cursor: ITreeCursorSynchronous,
			context: EncoderContext,
			outputBuffer: BufferFormat,
		): void {
			fail(0xb4d  );
		},
	});
	public constructor(
		public readonly length: number,
		public readonly inner: NodesEncoder,
	) {
		super();
	}
	public encodeNodes(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat,
	): void {
		for (let index = 0; index < this.length; index++) {
			this.inner.encodeNodes(cursor, context, outputBuffer);
		}
	}
	public encodeField(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat,
	): void {
		assert(
			cursor.getFieldLength() >= this.length,
			0x73c  ,
		);
		cursor.firstNode();
		this.encodeNodes(cursor, context, outputBuffer);
		assert(
			cursor.mode === CursorLocationType.Fields,
			0x73d  ,
		);
	}
	public encodeShape(
		identifiers: DeduplicationTable<string>,
		shapes: DeduplicationTable<Shape>,
	): EncodedChunkShapeV1 {
		return {
			b: {
				length: this.length,
				shape: shapes.valueToIndex.get(this.inner.shape) ?? fail(0xb4e  ),
			},
		};
	}
	public countReferencedShapesAndIdentifiers(
		identifiers: Counter<string>,
		shapeDiscovered: (shape: Shape) => void,
	): void {
		shapeDiscovered(this.inner.shape);
	}
	public get shape(): this {
		return this;
	}
}
export class NestedArrayShape extends ShapeGeneric<EncodedChunkShape> {
	public constructor(public readonly innerShape: Shape) {
		super();
	}
	public encodeShape(
		identifiers: DeduplicationTable<string>,
		shapes: DeduplicationTable<Shape>,
	): EncodedChunkShape {
		const shape: EncodedNestedArrayShape =
			shapes.valueToIndex.get(this.innerShape) ??
			fail(0xb4f  );
		return {
			a: shape,
		};
	}
	public countReferencedShapesAndIdentifiers(
		identifiers: Counter<string>,
		shapeDiscovered: (shape: Shape) => void,
	): void {
		shapeDiscovered(this.innerShape);
	}
}
export class NestedArrayEncoder implements FieldEncoder {
	public constructor(
		public readonly innerEncoder: NodeEncoder,
		public readonly shape: NestedArrayShape = new NestedArrayShape(innerEncoder.shape),
	) {}
	public encodeField(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat,
	): void {
		const buffer: BufferFormat = [];
		let allNonZeroSize = true;
		const length = cursor.getFieldLength();
		forEachNode(cursor, () => {
			const before = buffer.length;
			this.innerEncoder.encodeNode(cursor, context, buffer);
			allNonZeroSize &&= buffer.length - before !== 0;
		});
		if (buffer.length === 0) {
			outputBuffer.push(length);
		} else {
			assert(
				allNonZeroSize,
				0x73e  ,
			);
			outputBuffer.push(buffer);
		}
	}
}
export class IncrementalChunkShape extends ShapeGeneric<EncodedChunkShape> {
	public encodeShape(
		identifiers: DeduplicationTable<string>,
		shapes: DeduplicationTable<Shape>,
	): EncodedChunkShape {
		return {
			e: 0  ,
		};
	}
	public countReferencedShapesAndIdentifiers(
		identifiers: Counter<string>,
		shapeDiscovered: (shape: Shape) => void,
	): void {}
	public get shape(): this {
		return this;
	}
}
export const incrementalFieldEncoder: FieldEncoder = {
	encodeField(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat,
	): void {
		assert(
			context.incrementalEncoder !== undefined,
			0xc88  ,
		);
		assert(
			supportsIncrementalEncoding(context.version),
			0xca1  ,
		);
		const chunkReferenceIds = context.incrementalEncoder.encodeIncrementalField(
			cursor,
			(chunk: TreeChunk) => compressedEncode([chunk.cursor()], context),
		);
		outputBuffer.push(chunkReferenceIds);
	},
	shape: new NestedArrayShape(new IncrementalChunkShape()  ),
};
export function encodeValue(
	value: Value,
	shape: EncodedValueShape,
	outputBuffer: BufferFormat,
): void {
	if (shape === undefined) {
		if (value === undefined) {
			outputBuffer.push(false);
		} else {
			outputBuffer.push(true, value);
		}
	} else {
		if (shape === true) {
			assert(value !== undefined, 0x78d  );
			outputBuffer.push(value);
		} else if (shape === false) {
			assert(value === undefined, 0x73f  );
		} else if (Array.isArray(shape)) {
			assert(shape.length === 1, 0x740  );
		} else if (shape === SpecialField.Identifier) {
			assert(value !== undefined, 0x998  );
			outputBuffer.push(value);
		} else {
			unreachableCase(shape, "Encoding values as deltas is not yet supported");
		}
	}
}
export class EncoderContext
	implements NodeEncodeBuilder, FieldEncodeBuilder, IdEncodingContext
{
	private readonly nodeEncodersFromSchema: Map<TreeNodeSchemaIdentifier, NodeEncoder> =
		new Map();
	private readonly nestedArrayEncoders: Map<NodeEncoder, NestedArrayEncoder> = new Map();
	public constructor(
		private readonly nodeEncoderFromPolicy: NodeEncoderPolicy,
		private readonly fieldEncoderFromPolicy: FieldEncoderPolicy,
		public readonly fieldShapes: ReadonlyMap<FieldKindIdentifier, FieldKindData>,
		private readonly idCompressor: IIdCompressor,
		public readonly incrementalEncoder: IncrementalEncoder | undefined,
		public readonly version: FieldBatchFormatVersion,
		public readonly isSummary: boolean,
	) {
		assert(
			isSummary || incrementalEncoder === undefined,
			0xd0d  ,
		);
	}
	public encodePossiblyCompressedId(id: string): string | EncodedId<EncodedIdType> {
		return encodePossiblyCompressedId(
			id,
			this.idCompressor,
			this.isSummary ? EncodedIdType.Originatorless : EncodedIdType.OriginatorDependent,
		);
	}
	public nodeEncoderFromSchema(schemaName: TreeNodeSchemaIdentifier): NodeEncoder {
		return getOrCreate(this.nodeEncodersFromSchema, schemaName, () =>
			this.nodeEncoderFromPolicy(this, schemaName),
		);
	}
	public fieldEncoderFromSchema(fieldSchema: TreeFieldStoredSchema): FieldEncoder {
		return new LazyFieldEncoder(this, fieldSchema, this.fieldEncoderFromPolicy);
	}
	public nestedArrayEncoder(inner: NodeEncoder): NestedArrayEncoder {
		return getOrCreate(this.nestedArrayEncoders, inner, () => new NestedArrayEncoder(inner));
	}
}
export interface NodeEncodeBuilder {
	nodeEncoderFromSchema(schemaName: TreeNodeSchemaIdentifier): NodeEncoder;
}
export interface FieldEncodeBuilder {
	fieldEncoderFromSchema(schema: TreeFieldStoredSchema): FieldEncoder;
}
export type FieldEncoderPolicy = (
	nodeBuilder: NodeEncodeBuilder,
	schema: TreeFieldStoredSchema,
) => FieldEncoder;
export type NodeEncoderPolicy = (
	fieldBuilder: FieldEncodeBuilder,
	schemaName: TreeNodeSchemaIdentifier,
) => NodeEncoder;
class LazyFieldEncoder implements FieldEncoder {
	private encoderLazy: FieldEncoder | undefined;
	public constructor(
		public readonly nodeBuilder: NodeEncodeBuilder,
		public readonly fieldSchema: TreeFieldStoredSchema,
		private readonly fieldEncoderFromPolicy: FieldEncoderPolicy,
	) {}
	public encodeField(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat,
	): void {
		this.encoder.encodeField(cursor, context, outputBuffer);
	}
	private get encoder(): FieldEncoder {
		if (this.encoderLazy === undefined) {
			this.encoderLazy = this.fieldEncoderFromPolicy(this.nodeBuilder, this.fieldSchema);
		}
		return this.encoderLazy;
	}
	public get shape(): Shape {
		return this.encoder.shape;
	}
}
```

### Decision procedure: `feature-libraries/chunked-forest/codec/fieldBatch.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/fieldBatch.ts:1-12`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type FieldBatch = readonly ITreeCursorSynchronous[];
```

### Decision procedure: `feature-libraries/chunked-forest/codec/incrementalEncodingPolicy.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/incrementalEncodingPolicy.ts:1-40`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type IncrementalEncodingPolicy = (
	nodeIdentifier: string | undefined,
	fieldKey?: string,
) => boolean;
export const defaultIncrementalEncodingPolicy: IncrementalEncodingPolicy = (
	nodeIdentifier: string | undefined,
	fieldKey?: string,
): boolean => {
	return false;
};
```

### Decision procedure: `feature-libraries/chunked-forest/codec/nodeEncoder.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/nodeEncoder.ts:1-294`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class NodeShapeBasedEncoder extends Shape<EncodedChunkShape> implements NodeEncoder {
	private readonly specializedFieldKeys: Set<FieldKey>;
	public constructor(
		public readonly type: undefined | TreeNodeSchemaIdentifier,
		public readonly value: EncodedValueShape,
		public readonly specializedFieldEncoders: readonly KeyedFieldEncoder[],
		public readonly otherFieldsEncoder: undefined | FieldEncoder,
	) {
		super();
		this.specializedFieldKeys = new Set(this.specializedFieldEncoders.map((f) => f.key));
	}
	private getValueToEncode(cursor: ITreeCursorSynchronous, context: EncoderContext): Value {
		if (this.value === SpecialField.Identifier) {
			assert(typeof cursor.value === "string", 0x9aa  );
			return context.encodePossiblyCompressedId(cursor.value);
		}
		return cursor.value;
	}
	public encodeNode(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat<EncodedChunkShape>,
	): void {
		if (this.type === undefined) {
			outputBuffer.push(new IdentifierToken(cursor.type));
		} else {
			assert(cursor.type === this.type, 0x741  );
		}
		encodeValue(this.getValueToEncode(cursor, context), this.value, outputBuffer);
		for (const fieldEncoder of this.specializedFieldEncoders) {
			cursor.enterField(brand(fieldEncoder.key));
			fieldEncoder.encoder.encodeField(cursor, context, outputBuffer);
			cursor.exitField();
		}
		const otherFieldsBuffer: BufferFormat<EncodedChunkShape> = [];
		forEachField(cursor, () => {
			const key = cursor.getFieldKey();
			if (!this.specializedFieldKeys.has(key)) {
				assert(
					this.otherFieldsEncoder !== undefined,
					0x742  ,
				);
				otherFieldsBuffer.push(new IdentifierToken(key));
				this.otherFieldsEncoder.encodeField(cursor, context, otherFieldsBuffer);
			}
		});
		if (this.otherFieldsEncoder !== undefined) {
			outputBuffer.push(otherFieldsBuffer);
		}
	}
	public encodeShape(
		identifiers: DeduplicationTable<string>,
		shapes: DeduplicationTable<Shape<EncodedChunkShape>>,
	): EncodedChunkShape {
		return {
			c: {
				type: encodeOptionalIdentifier(this.type, identifiers),
				value: this.value,
				fields: encodeFieldShapes(this.specializedFieldEncoders, identifiers, shapes),
				extraFields: encodeOptionalFieldShape(this.otherFieldsEncoder, shapes),
			},
		};
	}
	public countReferencedShapesAndIdentifiers(
		identifiers: Counter<string>,
		shapeDiscovered: (shape: Shape<EncodedChunkShape>) => void,
	): void {
		if (this.type !== undefined) {
			identifiers.add(this.type);
		}
		for (const fieldEncoder of this.specializedFieldEncoders) {
			identifiers.add(fieldEncoder.key);
			shapeDiscovered(fieldEncoder.encoder.shape);
		}
		if (this.otherFieldsEncoder !== undefined) {
			shapeDiscovered(this.otherFieldsEncoder.shape);
		}
	}
	public get shape(): Shape<EncodedChunkShape> {
		return this;
	}
}
export class SpecializedNodeShapeEncoder
	extends Shape<EncodedChunkShape>
	implements NodeEncoder
{
	private readonly inner: NodeShapeBasedEncoder;
	public constructor(
		private readonly base: NodeShapeBasedEncoder,
		private readonly fieldOverrides: readonly KeyedFieldEncoder[],
	) {
		super();
		const overrideMap = new Map(fieldOverrides.map((override) => [override.key, override]));
		assert(
			overrideMap.size === fieldOverrides.length,
			0xd7c  ,
		);
		const baseKeys = new Set(base.specializedFieldEncoders.map((field) => field.key));
		const mergedFields: KeyedFieldEncoder[] = base.specializedFieldEncoders.map(
			(baseField) => overrideMap.get(baseField.key) ?? baseField,
		);
		for (const override of fieldOverrides) {
			if (!baseKeys.has(override.key)) {
				mergedFields.push(override);
			}
		}
		this.inner = new NodeShapeBasedEncoder(
			base.type,
			base.value,
			mergedFields,
			base.otherFieldsEncoder,
		);
	}
	public encodeNode(
		cursor: ITreeCursorSynchronous,
		context: EncoderContext,
		outputBuffer: BufferFormat<EncodedChunkShape>,
	): void {
		assert(
			supportsSpecializedNodeShapes(context.version),
			0xd7d  ,
		);
		this.inner.encodeNode(cursor, context, outputBuffer);
	}
	public encodeShape(
		identifiers: DeduplicationTable<string>,
		shapes: DeduplicationTable<Shape<EncodedChunkShape>>,
	): EncodedChunkShapeVTextExperimental {
		const baseIndex =
			shapes.valueToIndex.get(this.base) ??
			fail(0xd7e  );
		return {
			f: {
				base: baseIndex,
				fields: encodeFieldShapes(this.fieldOverrides, identifiers, shapes),
			},
		};
	}
	public countReferencedShapesAndIdentifiers(
		identifiers: Counter<string>,
		shapeDiscovered: (shape: Shape<EncodedChunkShape>) => void,
	): void {
		shapeDiscovered(this.base);
		for (const override of this.fieldOverrides) {
			identifiers.add(override.key);
			shapeDiscovered(override.encoder.shape);
		}
	}
	public get shape(): this {
		return this;
	}
}
export function encodeFieldShapes(
	fieldEncoders: readonly KeyedFieldEncoder[],
	identifiers: DeduplicationTable<string>,
	shapes: DeduplicationTable<Shape<EncodedChunkShape>>,
): EncodedFieldShape[] | undefined {
	if (fieldEncoders.length === 0) {
		return undefined;
	}
	return fieldEncoders.map((fieldEncoder) => [
		encodeIdentifier(fieldEncoder.key, identifiers),
		shapes.valueToIndex.get(fieldEncoder.encoder.shape) ?? fail(0xb50  ),
	]);
}
function encodeIdentifier(
	identifier: string,
	identifiers: DeduplicationTable<string>,
): string | number {
	return identifiers.valueToIndex.get(identifier) ?? identifier;
}
function encodeOptionalIdentifier(
	identifier: string | undefined,
	identifiers: DeduplicationTable<string>,
): string | number | undefined {
	return identifier === undefined ? undefined : encodeIdentifier(identifier, identifiers);
}
function encodeOptionalFieldShape(
	encoder: FieldEncoder | undefined,
	shapes: DeduplicationTable<Shape<EncodedChunkShape>>,
): number | undefined {
	return encoder === undefined ? undefined : dedupShape(encoder.shape, shapes);
}
function dedupShape(
	shape: Shape<EncodedChunkShape>,
	shapes: DeduplicationTable<Shape<EncodedChunkShape>>,
): number {
	return shapes.valueToIndex.get(shape) ?? fail(0xb51  );
}
```

### Decision procedure: `feature-libraries/chunked-forest/codec/schemaBasedEncode.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/schemaBasedEncode.ts:1-289`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function schemaCompressedEncodeV1(
	schema: StoredSchemaCollection,
	policy: SchemaPolicy,
	fieldBatch: FieldBatch,
	idCompressor: IIdCompressor,
	_incrementalEncoder: IncrementalEncoder | undefined,
	isSummary: boolean,
): EncodedFieldBatchV1 {
	const encoded: EncodedFieldBatchAnyVersion = schemaCompressedEncode(
		schema,
		policy,
		fieldBatch,
		idCompressor,
		undefined  ,
		brand(FieldBatchFormatVersion.v1),
		isSummary,
	);
	return encoded as EncodedFieldBatchV1;
}
export function schemaCompressedEncodeV2(
	schema: StoredSchemaCollection,
	policy: SchemaPolicy,
	fieldBatch: FieldBatch,
	idCompressor: IIdCompressor,
	incrementalEncoder: IncrementalEncoder | undefined,
	isSummary: boolean,
): EncodedFieldBatchV2 {
	const encoded: EncodedFieldBatchAnyVersion = schemaCompressedEncode(
		schema,
		policy,
		fieldBatch,
		idCompressor,
		incrementalEncoder,
		brand(FieldBatchFormatVersion.v2),
		isSummary,
	);
	return encoded as EncodedFieldBatchV2;
}
function schemaCompressedEncode(
	schema: StoredSchemaCollection,
	policy: SchemaPolicy,
	fieldBatch: FieldBatch,
	idCompressor: IIdCompressor,
	incrementalEncoder: IncrementalEncoder | undefined,
	version: FieldBatchFormatVersion,
	isSummary: boolean,
): EncodedFieldBatchAnyVersion {
	return compressedEncode(
		fieldBatch,
		buildContext(schema, policy, idCompressor, incrementalEncoder, version, isSummary),
	);
}
export type SpecializedNodeEncoderPolicy = (
	base: NodeShapeBasedEncoder,
	schemaName: TreeNodeSchemaIdentifier,
	fieldBuilder: FieldEncodeBuilder,
) => NodeEncoder;
export const baseNodeEncoders: SpecializedNodeEncoderPolicy = (base) => base;
export function buildContext(
	storedSchema: StoredSchemaCollection,
	policy: SchemaPolicy,
	idCompressor: IIdCompressor,
	incrementalEncoder: IncrementalEncoder | undefined,
	version: FieldBatchFormatVersion,
	isSummary: boolean,
	nodeEncoderFor: SpecializedNodeEncoderPolicy = baseNodeEncoders,
): EncoderContext {
	const context: EncoderContext = new EncoderContext(
		(fieldBuilder: FieldEncodeBuilder, schemaName: TreeNodeSchemaIdentifier) =>
			nodeEncoderFor(
				getNodeEncoder(fieldBuilder, storedSchema, schemaName, incrementalEncoder),
				schemaName,
				fieldBuilder,
			),
		(nodeBuilder: NodeEncodeBuilder, fieldSchema: TreeFieldStoredSchema) =>
			getFieldEncoder(nodeBuilder, fieldSchema, context, storedSchema),
		policy.fieldKinds,
		idCompressor,
		incrementalEncoder,
		version,
		isSummary,
	);
	return context;
}
export function getFieldEncoder(
	nodeBuilder: NodeEncodeBuilder,
	field: TreeFieldStoredSchema,
	context: EncoderContext,
	storedSchema: StoredSchemaCollection,
): FieldEncoder {
	const kind = context.fieldShapes.get(field.kind) ?? fail(0xb52  );
	const type = oneFromIterable(field.types);
	const nodeEncoder =
		type === undefined ? anyNodeEncoder : nodeBuilder.nodeEncoderFromSchema(type);
	if (kind.multiplicity === Multiplicity.Single) {
		if (field.kind === identifierFieldKindIdentifier) {
			assert(type !== undefined, 0x999  );
			const nodeSchema = storedSchema.nodeSchema.get(type);
			assert(nodeSchema !== undefined, 0x99a  );
			assert(
				nodeSchema instanceof LeafNodeStoredSchema,
				0x99b  ,
			);
			assert(
				nodeSchema.leafValue === ValueSchema.String,
				0x99c  ,
			);
			const identifierNodeEncoder = new NodeShapeBasedEncoder(
				type,
				SpecialField.Identifier,
				[],
				undefined,
			);
			return asFieldEncoder(identifierNodeEncoder);
		}
		return asFieldEncoder(nodeEncoder);
	} else {
		return context.nestedArrayEncoder(nodeEncoder);
	}
}
export function getNodeEncoder(
	fieldBuilder: FieldEncodeBuilder,
	storedSchema: StoredSchemaCollection,
	schemaName: TreeNodeSchemaIdentifier,
	incrementalEncoder?: IncrementalEncoder,
): NodeShapeBasedEncoder {
	const shouldEncodeIncrementally =
		incrementalEncoder?.shouldEncodeIncrementally ?? defaultIncrementalEncodingPolicy;
	const schema =
		storedSchema.nodeSchema.get(schemaName) ?? fail(0xb53  );
	if (schema instanceof ObjectNodeStoredSchema) {
		const objectNodeFields: KeyedFieldEncoder[] = [];
		for (const [key, field] of schema.objectNodeFields ?? []) {
			const fieldEncoder = shouldEncodeIncrementally(schemaName, key)
				? incrementalFieldEncoder
				: fieldBuilder.fieldEncoderFromSchema(field);
			objectNodeFields.push({
				key,
				encoder: fieldEncoder,
			});
		}
		const shape = new NodeShapeBasedEncoder(schemaName, false, objectNodeFields, undefined);
		return shape;
	}
	if (schema instanceof LeafNodeStoredSchema) {
		const shape = new NodeShapeBasedEncoder(
			schemaName,
			valueShapeFromSchema(schema.leafValue),
			[],
			undefined,
		);
		return shape;
	}
	if (schema instanceof MapNodeStoredSchema) {
		const fieldEncoder = shouldEncodeIncrementally(schemaName)
			? incrementalFieldEncoder
			: fieldBuilder.fieldEncoderFromSchema(schema.mapFields);
		const shape = new NodeShapeBasedEncoder(schemaName, false, [], fieldEncoder);
		return shape;
	}
	fail(0xb54  );
}
function valueShapeFromSchema(schema: ValueSchema | undefined): undefined | EncodedValueShape {
	switch (schema) {
		case undefined: {
			return false;
		}
		case ValueSchema.Number:
		case ValueSchema.String:
		case ValueSchema.Boolean:
		case ValueSchema.FluidHandle: {
			return true;
		}
		case ValueSchema.Null: {
			return [null];
		}
		default: {
			unreachableCase(schema);
		}
	}
}
```

### Decision procedure: `feature-libraries/chunked-forest/codec/schemaBasedEncodeVText.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/schemaBasedEncodeVText.ts:1-88`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type SpecializationStrategy = (
	fieldBatch: FieldBatch,
	schema: StoredSchemaCollection,
	policy: SchemaPolicy,
) => SpecializedNodeEncoderPolicy;
export const noSpecialization: SpecializationStrategy = () => baseNodeEncoders;
export function schemaCompressedEncodeVTextExperimental(
	schema: StoredSchemaCollection,
	policy: SchemaPolicy,
	fieldBatch: FieldBatch,
	idCompressor: IIdCompressor,
	incrementalEncoder: IncrementalEncoder | undefined,
	isSummary: boolean,
	strategy: SpecializationStrategy = noSpecialization,
): EncodedFieldBatchVTextExperimental {
	return compressedEncode(
		fieldBatch,
		buildContext(
			schema,
			policy,
			idCompressor,
			incrementalEncoder,
			brand(FieldBatchFormatVersion.vTextExperimental),
			isSummary,
			strategy(fieldBatch, schema, policy),
		),
	);
}
```

### Decision procedure: `feature-libraries/chunked-forest/codec/uncompressedEncode.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/uncompressedEncode.ts:1-107`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function uncompressedEncodeV1(batch: FieldBatch): EncodedFieldBatchV1 {
	return uncompressedEncode(batch, brand(FieldBatchFormatVersion.v1));
}
export function uncompressedEncodeV2(batch: FieldBatch): EncodedFieldBatchV2 {
	return uncompressedEncode(batch, brand(FieldBatchFormatVersion.v2));
}
export function uncompressedEncodeVTextExperimental(
	batch: FieldBatch,
): EncodedFieldBatchVTextExperimental {
	return uncompressedEncode(batch, brand(FieldBatchFormatVersion.vTextExperimental));
}
function uncompressedEncode(
	batch: FieldBatch,
	version: FieldBatchFormatVersion,
): EncodedFieldBatchV1AndV2 {
	const rootFields = batch.map(encodeSequence);
	return {
		version,
		identifiers: [],
		shapes: [{ c: anyNodeShape }, { a: anyArray }],
		data: rootFields.map((data) => [arrayIndex, data]),
	};
}
const treeIndex: ShapeIndex = 0;
const arrayIndex: ShapeIndex = 1;
const anyNodeShape: EncodedNodeShape = {
	extraFields: arrayIndex,
};
const anyArray: EncodedNestedArrayShape = treeIndex;
function encodeSequence(cursor: ITreeCursorSynchronous): FluidSerializableReadOnly[] {
	const data: FluidSerializableReadOnly[] = [];
	forEachNode(cursor, () => {
		data.push(cursor.type);
		const value = cursor.value;
		data.push(value !== undefined);
		if (value !== undefined) {
			data.push(value);
		}
		const local: FluidSerializableReadOnly[] = [];
		forEachField(cursor, () => {
			const key = cursor.getFieldKey();
			local.push(key, encodeSequence(cursor));
		});
		data.push(local);
	});
	return data;
}
```

### Decision procedure: `feature-libraries/chunked-forest/codec/format/versions.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/format/versions.ts:1-150`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type FieldBatchFormatVersion = Values<typeof FieldBatchFormatVersion>;
export const FieldBatchFormatVersion = strictEnum("FieldBatchFormatVersion", {
	v1: 1,
	v2: 2,
	vTextExperimental: "text",
});
export function supportsIncrementalEncoding(version: FieldBatchFormatVersion): boolean {
	if (version === FieldBatchFormatVersion.v1) {
		return false;
	}
	return true;
}
export function supportsSpecializedNodeShapes(version: FieldBatchFormatVersion): boolean {
	if (version === FieldBatchFormatVersion.v1 || version === FieldBatchFormatVersion.v2) {
		return false;
	}
	return true;
}
export type EncodedFieldBatchV1 = Static<typeof EncodedFieldBatchV1>;
export const EncodedFieldBatchV1 = EncodedFieldBatchGeneric(
	FieldBatchFormatVersion.v1,
	EncodedChunkShapeV1,
);
export type EncodedFieldBatchV2 = Static<typeof EncodedFieldBatchV2>;
export const EncodedFieldBatchV2 = EncodedFieldBatchGeneric(
	FieldBatchFormatVersion.v2,
	EncodedChunkShapeV2,
);
export type EncodedFieldBatchVTextExperimental = Static<
	typeof EncodedFieldBatchVTextExperimental
>;
export const EncodedFieldBatchVTextExperimental = EncodedFieldBatchGeneric(
	FieldBatchFormatVersion.vTextExperimental,
	EncodedChunkShapeVTextExperimental,
);
export type EncodedFieldBatchAnyVersion =
	| EncodedFieldBatchV1
	| EncodedFieldBatchV2
	| EncodedFieldBatchVTextExperimental;
export type EncodedFieldBatchV1AndV2 = EncodedFieldBatchV1 & EncodedFieldBatchV2;
export type EncodedChunkShape =
	| EncodedChunkShapeV1
	| EncodedChunkShapeV2
	| EncodedChunkShapeVTextExperimental;
```

## 5. Invariants and asserts

0x76a visitor exclusivity, 0x76b double-free; 0xd1e destroy exact field length; 0xd22 attach consumes entire source; 0xd23 insertion in bounds; 0xd27 detach destination new/empty. 0x8a3 input cursor field mode; 0xca0 incremental version capability; 0xd0c incremental context originatorless. Specialized shapes: 0xcfb cycles, 0xcfc out-of-bounds base, 0xcfd wrong base kind, 0xcfe/0xcff duplicate keys. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/chunkedForest.ts:235` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/codecs.ts:207` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkDecoding.ts:93`

## 6. JS-semantics hazards

Distinguish Bool from numeric zero in shape/value unions (Swift bridging NSNumber is dangerous). Distinguish undefined/null in f overrides and tree leaves. Preserve fixed-field order and dictionary discovery/count tie order; never sort identifiers for convenience. Chunk reference identity drives incremental reuse, so deep value equality is insufficient. Retain/release is explicit in TS even under GC; Swift ARC alone does not implement the chunk COW ownership protocol. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkDecoding.ts:243` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/codec/chunkEncodingGeneric.ts:53` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/chunked-forest/chunkedForest.ts:205`

## 7. Test assets to reuse

Reuse chunked-forest unit/codec tests, schema-compressed and schemaless snapshots, and text shape codec cases. Cross-check all 1/2/text formats and compressed/uncompressed strategies with handles, null/absent values, repeated constant-shaped empty-data nodes, unknown identifiers, and incremental child chunks. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/feature-libraries/chunked-forest/chunkedForest.spec.ts:1`

## 8. Open questions

None about format registrations. Experimental text semantic API is companion scope, but its field-batch codec is included here because 3.11.0 registers the reader.

