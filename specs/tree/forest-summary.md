# Forest Summary — Fluid Framework 3.11.0

## 1. Role

ForestSummarizer stores all forest detached fields (including visible document root field) and supports immutable-chunk incremental summary reuse. It is separate from edit-history and detached-index summaries. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/forestSummarizer.ts:70`

## 2. Surface used by other packages

ForestSummarizer, forestCodecBuilder/FieldSet, ForestIncrementalSummaryBuilder, summary layout version/key helpers. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/index.ts:6`

## 3. Wire and persisted formats

Payload versions Forest 1 baseline, 2 at minimum 2.74; same outer shape emitted `{keys,fields,version}`: keys ordered FieldKey array; fields FieldBatch encoding of corresponding cursors. Lengths must match. Embedded FieldBatch version selected independently (1/2/text). `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/codec.ts:36`

Component key is Forest; layout accepts missing metadata, v1, v2, v3. Writer layout2 baseline, layout3 at minimum2.74. Layout1/2 root blob `ForestTree`; layout3 root blob `contents`. `.metadata` contains `{version:layoutVersion}`. Layout3 optionally has numeric chunk-reference-named child subtrees, each with `contents` blob containing FieldBatch (not Forest payload) plus more numeric child trees. Handle paths point into acknowledged prior summary; IDs are incremental chunk references, not detached-root IDs. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryFormatCommon.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryTypes.ts:21` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryFormatV1ToV2.ts:11` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryFormatV3.ts:18` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/incrementalSummaryBuilder.ts:419`


### Decision procedure: `feature-libraries/forest-summary/codec.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/codec.ts:1-89`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type FieldSet = ReadonlyMap<FieldKey, ITreeCursorSynchronous>;
export type ForestCodec = VersionDispatchingCodec<
	FieldSet,
	FieldBatchEncodingContext,
	ForestFormatVersion,
	FieldBatchDecodingContext
>;
function makeForestSummarizerCodec(
	options: CodecWriteOptions,
	version: ForestFormatVersion,
): CodecAndSchema<FieldSet, FieldBatchEncodingContext, FieldBatchDecodingContext> {
	const fieldBatchCodec = fieldBatchCodecBuilder.build(options);
	const formatSchema = FormatCommon;
	return {
		encode: (data: FieldSet, context: FieldBatchEncodingContext): FormatCommon => {
			const keys: FieldKey[] = [];
			const fields: ITreeCursorSynchronous[] = [];
			for (const [key, value] of data) {
				keys.push(key);
				fields.push(value);
			}
			return {
				keys,
				fields: fieldBatchCodec.encode(fields, context),
				version,
			};
		},
		decode: (data: FormatCommon, context: FieldBatchDecodingContext): FieldSet => {
			const out: Map<FieldKey, ITreeCursorSynchronous> = new Map();
			const fields = fieldBatchCodec.decode(data.fields, context);
			assert(data.keys.length === fields.length, 0x891  );
			for (const [index, field] of fields.entries()) {
				out.set(data.keys[index] ?? oob(), field);
			}
			return out;
		},
		schema: formatSchema,
	};
}
export const forestCodecBuilder = VersionDispatchingCodecBuilder.build("Forest", [
	{
		minVersionForCollab: lowestMinVersionForCollab,
		formatVersion: ForestFormatVersion.v1,
		codec: (options: CodecWriteOptions) =>
			makeForestSummarizerCodec(options, ForestFormatVersion.v1),
	},
	{
		minVersionForCollab: FluidClientVersion.v2_74,
		formatVersion: ForestFormatVersion.v2,
		codec: (options: CodecWriteOptions) =>
			makeForestSummarizerCodec(options, ForestFormatVersion.v2),
	},
]);
```

### Decision procedure: `feature-libraries/forest-summary/formatCommon.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/formatCommon.ts:1-34`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const ForestFormatVersion = strictEnum("ForestFormatVersion", {
	v1: 1,
	v2: 2,
});
export type ForestFormatVersion = Values<typeof ForestFormatVersion>;
export const FormatCommon = Type.Object(
	{
		...versionField,
		keys: Type.Array(schemaFormatV1.FieldKeySchema),
		fields: JsonCompatibleReadOnlySchema,
	},
	{ additionalProperties: false },
);
export type FormatCommon = Static<typeof FormatCommon>;
```

### Decision procedure: `feature-libraries/forest-summary/summaryFormatCommon.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryFormatCommon.ts:1-41`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const forestSummaryKey = "Forest";
export enum ForestSummaryFormatVersion {
	v1 = 1,
	v2 = 2,
	v3 = 3,
	vLatest = v3,
}
export const supportedForestSummaryFormatVersions = new Set<ForestSummaryFormatVersion>([
	ForestSummaryFormatVersion.v1,
	ForestSummaryFormatVersion.v2,
	ForestSummaryFormatVersion.v3,
]);
```

### Decision procedure: `feature-libraries/forest-summary/summaryFormatV1ToV2.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryFormatV1ToV2.ts:1-11`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const summaryContentBlobKey = "ForestTree";
```

### Decision procedure: `feature-libraries/forest-summary/summaryFormatV3.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryFormatV3.ts:1-18`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const summaryContentBlobKey = "contents";
```

### Decision procedure: `feature-libraries/forest-summary/summaryTypes.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryTypes.ts:1-42`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function minVersionToForestSummaryFormatVersion(
	version: OldestSupportedClientVersion,
): ForestSummaryFormatVersion {
	return getConfigForMinVersionForCollab(version, {
		[lowestMinVersionForCollab]: ForestSummaryFormatVersion.v2,
		[FluidClientVersion.v2_74]: ForestSummaryFormatVersion.v3,
	});
}
export function getForestRootSummaryContentKey(
	summaryFormatVersion: ForestSummaryFormatVersion | undefined,
): string {
	return summaryFormatVersion === undefined ||
		summaryFormatVersion < ForestSummaryFormatVersion.v3
		? summaryContentBlobKeyV1ToV2
		: summaryContentBlobKeyV3;
}
```

### Literal payload and layout examples

An empty forest under baseline writers emits ForestTree blob `{"keys":[],"fields":{"version":1,"identifiers":[],"shapes":[{"c":{"extraFields":1}},{"a":0}],"data":[]},"version":1}` alongside `.metadata` blob `{"version":2}`. At min 2.74 with Uncompressed strategy, `contents` instead contains `{"keys":[],"fields":{"version":2,"identifiers":[],"shapes":[{"c":{"extraFields":1}},{"a":0}],"data":[]},"version":2}` and `.metadata` is `{"version":3}`. FieldBatch version follows its own writer choice; a safe older override can therefore coexist with Forest payload 2. Numeric child subtree `4/contents`, for example, contains one FieldBatch, without keys or Forest version. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/codec.ts:45-89` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/summaryTypes.ts:21-42` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/incrementalSummaryBuilder.ts:419-510`

## 4. Behavior

Enumerate all detached fields with root cursor; allocate positioned cursor for each; begin summary tracking; supply incrementalEncoder only for Incremental behavior; encode forest; free cursors; complete tracking writes root blob and child chunks/handles. Incremental enabled only layout>=3 AND strategy CompressedIncremental; incremental context still required at summary time. FullTree inhibits old handle reuse but still permits new chunk subtree encoding. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/forestSummarizer.ts:117` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/forestSummarizer.ts:138`

Incremental tracking keys by summary sequence and chunk OBJECT identity. Start selects latest successful/acknowledged summary tracking, not merely most recently generated snapshot. Existing chunk + !fullTree uses its reference ID and computes prior path by following parentReferenceId chain (do not cache a stale absolute path after ancestor re-encoding). New chunk allocates nextReferenceId, pushes path, changes parent builder, encodes child contents recursively, restores parent builder/path; record current summary parent reference. Complete carries unchanged descendant tracking forward and cleans old tracking. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/incrementalSummaryBuilder.ts:319` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/incrementalSummaryBuilder.ts:419` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/incrementalSummaryBuilder.ts:514`

Load: select root blob by layout; require it; recursively prefetch every incremental child `contents` into reference map if snapshot tree available; decode root using originatorless summary context with incremental decoder. Decode child chunks once and retain references as needed. For each decoded field chunk its contents, allocate temporary minor build IDs, build all trees, then attach through applyDelta into empty forest with temporary detached index `init`. Persistent detached identity mapping is loaded by its own component. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/forestSummarizer.ts:193` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/incrementalSummaryBuilder.ts:263`

Exact summary tracking and chunk identity reuse implementation follows, because incorrect acknowledgment or parent-path handling corrupts subsequent summary handles.

### Algorithm notation and completeness

The following decision procedures are part of this specification, not external reading assignments. They preserve exact predicates, allocation order, collection traversal, return shapes and synchronous event calls. `undefined` means absent; `null` is a value; object spread is right-biased; `delete` removes a property; `Map`/`Set` iterate in insertion order. TypeBox `Optional(T)` permits absence, not null; tuples are fixed-order JSON arrays; singleton discriminated unions have exactly one case property. Assertions stop execution at the displayed short code. Helpers in another area use that area's same-named procedure; generic collection utilities retain JavaScript order. These are reference algorithms to translate into Swift, not a proposal to embed TypeScript in the client.

### Decision procedure: `feature-libraries/forest-summary/forestSummarizer.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/forestSummarizer.ts:1-256`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class ForestSummarizer
	extends VersionedSummarizer<ForestSummaryFormatVersion>
	implements Summarizable
{
	private readonly codec: ForestCodec;
	public get breaker(): Breakable {
		return this.forest.breaker;
	}
	private readonly incrementalSummaryBuilder: ForestIncrementalSummaryBuilder;
	private readonly forestRootSummaryContentKey: string;
	public constructor(
		private readonly forest: IEditableForest,
		private readonly encoderContext: FieldBatchEncodingContext,
		private readonly decoderContext: FieldBatchDecodingContext,
		options: CodecWriteOptions,
		private readonly idCompressor: IIdCompressor,
		initialSequenceNumber: number,
		shouldEncodeIncrementally: IncrementalEncodingPolicy = defaultIncrementalEncodingPolicy,
	) {
		super(
			forestSummaryKey,
			minVersionToForestSummaryFormatVersion(options.minVersionForCollab),
			supportedForestSummaryFormatVersions,
			true  ,
		);
		this.codec = forestCodecBuilder.build(options);
		const summaryFormatWriteVersion = minVersionToForestSummaryFormatVersion(
			options.minVersionForCollab,
		);
		this.forestRootSummaryContentKey = getForestRootSummaryContentKey(
			summaryFormatWriteVersion,
		);
		const enableIncrementalSummary =
			summaryFormatWriteVersion >= ForestSummaryFormatVersion.v3 &&
			encoderContext.encodeType === TreeCompressionStrategy.CompressedIncremental;
		this.incrementalSummaryBuilder = new ForestIncrementalSummaryBuilder(
			enableIncrementalSummary,
			(cursor: ITreeCursorSynchronous) => this.forest.chunkField(cursor),
			shouldEncodeIncrementally,
			initialSequenceNumber,
		);
	}
	protected summarizeInternal(props: {
		stringify: SummaryElementStringifier;
		fullTree?: boolean;
		trackState?: boolean;
		telemetryContext?: ITelemetryContext;
		incrementalSummaryContext?: IExperimentalIncrementalSummaryContext;
		builder: SummaryTreeBuilder;
	}): void {
		const { stringify, fullTree = false, incrementalSummaryContext, builder } = props;
		const rootCursor = this.forest.getCursorAboveDetachedFields();
		const fieldMap: Map<FieldKey, ITreeCursorSynchronous & ITreeSubscriptionCursor> =
			new Map();
		forEachField(rootCursor, (cursor) => {
			const key = cursor.getFieldKey();
			const innerCursor = this.forest.allocateCursor("getTreeString");
			assert(
				this.forest.tryMoveCursorToField({ fieldKey: key, parent: undefined }, innerCursor) ===
					TreeNavigationResult.Ok,
				0x892  ,
			);
			fieldMap.set(key, innerCursor as ITreeCursorSynchronous & ITreeSubscriptionCursor);
		});
		const incrementalSummaryBehavior = this.incrementalSummaryBuilder.startSummary({
			fullTree,
			incrementalSummaryContext,
			stringify,
			builder,
		});
		const encoderContext: FieldBatchEncodingContext = {
			...this.encoderContext,
			incrementalEncoder:
				incrementalSummaryBehavior === ForestIncrementalSummaryBehavior.Incremental
					? this.incrementalSummaryBuilder
					: undefined,
		};
		const encoded = this.codec.encode(fieldMap, encoderContext);
		for (const value of fieldMap.values()) {
			value.free();
		}
		this.incrementalSummaryBuilder.completeSummary({
			incrementalSummaryContext,
			forestSummaryRootContent: stringify(encoded),
			forestSummaryRootContentKey: this.forestRootSummaryContentKey,
			builder,
		});
	}
	@breakingMethod
	protected async loadInternal(
		services: IChannelStorageService,
		parse: SummaryElementParser,
		version: ForestSummaryFormatVersion | undefined,
	): Promise<void> {
		const forestSummaryRootContentKey = getForestRootSummaryContentKey(version);
		assert(
			await services.contains(forestSummaryRootContentKey),
			0xc21  ,
		);
		await this.incrementalSummaryBuilder.load({
			services,
			readAndParseChunk: async (chunkBlobPath: string) =>
				readAndParseSnapshotBlob(chunkBlobPath, services, parse),
		});
		const fields = this.codec.decode(
			(await readAndParseSnapshotBlob(
				forestSummaryRootContentKey,
				services,
				parse,
			)) as JsonCompatibleReadOnly,
			this.decoderContext.withIncrementalDecoder(this.incrementalSummaryBuilder),
		);
		const allocator = idAllocatorFromMaxId();
		const fieldChanges: [FieldKey, DeltaFieldChanges][] = [];
		const build: DeltaDetachedNodeBuild[] = [];
		for (const [fieldKey, field] of fields) {
			const chunked = chunkFieldSingle(field, {
				policy: defaultChunkPolicy,
				idCompressor: this.idCompressor,
			});
			const buildId = { minor: allocator.allocate(chunked.topLevelLength) };
			build.push({
				id: buildId,
				trees: chunked,
			});
			fieldChanges.push([
				fieldKey,
				{ marks: [{ count: chunked.topLevelLength, attach: buildId }] },
			]);
		}
		assert(this.forest.isEmpty, 0x797  );
		applyDelta(
			{ build, fields: new Map(fieldChanges) },
			undefined,
			this.forest,
			makeDetachedFieldIndex("init"),
		);
	}
}
```

### Decision procedure: `feature-libraries/forest-summary/incrementalSummaryBuilder.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/incrementalSummaryBuilder.ts:1-590`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
interface ChunkLoadProperties {
	readonly encodedContents: EncodedFieldBatchAnyVersion;
	readonly parentReferenceId: ChunkReferenceId | undefined;
}
interface ChunkSummaryProperties {
	readonly referenceId: ChunkReferenceId;
	readonly parentReferenceId: ChunkReferenceId | undefined;
}
interface TrackedSummaryProperties {
	readonly summarySequenceNumber: number;
	readonly latestSummaryBasePath: string;
	readonly fullTree: boolean;
	readonly chunkSummaryPath: ChunkReferenceId[];
	parentSummaryBuilder: SummaryTreeBuilder;
	stringify: SummaryElementStringifier;
	readonly latestSummaryRefIdMap: Map<ChunkReferenceId, ChunkSummaryProperties>;
}
export enum ForestIncrementalSummaryBehavior {
	Incremental,
	SingleBlob,
}
export class ForestIncrementalSummaryBuilder implements IncrementalEncoderDecoder {
	private nextReferenceId: ChunkReferenceId = brand(0);
	private readonly chunkTrackingPropertiesMap: NestedMap<
		number,
		TreeChunk,
		ChunkSummaryProperties
	> = new Map();
	public get isSummarizing(): boolean {
		return this.trackedSummaryProperties !== undefined;
	}
	private latestSummarySequenceNumber: number = -1;
	private trackedSummaryProperties: TrackedSummaryProperties | undefined;
	private readonly loadedChunksMap: Map<string, ChunkLoadProperties> = new Map();
	public constructor(
		private readonly enableIncrementalSummary: boolean,
		private readonly getChunkAtCursor: (cursor: ITreeCursorSynchronous) => TreeChunk[],
		public readonly shouldEncodeIncrementally: IncrementalEncodingPolicy,
		private readonly initialSequenceNumber: number,
	) {}
	public async load(args: {
		services: IChannelStorageService;
		readAndParseChunk: (chunkBlobPath: string) => Promise<JsonCompatible<IFluidHandle>>;
	}): Promise<void> {
		const forestTree = args.services.getSnapshotTree?.();
		if (forestTree === undefined) {
			return;
		}
		const downloadChunkContentsInTree = async (
			snapshotTree: ISnapshotTree,
			parentPathSegments: string[],
			parentReferenceId: ChunkReferenceId | undefined,
		): Promise<void> => {
			for (const [chunkReferenceId, chunkSnapshotTree] of Object.entries(snapshotTree.trees)) {
				const chunkSubTreeSegments = [...parentPathSegments, chunkReferenceId];
				const chunkSubTreePath = chunkSubTreeSegments.join("/");
				const chunkContentsPath = `${chunkSubTreePath}/${summaryContentBlobKey}`;
				if (!(await args.services.contains(chunkContentsPath))) {
					throw new LoggingError(
						`SharedTree: Cannot find contents for incremental chunk ${chunkContentsPath}`,
					);
				}
				const chunkContents = (await args.readAndParseChunk(
					chunkContentsPath,
				)) as EncodedFieldBatchAnyVersion;
				this.loadedChunksMap.set(chunkReferenceId, {
					encodedContents: chunkContents,
					parentReferenceId,
				});
				const chunkReferenceIdNumber = Number(chunkReferenceId);
				this.nextReferenceId = brand(
					Math.max(this.nextReferenceId, chunkReferenceIdNumber + 1),
				);
				await downloadChunkContentsInTree(
					chunkSnapshotTree,
					chunkSubTreeSegments,
					brand(chunkReferenceIdNumber),
				);
			}
		};
		await downloadChunkContentsInTree(forestTree, [], undefined  );
	}
	private requireTrackingSummary(): TrackedSummaryProperties {
		assert(this.trackedSummaryProperties !== undefined, 0xc22  );
		return this.trackedSummaryProperties;
	}
	public startSummary(args: {
		fullTree: boolean;
		incrementalSummaryContext: IExperimentalIncrementalSummaryContext | undefined;
		stringify: SummaryElementStringifier;
		builder: SummaryTreeBuilder;
	}): ForestIncrementalSummaryBehavior {
		assert(
			this.trackedSummaryProperties === undefined,
			0xc24  ,
		);
		const { fullTree, incrementalSummaryContext, stringify, builder } = args;
		if (!this.enableIncrementalSummary || incrementalSummaryContext === undefined) {
			return ForestIncrementalSummaryBehavior.SingleBlob;
		}
		this.latestSummarySequenceNumber = incrementalSummaryContext.latestSummarySequenceNumber;
		const latestSummaryRefIdMap: Map<ChunkReferenceId, ChunkSummaryProperties> = new Map();
		const latestTracking = this.chunkTrackingPropertiesMap.get(
			this.latestSummarySequenceNumber,
		);
		if (latestTracking !== undefined) {
			for (const properties of latestTracking.values()) {
				latestSummaryRefIdMap.set(properties.referenceId, properties);
			}
		}
		this.trackedSummaryProperties = {
			summarySequenceNumber: incrementalSummaryContext.summarySequenceNumber,
			latestSummaryBasePath: incrementalSummaryContext.summaryPath,
			chunkSummaryPath: [],
			parentSummaryBuilder: builder,
			fullTree,
			stringify,
			latestSummaryRefIdMap,
		};
		return ForestIncrementalSummaryBehavior.Incremental;
	}
	private computeHandlePathInLatestSummary(chunkProperties: ChunkSummaryProperties): string {
		const { latestSummaryRefIdMap } = this.requireTrackingSummary();
		const pathSegments: string[] = [];
		let current: ChunkSummaryProperties | undefined = chunkProperties;
		while (current !== undefined) {
			pathSegments.push(`${current.referenceId}`);
			if (current.parentReferenceId === undefined) {
				break;
			}
			current = latestSummaryRefIdMap.get(current.parentReferenceId);
			assert(
				current !== undefined,
				0xcf7  ,
			);
		}
		return pathSegments.reverse().join("/");
	}
	public encodeIncrementalField(
		cursor: ITreeCursorSynchronous,
		chunkEncoder: (chunk: TreeChunk) => EncodedFieldBatchAnyVersion,
	): ChunkReferenceId[] {
		const trackedSummaryProperties = this.requireTrackingSummary();
		const chunkReferenceIds: ChunkReferenceId[] = [];
		const chunks = this.getChunkAtCursor(cursor);
		for (const chunk of chunks) {
			const previousChunkProperties = tryGetFromNestedMap(
				this.chunkTrackingPropertiesMap,
				this.latestSummarySequenceNumber,
				chunk,
			);
			let chunkReferenceId: ChunkReferenceId;
			if (previousChunkProperties !== undefined && !trackedSummaryProperties.fullTree) {
				chunkReferenceId = previousChunkProperties.referenceId;
				const handlePath = this.computeHandlePathInLatestSummary(previousChunkProperties);
				trackedSummaryProperties.parentSummaryBuilder.addHandle(
					`${chunkReferenceId}`,
					SummaryType.Tree,
					`${trackedSummaryProperties.latestSummaryBasePath}/${handlePath}`,
				);
			} else {
				const newReferenceId: ChunkReferenceId = brand(this.nextReferenceId++);
				chunkReferenceId = newReferenceId;
				trackedSummaryProperties.chunkSummaryPath.push(newReferenceId);
				const parentSummaryBuilder = trackedSummaryProperties.parentSummaryBuilder;
				const chunkSummaryBuilder = new SummaryTreeBuilder();
				trackedSummaryProperties.parentSummaryBuilder = chunkSummaryBuilder;
				chunkSummaryBuilder.addBlob(
					summaryContentBlobKey,
					trackedSummaryProperties.stringify(chunkEncoder(chunk)),
				);
				parentSummaryBuilder.addWithStats(
					`${newReferenceId}`,
					chunkSummaryBuilder.getSummaryTree(),
				);
				trackedSummaryProperties.parentSummaryBuilder = parentSummaryBuilder;
				trackedSummaryProperties.chunkSummaryPath.pop();
			}
			const chunkSummaryPathLength = trackedSummaryProperties.chunkSummaryPath.length;
			const parentReferenceId: ChunkReferenceId | undefined =
				chunkSummaryPathLength > 0
					? trackedSummaryProperties.chunkSummaryPath[chunkSummaryPathLength - 1]
					: undefined;
			setInNestedMap(
				this.chunkTrackingPropertiesMap,
				trackedSummaryProperties.summarySequenceNumber,
				chunk,
				{ referenceId: chunkReferenceId, parentReferenceId },
			);
			chunkReferenceIds.push(chunkReferenceId);
		}
		return chunkReferenceIds;
	}
	public completeSummary(args: {
		incrementalSummaryContext: IExperimentalIncrementalSummaryContext | undefined;
		forestSummaryRootContent: string;
		forestSummaryRootContentKey: string;
		builder: SummaryTreeBuilder;
	}): void {
		const {
			incrementalSummaryContext,
			forestSummaryRootContent,
			forestSummaryRootContentKey,
			builder,
		} = args;
		if (!this.enableIncrementalSummary || incrementalSummaryContext === undefined) {
			builder.addBlob(forestSummaryRootContentKey, forestSummaryRootContent);
			return;
		}
		const trackedSummaryProperties = this.requireTrackingSummary();
		builder.addBlob(forestSummaryRootContentKey, forestSummaryRootContent);
		const latestSummaryTrackingMap = this.chunkTrackingPropertiesMap.get(
			this.latestSummarySequenceNumber,
		);
		const currentSummaryTrackingMap = this.chunkTrackingPropertiesMap.get(
			trackedSummaryProperties.summarySequenceNumber,
		);
		if (latestSummaryTrackingMap !== undefined && currentSummaryTrackingMap !== undefined) {
			for (const [chunk, chunkProperties] of latestSummaryTrackingMap.entries()) {
				if (!currentSummaryTrackingMap.has(chunk)) {
					currentSummaryTrackingMap.set(chunk, chunkProperties);
				}
			}
		}
		for (const sequenceNumber of this.chunkTrackingPropertiesMap.keys()) {
			if (sequenceNumber < this.latestSummarySequenceNumber) {
				this.chunkTrackingPropertiesMap.delete(sequenceNumber);
			}
		}
		this.trackedSummaryProperties = undefined;
	}
	public decodeIncrementalChunk(
		referenceId: ChunkReferenceId,
		chunkDecoder: (encoded: EncodedFieldBatchAnyVersion) => TreeChunk,
	): TreeChunk {
		const chunkLoadProperties = this.loadedChunksMap.get(`${referenceId}`);
		assert(chunkLoadProperties !== undefined, 0xc86  );
		const chunk = chunkDecoder(chunkLoadProperties.encodedContents);
		chunk.referenceAdded();
		setInNestedMap(this.chunkTrackingPropertiesMap, this.initialSequenceNumber, chunk, {
			referenceId,
			parentReferenceId: chunkLoadProperties.parentReferenceId,
		});
		return chunk;
	}
}
```

### Decision procedure: `feature-libraries/incrementalSummarizationUtils.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/incrementalSummarizationUtils.ts:1-20`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface CollabWindow {
	getCurrentSeq: () => number | undefined;
}
```

## 5. Invariants and asserts

0x891 keys/fields count equal; 0xc21 root blob must exist; 0x892 failed field navigation; 0x797 load forest must be empty. Missing incremental chunk contents throws LoggingError. Parent tracking must exist while reconstructing handles (0xcf7). `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/codec.ts:63` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/forestSummarizer.ts:204` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/incrementalSummaryBuilder.ts:287`

## 6. JS-semantics hazards

Map ordering maps keys to field indexes and changes bytes. Chunk cache keys use reference identity, not tree value equality. Numeric subtree names become JS Object.entries integer-key order on load. Summary contexts and reference IDs must remain separate from op originator contexts; await only at storage edges, not halfway through local delta apply. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/codec.ts:48` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/incrementalSummaryBuilder.ts:287` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/forestSummarizer.ts:229`

## 7. Test assets to reuse

Reuse forest-summary tests and incremental summary cases with reused children under re-encoded ancestors, failed/unacknowledged summaries, fullTree, missing chunk blobs, and layout1/2/3. Compare byte-exact blobs and handle paths, not just decoded tree. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/feature-libraries/forest-summary/forestSummarizer.spec.ts:1`

## 8. Open questions

None about formats. Snapshot storage may omit getSnapshotTree; incremental prefetch then returns without data, so actual incremental references still require a populated decoder cache rather than silently resolving to empty content. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/forest-summary/incrementalSummaryBuilder.ts:267`

