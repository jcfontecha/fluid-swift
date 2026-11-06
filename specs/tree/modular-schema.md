# Modular Schema — Fluid Framework 3.11.0

## 1. Role

ModularChangeFamily is the tree-wide change algebra and dispatcher over field kinds. It preserves cross-field moves, detached content and nested constraints, while field handlers decide local ordering. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:126`

## 2. Surface used by other packages

`ModularChangeFamily`, `ModularEditBuilder`, `ModularChangeset`, field/node IDs and change handlers; CrossFieldManager, CrossFieldTarget, FieldKindConfiguration/FlexFieldKind, atom alias/revision replacers, generic field kind, removed-root/refresher helpers. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/index.ts:6`

## 3. Wire and persisted formats

Modular family registers parent formats 3/4→codec V1 structure, 5→V2 structure. V1 JSON emitted order `{maxId?,revisions?,changes,builds?,refreshers?,violations?}`. `changes` array of `{fieldKey,fieldKind,change}` in field-map order. Nested `change` codec receives callbacks that inline node changes: `{fieldChanges?,nodeExistsConstraint?:{violated}}`. Node IDs, aliases, nodeToParent and crossFieldKeys are reconstructed, NOT transmitted. maxId marks original ID space; decoding allocates node IDs above it. Revision list entries `{revision,rollbackOf?}`; a single context revision may be omitted and is restored from decoding context. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeCodecs.ts:30` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeCodecV1.ts:139` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeCodecV1.ts:468`

`builds`/`refreshers` each `{builds,trees}`. builds is revision groups `[[[localId,treeIndex],...],encodedRevision?]`; `trees` is one FieldBatch, indexes address its fields. Missing group revision uses context revision. V2 structure adds optional `noChangeConstraint:{violated}` after all V1 members. Revert-only constraints and destroys are not emitted; attempting to encode destroys asserts 0x899. Field codec versions are selected by default-schema parent mapping, not by a field member. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFormatV1.ts:90` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeCodecV1.ts:292` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeCodecV2.ts:63`


### Decision procedure: `feature-libraries/modular-schema/genericFieldKindCodecs.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/genericFieldKindCodecs.ts:1-51`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function makeGenericChangeCodec(): ICodecFamily<
	GenericChangeset,
	FieldChangeEncodingContext,
	FieldChangeDecodingContext
> {
	return makeCodecFamily([[1, makeV1Codec()]]);
}
function makeV1Codec(): IJsonCodec<
	GenericChangeset,
	EncodedGenericChangeset,
	EncodedGenericChangeset,
	FieldChangeEncodingContext,
	FieldChangeDecodingContext
> {
	return {
		encode: (
			change: GenericChangeset,
			context: FieldChangeEncodingContext,
		): EncodedGenericChangeset => {
			const encoded: EncodedGenericChangeset = change
				.toArray()
				.map(([index, nodeChange]) => [index, context.encodeNode(nodeChange)]);
			return encoded;
		},
		decode: (
			encoded: EncodedGenericChangeset,
			context: FieldChangeDecodingContext,
		): GenericChangeset => {
			return newGenericChangeset(
				encoded.map(([index, nodeChange]) => [index, context.decodeNode(nodeChange)]),
			);
		},
		encodedSchema: EncodedGenericChangeset(EncodedNodeChangeset),
	};
}
```

### Decision procedure: `feature-libraries/modular-schema/genericFieldKindFormat.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/genericFieldKindFormat.ts:1-26`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const EncodedGenericChange = <NodeChangesetSchema extends TSchema>(
	tNodeChangeset: NodeChangesetSchema,
) => Type.Tuple([Type.Integer({ minimum: 0 }), tNodeChangeset]);
export type EncodedGenericChange<Schema extends TSchema = TAnySchema> = Static<
	ReturnType<typeof EncodedGenericChange<Schema>>
>;
export const EncodedGenericChangeset = <NodeChangesetSchema extends TSchema>(
	tNodeChangeset: NodeChangesetSchema,
) => Type.Array(EncodedGenericChange(tNodeChangeset));
export type EncodedGenericChangeset<Schema extends TSchema = TAnySchema> = Static<
	ReturnType<typeof EncodedGenericChangeset<Schema>>
>;
```

### Decision procedure: `feature-libraries/modular-schema/modularChangeCodecV1.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeCodecV1.ts:1-735`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
type ModularChangeCodec = IJsonCodec<
	ModularChangeset,
	EncodedModularChangesetV1,
	EncodedModularChangesetV1,
	ChangeEncodingContext,
	ChangeDecodingContext
>;
type FieldCodec = IJsonCodec<
	FieldChangeset,
	JsonCompatibleReadOnly,
	JsonCompatibleReadOnly,
	FieldChangeEncodingContext,
	FieldChangeDecodingContext
>;
type FieldChangesetCodecs = Map<
	FieldKindIdentifier,
	{
		compiledSchema?: SchemaValidationFunction<TAnySchema>;
		codec: FieldCodec;
	}
>;
export function getFieldChangesetCodec(
	fieldKind: FieldKindIdentifier,
	fieldChangesetCodecs: FieldChangesetCodecs,
): {
	compiledSchema?: SchemaValidationFunction<TAnySchema>;
	codec: FieldCodec;
} {
	const entry = fieldChangesetCodecs.get(fieldKind);
	assert(entry !== undefined, 0x5ea  );
	return entry;
}
export function encodeFieldChangesForJson(
	change: FieldChangeMap,
	context: ChangeEncodingContext,
	nodeChanges: ChangeAtomIdBTree<NodeChangeset>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
	fieldChangesetCodecs: FieldChangesetCodecs,
): EncodedFieldChangeMap {
	const fieldContext: FieldChangeEncodingContext = {
		baseContext: context,
		encodeNode: (nodeId: NodeId): EncodedNodeChangeset => {
			const node = nodeChangeFromId(nodeChanges, nodeId, nodeAliases);
			return encodeNodeChangesForJson(node, fieldContext, fieldChangesetCodecs);
		},
	};
	return encodeFieldChangesForJsonI(change, fieldContext, fieldChangesetCodecs);
}
export function encodeFieldChangesForJsonI(
	change: FieldChangeMap,
	context: FieldChangeEncodingContext,
	fieldChangesetCodecs: FieldChangesetCodecs,
): EncodedFieldChangeMap {
	const encodedFields: EncodedFieldChangeMap = [];
	for (const [field, fieldChange] of change) {
		const { codec, compiledSchema } = getFieldChangesetCodec(
			fieldChange.fieldKind,
			fieldChangesetCodecs,
		);
		const encodedChange = codec.encode(fieldChange.change, context);
		if (compiledSchema !== undefined && !compiledSchema.check(encodedChange)) {
			fail(0xb1f  );
		}
		const fieldKey: FieldKey = field;
		const encodedField: EncodedFieldChange = {
			fieldKey,
			fieldKind: fieldChange.fieldKind,
			change: encodedChange,
		};
		encodedFields.push(encodedField);
	}
	return encodedFields;
}
export function encodeNodeChangesForJson(
	change: NodeChangeset,
	context: FieldChangeEncodingContext,
	fieldChangesetCodecs: FieldChangesetCodecs,
): EncodedNodeChangeset {
	const encodedChange: EncodedNodeChangeset = {};
	const { fieldChanges, nodeExistsConstraint } = change;
	if (fieldChanges !== undefined) {
		encodedChange.fieldChanges = encodeFieldChangesForJsonI(
			fieldChanges,
			context,
			fieldChangesetCodecs,
		);
	}
	if (nodeExistsConstraint !== undefined) {
		encodedChange.nodeExistsConstraint = nodeExistsConstraint;
	}
	return encodedChange;
}
export function decodeFieldChangesFromJson(
	encodedChange: EncodedFieldChangeMap,
	parentId: NodeId | undefined,
	decoded: ModularChangeset,
	context: ChangeDecodingContext,
	idAllocator: IdAllocator,
	fieldKinds: FieldKindConfiguration,
	fieldChangesetCodecs: FieldChangesetCodecs,
): FieldChangeMap {
	const decodedFields: FieldChangeMap = new Map();
	for (const field of encodedChange) {
		const { codec, compiledSchema } = getFieldChangesetCodec(
			field.fieldKind,
			fieldChangesetCodecs,
		);
		if (compiledSchema !== undefined && !compiledSchema.check(field.change)) {
			fail(0xb20  );
		}
		const fieldId: FieldId = {
			nodeId: parentId,
			field: field.fieldKey,
		};
		const fieldContext: FieldChangeDecodingContext = {
			baseContext: context,
			decodeNode: (encodedNode: EncodedNodeChangeset): NodeId => {
				const nodeId: NodeId = {
					revision: context.revision,
					localId: brand(idAllocator.allocate()),
				};
				const node = decodeNodeChangesetFromJson(
					encodedNode,
					nodeId,
					decoded,
					context,
					idAllocator,
					fieldKinds,
					fieldChangesetCodecs,
				);
				decoded.nodeChanges.set([nodeId.revision, nodeId.localId], node);
				decoded.nodeToParent.set([nodeId.revision, nodeId.localId], fieldId);
				return nodeId;
			},
		};
		const fieldChangeset = codec.decode(field.change, fieldContext);
		const crossFieldKeys = getChangeHandler(fieldKinds, field.fieldKind).getCrossFieldKeys(
			fieldChangeset,
		);
		for (const { key, count } of crossFieldKeys) {
			decoded.crossFieldKeys.set(key, count, fieldId);
		}
		const fieldKey: FieldKey = brand<FieldKey>(field.fieldKey);
		decodedFields.set(fieldKey, {
			fieldKind: field.fieldKind,
			change: brand(fieldChangeset),
		});
	}
	return decodedFields;
}
export function decodeNodeChangesetFromJson(
	encodedChange: EncodedNodeChangeset,
	id: NodeId,
	decoded: ModularChangeset,
	context: ChangeDecodingContext,
	idAllocator: IdAllocator,
	fieldKinds: FieldKindConfiguration,
	fieldChangesetCodecs: FieldChangesetCodecs,
): NodeChangeset {
	const decodedChange: NodeChangeset = {};
	const { fieldChanges, nodeExistsConstraint } = encodedChange;
	if (fieldChanges !== undefined) {
		decodedChange.fieldChanges = decodeFieldChangesFromJson(
			fieldChanges,
			id,
			decoded,
			context,
			idAllocator,
			fieldKinds,
			fieldChangesetCodecs,
		);
	}
	if (nodeExistsConstraint !== undefined) {
		decodedChange.nodeExistsConstraint = nodeExistsConstraint;
	}
	return decodedChange;
}
export function encodeDetachedNodes(
	detachedNodes: ChangeAtomIdBTree<TreeChunk> | undefined,
	context: ChangeEncodingContext,
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
	fieldsCodec: FieldBatchCodec,
	chunkCompressionStrategy: TreeCompressionStrategy,
): EncodedBuilds | undefined {
	if (detachedNodes === undefined) {
		return undefined;
	}
	const treesToEncode: ITreeCursorSynchronous[] = [];
	const buildsArray: EncodedBuildsArray = [];
	let buildsForRevision:
		| [[ChangesetLocalId, number][], EncodedRevisionTag]
		| [[ChangesetLocalId, number][]]
		| undefined;
	for (const [[revision, id], chunk] of detachedNodes.entries()) {
		const encodedRevision = encodeRevisionOpt(revisionTagCodec, revision, context);
		if (buildsForRevision === undefined || buildsForRevision[1] !== encodedRevision) {
			if (buildsForRevision !== undefined) {
				buildsArray.push(buildsForRevision);
			}
			buildsForRevision = encodedRevision === undefined ? [[]] : [[], encodedRevision];
		}
		treesToEncode.push(chunk.cursor());
		const treeIndexInBatch = treesToEncode.length - 1;
		buildsForRevision?.[0].push([id, treeIndexInBatch]);
	}
	if (buildsForRevision !== undefined) {
		buildsArray.push(buildsForRevision);
	}
	return buildsArray.length === 0
		? undefined
		: {
				builds: buildsArray,
				trees: fieldsCodec.encode(treesToEncode, {
					encodeType: chunkCompressionStrategy,
					schema: context.schema,
					idCompressor: context.idCompressor,
					isSummary: context.isSummary,
				}),
			};
}
export function decodeDetachedNodes(
	encoded: EncodedBuilds | undefined,
	context: ChangeDecodingContext,
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
	fieldsCodec: FieldBatchCodec,
	chunkCompressionStrategy: TreeCompressionStrategy,
): ChangeAtomIdBTree<TreeChunk> | undefined {
	if (encoded === undefined || encoded.builds.length === 0) {
		return undefined;
	}
	const chunks = fieldsCodec.decode(
		encoded.trees,
		context.isSummary
			? FieldBatchDecodingContext.forSummary({
					idCompressor: context.idCompressor,
					healing: context.healing,
				})
			: FieldBatchDecodingContext.forOp({
					idCompressor: context.idCompressor,
					originatorId: context.originatorId,
				}),
	);
	const getChunk = (index: number): TreeChunk => {
		assert(index < chunks.length, 0x898  );
		return chunkFieldSingle(chunks[index] ?? oob(), {
			policy: defaultChunkPolicy,
			idCompressor: context.idCompressor,
		});
	};
	const map: ModularChangeset["builds"] = newChangeAtomIdBTree();
	encoded.builds.forEach((build) => {
		const revision =
			build[1] === undefined ? context.revision : revisionTagCodec.decode(build[1], context);
		const decodedChunks: [ChangesetLocalId, TreeChunk][] = build[0].map(([i, n]) => [
			i,
			getChunk(n),
		]);
		for (const [id, chunk] of decodedChunks) {
			map.set([revision, id], chunk);
		}
	});
	return map;
}
export function encodeRevisionInfos(
	revisions: readonly RevisionInfo[],
	context: ChangeEncodingContext,
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
): EncodedRevisionInfo[] | undefined {
	if (context.revision !== undefined) {
		assert(
			revisions.length === 1 &&
				revisions[0] !== undefined &&
				revisions[0].revision === context.revision &&
				revisions[0].rollbackOf === undefined,
			0x964  ,
		);
		return undefined;
	}
	const encodedRevisions = [];
	for (const revision of revisions) {
		const encodedRevision: Mutable<EncodedRevisionInfo> = {
			revision: revisionTagCodec.encode(revision.revision, context),
		};
		if (revision.rollbackOf !== undefined) {
			encodedRevision.rollbackOf = revisionTagCodec.encode(revision.rollbackOf, context);
		}
		encodedRevisions.push(encodedRevision);
	}
	return encodedRevisions;
}
export function decodeRevisionInfos(
	revisions: readonly EncodedRevisionInfo[] | undefined,
	context: ChangeDecodingContext,
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
): RevisionInfo[] | undefined {
	if (revisions === undefined) {
		return context.revision === undefined ? undefined : [{ revision: context.revision }];
	}
	const decodedRevisions = [];
	for (const revision of revisions) {
		const decodedRevision: Mutable<RevisionInfo> = {
			revision: revisionTagCodec.decode(revision.revision, context),
		};
		if (revision.rollbackOf !== undefined) {
			decodedRevision.rollbackOf = revisionTagCodec.decode(revision.rollbackOf, context);
		}
		decodedRevisions.push(decodedRevision);
	}
	return decodedRevisions;
}
export function encodeChange(
	change: ModularChangeset,
	context: ChangeEncodingContext,
	fieldChangesetCodecs: Map<
		FieldKindIdentifier,
		{
			compiledSchema?: SchemaValidationFunction<TAnySchema>;
			codec: FieldCodec;
		}
	>,
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
	fieldsCodec: FieldBatchCodec,
	chunkCompressionStrategy: TreeCompressionStrategy,
): EncodedModularChangesetV1 {
	assert(change.destroys === undefined, 0x899  );
	return {
		maxId: change.maxId,
		revisions:
			change.revisions === undefined
				? undefined
				: encodeRevisionInfos(change.revisions, context, revisionTagCodec),
		changes: encodeFieldChangesForJson(
			change.fieldChanges,
			context,
			change.nodeChanges,
			change.nodeAliases,
			fieldChangesetCodecs,
		),
		builds: encodeDetachedNodes(
			change.builds,
			context,
			revisionTagCodec,
			fieldsCodec,
			chunkCompressionStrategy,
		),
		refreshers: encodeDetachedNodes(
			change.refreshers,
			context,
			revisionTagCodec,
			fieldsCodec,
			chunkCompressionStrategy,
		),
		violations: change.constraintViolationCount,
	};
}
export function decodeChange(
	encodedChange: EncodedModularChangesetV1,
	context: ChangeDecodingContext,
	fieldKinds: FieldKindConfiguration,
	fieldChangesetCodecs: Map<
		FieldKindIdentifier,
		{
			compiledSchema?: SchemaValidationFunction<TAnySchema>;
			codec: FieldCodec;
		}
	>,
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
	fieldsCodec: FieldBatchCodec,
	chunkCompressionStrategy: TreeCompressionStrategy,
): Mutable<ModularChangeset> {
	const decoded: Mutable<ModularChangeset> = {
		fieldChanges: new Map(),
		nodeChanges: newChangeAtomIdBTree(),
		nodeToParent: newChangeAtomIdBTree(),
		nodeAliases: newChangeAtomIdBTree(),
		crossFieldKeys: newCrossFieldKeyTable(),
	};
	decoded.fieldChanges = decodeFieldChangesFromJson(
		encodedChange.changes,
		undefined,
		decoded,
		context,
		idAllocatorFromMaxId(encodedChange.maxId),
		fieldKinds,
		fieldChangesetCodecs,
	);
	if (encodedChange.builds !== undefined) {
		decoded.builds = decodeDetachedNodes(
			encodedChange.builds,
			context,
			revisionTagCodec,
			fieldsCodec,
			chunkCompressionStrategy,
		);
	}
	if (encodedChange.refreshers !== undefined) {
		decoded.refreshers = decodeDetachedNodes(
			encodedChange.refreshers,
			context,
			revisionTagCodec,
			fieldsCodec,
			chunkCompressionStrategy,
		);
	}
	if (encodedChange.violations !== undefined) {
		decoded.constraintViolationCount = encodedChange.violations;
	}
	const decodedRevInfos = decodeRevisionInfos(
		encodedChange.revisions,
		context,
		revisionTagCodec,
	);
	if (decodedRevInfos !== undefined) {
		decoded.revisions = decodedRevInfos;
	}
	if (encodedChange.maxId !== undefined) {
		decoded.maxId = encodedChange.maxId;
	}
	return decoded;
}
export function getFieldChangesetCodecs(
	fieldKinds: FieldKindConfiguration,
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
	codecOptions: ICodecOptions,
): Map<
	FieldKindIdentifier,
	{ compiledSchema?: SchemaValidationFunction<TAnySchema>; codec: FieldCodec }
> {
	const getMapEntry = ({ kind, formatVersion }: FieldKindConfigurationEntry) => {
		const codec = kind.changeHandler.codecsFactory(revisionTagCodec).resolve(formatVersion);
		return {
			codec,
			compiledSchema: codec.encodedSchema
				? extractJsonValidator(codecOptions.jsonValidator).compile(codec.encodedSchema)
				: undefined,
		};
	};
	const genericFieldKindFormatVersion = 1;
	const fieldChangesetCodecs: Map<
		FieldKindIdentifier,
		{
			compiledSchema?: SchemaValidationFunction<TAnySchema>;
			codec: FieldCodec;
		}
	> = new Map([
		[
			genericFieldKind.identifier,
			getMapEntry({ kind: genericFieldKind, formatVersion: genericFieldKindFormatVersion }),
		],
	]);
	fieldKinds.forEach((entry, identifier) => {
		fieldChangesetCodecs.set(identifier, getMapEntry(entry));
	});
	return fieldChangesetCodecs;
}
export function makeModularChangeCodecV1(
	fieldKinds: FieldKindConfiguration,
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
	fieldsCodec: FieldBatchCodec,
	codecOptions: ICodecOptions,
	chunkCompressionStrategy: TreeCompressionStrategy = TreeCompressionStrategy.Compressed,
): ModularChangeCodec {
	const fieldChangesetCodecs = getFieldChangesetCodecs(
		fieldKinds,
		revisionTagCodec,
		codecOptions,
	);
	const modularChangeCodec: ModularChangeCodec = {
		encode: (change, context) => {
			strictRebaseValidation("Malformed V1 encode input", () =>
				isChangesetValid(change, fieldKindsFromConfiguration(fieldKinds)),
			);
			const encoded = encodeChange(
				change,
				context,
				fieldChangesetCodecs,
				revisionTagCodec,
				fieldsCodec,
				chunkCompressionStrategy,
			);
			cheapRebaseValidation("V1 encode output", (): true | string => {
				const decoded = modularChangeCodec.decode(encoded, context);
				return (
					areEquivalent(change, decoded, fieldKindsFromConfiguration(fieldKinds)) ||
					"does not match decode output"
				);
			});
			return encoded;
		},
		decode: (encodedChange, context) => {
			const decoded = decodeChange(
				encodedChange,
				context,
				fieldKinds,
				fieldChangesetCodecs,
				revisionTagCodec,
				fieldsCodec,
				chunkCompressionStrategy,
			);
			cheapRebaseValidation("Malformed V1 decode output", () =>
				isChangesetValid(decoded, fieldKindsFromConfiguration(fieldKinds)),
			);
			return decoded;
		},
	};
	return withSchemaValidation(
		EncodedModularChangesetV1,
		modularChangeCodec,
		codecOptions.jsonValidator,
	);
}
function getChangeHandler(
	fieldKinds: FieldKindConfiguration,
	fieldKind: FieldKindIdentifier,
): FieldChangeHandler<unknown> {
	if (fieldKind === genericFieldKind.identifier) {
		return genericFieldKind.changeHandler;
	}
	const handler = fieldKinds.get(fieldKind)?.kind.changeHandler;
	assert(handler !== undefined, 0x9c1  );
	return handler;
}
function encodeRevisionOpt(
	revisionCodec: IJsonCodec<
		RevisionTag,
		EncodedRevisionTag,
		EncodedRevisionTag,
		ChangeEncodingContext
	>,
	revision: RevisionTag | undefined,
	context: ChangeEncodingContext,
): EncodedRevisionTag | undefined {
	if (revision === undefined) {
		return undefined;
	}
	return revision === context.revision ? undefined : revisionCodec.encode(revision, context);
}
```

### Decision procedure: `feature-libraries/modular-schema/modularChangeCodecV2.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeCodecV2.ts:1-111`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
type ModularChangeCodec = IJsonCodec<
	ModularChangeset,
	EncodedModularChangesetV2,
	EncodedModularChangesetV2,
	ChangeEncodingContext,
	ChangeDecodingContext
>;
export function makeModularChangeCodecV2(
	fieldKinds: FieldKindConfiguration,
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
	fieldsCodec: FieldBatchCodec,
	codecOptions: ICodecOptions,
	chunkCompressionStrategy: TreeCompressionStrategy = TreeCompressionStrategy.Compressed,
): ModularChangeCodec {
	const fieldChangesetCodecs = getFieldChangesetCodecs(
		fieldKinds,
		revisionTagCodec,
		codecOptions,
	);
	const modularChangeCodec: ModularChangeCodec = {
		encode: (change, context) => {
			strictRebaseValidation("Malformed V2 encode input", () =>
				isChangesetValid(change, fieldKindsFromConfiguration(fieldKinds)),
			);
			const encoded = encodeChange(
				change,
				context,
				fieldChangesetCodecs,
				revisionTagCodec,
				fieldsCodec,
				chunkCompressionStrategy,
			) as EncodedModularChangesetV2;
			encoded.noChangeConstraint = change.noChangeConstraint;
			cheapRebaseValidation("V2 encode output", (): true | string => {
				const decoded = modularChangeCodec.decode(encoded, context);
				return (
					areEquivalent(change, decoded, fieldKindsFromConfiguration(fieldKinds)) ||
					"does not match decode output"
				);
			});
			return encoded;
		},
		decode: (encodedChange: EncodedModularChangesetV2, context) => {
			const decoded = decodeChange(
				encodedChange,
				context,
				fieldKinds,
				fieldChangesetCodecs,
				revisionTagCodec,
				fieldsCodec,
				chunkCompressionStrategy,
			);
			if (encodedChange.noChangeConstraint !== undefined) {
				decoded.noChangeConstraint = encodedChange.noChangeConstraint;
			}
			cheapRebaseValidation("Malformed V2 decode output", () =>
				isChangesetValid(decoded, fieldKindsFromConfiguration(fieldKinds)),
			);
			return decoded;
		},
	};
	return withSchemaValidation(
		EncodedModularChangesetV2,
		modularChangeCodec,
		codecOptions.jsonValidator,
	);
}
```

### Decision procedure: `feature-libraries/modular-schema/modularChangeCodecs.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeCodecs.ts:1-101`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function makeModularChangeCodecFamily(
	fieldKindConfigurations: ReadonlyMap<ModularChangeFormatVersion, FieldKindConfiguration>,
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
	fieldsCodec: FieldBatchCodec,
	codecOptions: ICodecOptions,
	chunkCompressionStrategy: TreeCompressionStrategy = TreeCompressionStrategy.Compressed,
): ICodecFamily<ModularChangeset, ChangeEncodingContext, ChangeDecodingContext> {
	return makeCodecFamily(
		Array.from(fieldKindConfigurations.entries(), ([version, fieldKinds]) => {
			switch (version) {
				case ModularChangeFormatVersion.v3:
				case ModularChangeFormatVersion.v4: {
					return [
						version,
						makeModularChangeCodecV1(
							fieldKinds,
							revisionTagCodec,
							fieldsCodec,
							codecOptions,
							chunkCompressionStrategy,
						),
					];
				}
				case ModularChangeFormatVersion.v5: {
					return [
						version,
						makeModularChangeCodecV2(
							fieldKinds,
							revisionTagCodec,
							fieldsCodec,
							codecOptions,
							chunkCompressionStrategy,
						),
					];
				}
				default: {
					fail(0xcc5  );
				}
			}
		}),
	);
}
export const ModularChangeFormatVersion = strictEnum("ModularChangeFormatVersion", {
	v3: 3,
	v4: 4,
	v5: 5,
});
export type ModularChangeFormatVersion = Values<typeof ModularChangeFormatVersion>;
```

### Decision procedure: `feature-libraries/modular-schema/modularChangeFormatV1.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFormatV1.ts:1-142`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
export const ChangesetLocalIdSchema = brandedIntegerType<ChangesetLocalId>();
export const EncodedChangeAtomId = Type.Union([
	Type.Tuple([ChangesetLocalIdSchema, RevisionTagSchema]),
	ChangesetLocalIdSchema,
]);
export type EncodedChangeAtomId = Static<typeof EncodedChangeAtomId>;
export const EncodedFieldChange = Type.Object(
	{
		fieldKey: schemaFormatV1.FieldKeySchema,
		fieldKind: schemaFormatV1.FieldKindIdentifierSchema,
		change: JsonCompatibleReadOnlySchema,
	},
	noAdditionalProps,
);
export interface EncodedFieldChange extends Static<typeof EncodedFieldChange> {
	change: JsonCompatibleReadOnly;
}
export const EncodedFieldChangeMap = Type.Array(EncodedFieldChange);
export type EncodedFieldChangeMap = Static<typeof EncodedFieldChangeMap>;
const EncodedNodeExistsConstraint = Type.Object(
	{
		violated: Type.Boolean(),
	},
	noAdditionalProps,
);
type EncodedNodeExistsConstraint = Static<typeof EncodedNodeExistsConstraint>;
export const EncodedNodeChangeset = Type.Object(
	{
		fieldChanges: Type.Optional(EncodedFieldChangeMap),
		nodeExistsConstraint: Type.Optional(EncodedNodeExistsConstraint),
	},
	noAdditionalProps,
);
export type EncodedNodeChangeset = Static<typeof EncodedNodeChangeset>;
export const EncodedRevisionInfo = Type.Object(
	{
		revision: Type.Readonly(RevisionTagSchema),
		rollbackOf: Type.ReadonlyOptional(RevisionTagSchema),
	},
	noAdditionalProps,
);
export type EncodedRevisionInfo = Static<typeof EncodedRevisionInfo>;
export const EncodedTreeIndex = Type.Integer({ minimum: 0 });
export const CommitBuilds = Type.Array(
	Type.Tuple([
		ChangesetLocalIdSchema,
		EncodedTreeIndex,
	]),
);
export type CommitBuilds = Static<typeof CommitBuilds>;
export const EncodedBuildsArray = Type.Array(
	Type.Union([
		Type.Tuple([CommitBuilds, RevisionTagSchema]),
		Type.Tuple([CommitBuilds]),
	]),
);
export type EncodedBuildsArray = Static<typeof EncodedBuildsArray>;
export const EncodedBuilds = Type.Object(
	{
		builds: EncodedBuildsArray,
		trees: JsonCompatibleReadOnlySchema,
	},
	noAdditionalProps,
);
export type EncodedBuilds = Static<typeof EncodedBuilds>;
export const EncodedModularChangesetV1 = Type.Object(
	{
		maxId: Type.Optional(ChangesetLocalIdSchema),
		changes: EncodedFieldChangeMap,
		revisions: Type.ReadonlyOptional(Type.Array(EncodedRevisionInfo)),
		builds: Type.Optional(EncodedBuilds),
		refreshers: Type.Optional(EncodedBuilds),
		violations: Type.Optional(Type.Integer({ minimum: 0 })),
	},
	noAdditionalProps,
);
export type EncodedModularChangesetV1 = Static<typeof EncodedModularChangesetV1>;
```

### Decision procedure: `feature-libraries/modular-schema/modularChangeFormatV2.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFormatV2.ts:1-35`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
const EncodedNoChangeConstraint = Type.Object(
	{
		violated: Type.Boolean(),
	},
	noAdditionalProps,
);
export type EncodedNoChangeConstraint = Static<typeof EncodedNoChangeConstraint>;
export const EncodedModularChangesetV2 = Type.Composite(
	[
		EncodedModularChangesetV1,
		Type.Object(
			{
				noChangeConstraint: Type.Optional(EncodedNoChangeConstraint),
			},
			noAdditionalProps,
		),
	],
	noAdditionalProps,
);
export type EncodedModularChangesetV2 = Static<typeof EncodedModularChangesetV2>;
```

### Literal emission examples and internal-only formats

A changeset with empty field/node/alias/key tables and absent optional members emits `{"changes":[]}` for parent formats 3, 4 and 5. A no-change constraint adds `{"changes":[],"noChangeConstraint":{"violated":false}}` in parent format 5. A single context revision without rollback is omitted; an explicitly empty revision list remains `"revisions":[]` and does not infer a revision on decode. No modular version property is present: its parent chooses 3/4/5. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeCodecV1.ts:405-525` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeCodecV2.ts:63-100`

A field modification to live optional child with empty node fields is `{"changes":[{"fieldKey":"x","fieldKind":"Optional","change":{"c":[[null,{}]]}}]}`. `ModularEditBuilder.Generic` field codec v1 is a sorted array of `[index,inlineNodeChange]`, e.g. `[[0,{}],[2,{}]]`; it has no embedded version. Generic changes are normalized into concrete kinds on composition when necessary. Node IDs allocated during decode are representation identities, not the encoded field indexes. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/genericFieldKindCodecs.ts:20-51` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/genericFieldKind.ts:22-90`

## 4. Behavior

### Representation

Root field changes map field key→`{fieldKind,change}`. Node changes are B-tree entries keyed `[revision?,localId]`; nodeToParent maps them to containing field; nodeAliases permits merged node identities. Cross-field key = target Source/Destination + revision + local ID range; owner table maps range→field ID `{nodeId?,field}`. Values and dependencies are maintained separately so a later write can invalidate an earlier query. Query reads only contiguous segment up to next boundary, even if caller asked for a longer range. Managers must route moved keys/child identities and retry invalidated handlers. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeTypes.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/crossFieldQueries.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/fieldChangeHandler.ts:200`

### Compose

Collect revision infos and max local ID before composing; balanced reduce chronological inputs (not arbitrary fold order if generated IDs/output structure must match). Pair: merge node tables/parents/aliases; compose field maps in A iteration order followed by B-only fields, normalize generic changes to concrete kind where necessary; compose node payloads recursively, unify IDs and record aliases; merge cross-field ownership; repeatedly handle invalidated fields/nodes and copied affected fields until settled. Keep first node-exists and revert constraint on each merged node. Compose builds/destroys/refreshers with cancellation; maxId follows shared allocator; preserve first no-change/revert constraint. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:232` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:294` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:411` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:564` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:707`

### Invert

Reject destroys input. Rollback converts builds to destroys, drops all constraints; ordinary inversion swaps normal/revert constraints. Conflicted original yields only revision/maxId and rollback destruction (no effective inverse fields). Reserve IDs for all original revisions before alias allocation; invert root fields and every node change separately, amend invalidated fields, rebuild owner/parent indexes, recalculate constraint count for ordinary undo only. Revision metadata is one fresh revision with rollbackOf only on rollback. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/invert.ts:53`

### Rebase

Compute effective base (mute conflicted base field intentions); maxId=max both. Clone input node/parent/key tables; rebase intersecting fields and affected base-only fields, transport child identities via baseToRebasedNodeId and update parents/key ownership; amend invalidated and unattached-child fields. Then constraints: any unviolated global no-change constraint becomes violated on rebase unless ignoreNoChangeViolation (even when no apparent data effect); recursively update existence constraints using attached state; preserve on-revert constraint; retain original builds/destroys/refreshers/revisions, prune empty nodes/fields. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:764` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:873` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:989`

### Constraints and delta

Violation count makes whole logical field/node change ineffective, not just the offending child. intoDelta suppresses fields/global/rename when conflicted but still outputs builds/destroys/refreshers, to retain content/history coherence. Children are lowered via node-ID resolution with aliases. Refreshers carry removed roots needed by later operations beyond retention; they are not extra visible insertions. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:1728` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:1673`

### Generic field edits

Generic is an indexed list of child changes, not a structural field mutation. Compose merges matching indexes via child compose; rebase pairs indexes via child rebase; invert preserves index/child ID while modular inversion handles actual node payload. Conversion to concrete field kind uses that handler's child-change builder at each index. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/genericFieldKind.ts:22`

Exact root operations, codec reconstruction, generic merge, dependency/range queries and key tables are extracted below. Field-specific tables are in optional/sequence specs.

### Algorithm notation and completeness

The following decision procedures are part of this specification, not external reading assignments. They preserve exact predicates, allocation order, collection traversal, return shapes and synchronous event calls. `undefined` means absent; `null` is a value; object spread is right-biased; `delete` removes a property; `Map`/`Set` iterate in insertion order. TypeBox `Optional(T)` permits absence, not null; tuples are fixed-order JSON arrays; singleton discriminated unions have exactly one case property. Assertions stop execution at the displayed short code. Helpers in another area use that area's same-named procedure; generic collection utilities retain JavaScript order. These are reference algorithms to translate into Swift, not a proposal to embed TypeScript in the client.

### Decision procedure: `feature-libraries/modular-schema/comparison.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/comparison.ts:1-256`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function allowsTreeSuperset(
	policy: FullSchemaPolicy,
	originalData: TreeStoredSchema,
	original: TreeNodeStoredSchema | undefined,
	superset: TreeNodeStoredSchema | undefined,
): boolean {
	if (isNeverTree(policy, originalData, original)) {
		return true;
	}
	if (isNeverTree(policy, originalData, superset)) {
		return false;
	}
	assert(original !== undefined, 0x716  );
	assert(superset !== undefined, 0x717  );
	if (original instanceof LeafNodeStoredSchema) {
		if (superset instanceof LeafNodeStoredSchema) {
			return allowsValueSuperset(original.leafValue, superset.leafValue);
		}
		return false;
	}
	if (superset instanceof LeafNodeStoredSchema) {
		return false;
	}
	assert(
		original instanceof MapNodeStoredSchema || original instanceof ObjectNodeStoredSchema,
		0x893  ,
	);
	assert(
		superset instanceof MapNodeStoredSchema || superset instanceof ObjectNodeStoredSchema,
		0x894  ,
	);
	if (original instanceof MapNodeStoredSchema) {
		if (superset instanceof MapNodeStoredSchema) {
			return allowsFieldSuperset(policy, originalData, original.mapFields, superset.mapFields);
		}
		return false;
	}
	assert(original instanceof ObjectNodeStoredSchema, 0x895  );
	if (superset instanceof MapNodeStoredSchema) {
		for (const [_key, field] of original.objectNodeFields) {
			if (!allowsFieldSuperset(policy, originalData, field, superset.mapFields)) {
				return false;
			}
		}
		return true;
	}
	assert(superset instanceof ObjectNodeStoredSchema, 0x896  );
	return compareSets({
		a: original.objectNodeFields,
		b: superset.objectNodeFields,
		aExtra: (originalField) =>
			allowsFieldSuperset(
				policy,
				originalData,
				original.objectNodeFields.get(originalField) ??
					fail(0xb17  ),
				storedEmptyFieldSchema,
			),
		bExtra: (supersetField) =>
			allowsFieldSuperset(
				policy,
				originalData,
				storedEmptyFieldSchema,
				superset.objectNodeFields.get(supersetField) ??
					fail(0xb18  ),
			),
		same: (sameField) =>
			allowsFieldSuperset(
				policy,
				originalData,
				original.objectNodeFields.get(sameField) ?? fail(0xb19  ),
				superset.objectNodeFields.get(sameField) ?? fail(0xb1a  ),
			),
	});
}
export function allowsValueSuperset(
	original: ValueSchema | undefined,
	superset: ValueSchema | undefined,
): boolean {
	return original === superset;
}
export function allowsFieldSuperset(
	policy: FullSchemaPolicy,
	originalData: TreeStoredSchema,
	original: TreeFieldStoredSchema,
	superset: TreeFieldStoredSchema,
	monotonicOnly: boolean = true,
): boolean {
	if (!monotonicOnly && isNeverField(policy, originalData, original)) {
		return true;
	}
	if (!allowsTreeSchemaIdentifierSuperset(original.types, superset.types)) {
		return false;
	}
	if (original.kind === superset.kind) {
		return true;
	}
	const supersetKind = policy.fieldKinds.get(superset.kind) ?? fail(0xb1b  );
	if (monotonicOnly) {
		return supersetKind.options.allowMonotonicUpgradeFrom.has(original.kind);
	} else {
		const originalKind =
			policy.fieldKinds.get(original.kind) ?? fail(0xcab  );
		return allowsMultiplicitySuperset(originalKind.multiplicity, supersetKind.multiplicity);
	}
}
export function allowsTreeSchemaIdentifierSuperset(
	original: TreeTypeSet,
	superset: TreeTypeSet,
): boolean {
	for (const originalType of original) {
		if (!superset.has(originalType)) {
			return false;
		}
	}
	return true;
}
export function allowsRepoSuperset(
	policy: FullSchemaPolicy,
	original: TreeStoredSchema,
	superset: TreeStoredSchema,
): boolean {
	{
		if (
			!allowsFieldSuperset(
				policy,
				original,
				original.rootFieldSchema,
				superset.rootFieldSchema,
			)
		) {
			return false;
		}
	}
	for (const [key, schema] of original.nodeSchema) {
		if (!allowsTreeSuperset(policy, original, schema, superset.nodeSchema.get(key))) {
			return false;
		}
	}
	return true;
}
export function allowsMultiplicitySuperset(
	original: Multiplicity,
	superset: Multiplicity,
): boolean {
	if (original === superset) {
		return true;
	}
	switch (superset) {
		case Multiplicity.Forbidden: {
			return false;
		}
		case Multiplicity.Optional: {
			return original === Multiplicity.Single || original === Multiplicity.Forbidden;
		}
		case Multiplicity.Single: {
			return false;
		}
		case Multiplicity.Sequence: {
			return true;
		}
		default: {
			return unreachableCase(superset);
		}
	}
}
```

### Decision procedure: `feature-libraries/modular-schema/crossFieldQueries.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/crossFieldQueries.ts:1-94`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type CrossFieldMap<T> = ChangeAtomIdRangeMap<T>;
export type CrossFieldQuerySet = CrossFieldMap<boolean>;
export function addCrossFieldQuery(
	set: CrossFieldQuerySet,
	revision: RevisionTag | undefined,
	id: ChangesetLocalId,
	count: number,
): void {
	setInCrossFieldMap(set, revision, id, count, true);
}
export function setInCrossFieldMap<T>(
	map: CrossFieldMap<T>,
	revision: RevisionTag | undefined,
	id: ChangesetLocalId,
	count: number,
	value: T,
): void {
	map.set({ revision, localId: id }, count, value);
}
export function getFirstFromCrossFieldMap<T>(
	map: CrossFieldMap<T>,
	revision: RevisionTag | undefined,
	id: ChangesetLocalId,
	count: number,
): RangeQueryResult<T | undefined> {
	return map.getFirst({ revision, localId: id }, count);
}
export enum CrossFieldTarget {
	Source,
	Destination,
}
export interface CrossFieldManager<T = unknown> {
	get(
		target: CrossFieldTarget,
		revision: RevisionTag | undefined,
		id: ChangesetLocalId,
		count: number,
		addDependency: boolean,
	): RangeQueryResult<T | undefined>;
	set(
		target: CrossFieldTarget,
		revision: RevisionTag | undefined,
		id: ChangesetLocalId,
		count: number,
		newValue: T,
		invalidateDependents: boolean,
	): void;
	onMoveIn(id: NodeId): void;
	moveKey(
		target: CrossFieldTarget,
		revision: RevisionTag | undefined,
		id: ChangesetLocalId,
		count: number,
	): void;
}
```

### Decision procedure: `feature-libraries/modular-schema/defaultAtomIdAliasAllocator.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/defaultAtomIdAliasAllocator.ts:1-71`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class DefaultAtomIdAliasAllocator implements AtomIdAliasAllocator {
	private readonly offsets: Map<
		RevisionTag | undefined,
		{ readonly offset: number; readonly originalMaxLocalId: ChangesetLocalId }
	> = new Map();
	private readonly allocator: IdAllocator = idAllocatorFromMaxId();
	public reserve(
		originalRevision: RevisionTag | undefined,
		originalMaxLocalId: ChangesetLocalId,
	): void {
		const current = this.offsets.get(originalRevision);
		if (current === undefined) {
			const offset =
				originalMaxLocalId < 0
					? this.allocator.getMaxId()
					: this.allocator.allocate(originalMaxLocalId + 1);
			this.offsets.set(originalRevision, { offset, originalMaxLocalId });
		} else {
			assert(
				originalMaxLocalId === current.originalMaxLocalId,
				0xd3f  ,
			);
		}
	}
	public getAlias(
		originalRevision: RevisionTag | undefined,
		originalLocalId: ChangesetLocalId,
	): ChangesetLocalId {
		const current = this.offsets.get(originalRevision);
		if (current === undefined) {
			fail(0xd40  );
		}
		assert(
			originalLocalId <= current.originalMaxLocalId,
			0xd41  ,
		);
		return offsetChangesetLocalId(originalLocalId, current.offset);
	}
	public getMaxId = (): ChangesetLocalId => {
		return brand(this.allocator.getMaxId());
	};
	public allocate = (count?: number): ChangesetLocalId => {
		return brand(this.allocator.allocate(count));
	};
}
```

### Decision procedure: `feature-libraries/modular-schema/defaultRevisionReplacer.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/defaultRevisionReplacer.ts:1-102`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class DefaultRevisionReplacer implements RevisionReplacer {
	private readonly updatedLocalIds: ChangeAtomIdRangeMap<ChangesetLocalId> =
		newChangeAtomIdRangeMap(offsetChangesetLocalId);
	private readonly localIds: RangeMap<ChangesetLocalId, true> = newIntegerRangeMap();
	private maxSeen: ChangesetLocalId = brandConst(-1)();
	public constructor(
		public readonly updatedRevision: RevisionTag,
		private readonly obsoleteRevisions: Set<RevisionTag | undefined>,
	) {}
	public isObsolete(revision: RevisionTag | undefined): boolean {
		return this.obsoleteRevisions.has(revision);
	}
	public getUpdatedAtomId<T extends ChangeAtomId>(id: T, count: number = 1): T {
		assert(count >= 1, 0xcc9  );
		if (this.isObsolete(id.revision)) {
			const updated: Mutable<T> = { ...id, revision: this.updatedRevision };
			let continuingOutputId: ChangesetLocalId | undefined;
			let remainderCount = count;
			let remainderStart = id;
			while (remainderCount > 0) {
				const prior = this.updatedLocalIds.getFirst(remainderStart, remainderCount);
				if (prior.value === undefined) {
					const defaultOutputId = continuingOutputId ?? remainderStart.localId;
					const newLocalId = this.areAllUnallocated(defaultOutputId, prior.length)
						?
							defaultOutputId
						:
							brand<ChangesetLocalId>(this.maxSeen + 1);
					this.maxSeen = brand(Math.max(this.maxSeen, newLocalId + prior.length - 1));
					this.localIds.set(newLocalId, prior.length, true);
					this.updatedLocalIds.set(remainderStart, prior.length, newLocalId);
					if (continuingOutputId === undefined) {
						updated.localId = newLocalId;
					} else if (newLocalId !== continuingOutputId) {
						fail(0xcca  );
					}
					continuingOutputId = offsetChangesetLocalId(newLocalId, prior.length);
				} else {
					if (continuingOutputId === undefined) {
						updated.localId = prior.value;
					} else if (prior.value !== continuingOutputId) {
						fail(0xccb  );
					}
					continuingOutputId = offsetChangesetLocalId(prior.value, prior.length);
				}
				remainderStart = offsetChangeAtomId(remainderStart, prior.length);
				remainderCount -= prior.length;
			}
			return updated;
		}
		return id;
	}
	private areAllUnallocated(id: ChangesetLocalId, count: number): boolean {
		for (const entry of this.localIds.getAll(id, count)) {
			if (entry.value !== undefined) {
				return false;
			}
		}
		return true;
	}
}
```

### Decision procedure: `feature-libraries/modular-schema/fieldChangeHandler.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/fieldChangeHandler.ts:1-402`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface ChildChangeInfo {
	nodeId: NodeId;
	inputRootId: ChangeAtomId | undefined;
	detachId: ChangeAtomId | undefined;
}
export interface FieldChangeDelta {
	readonly local?: DeltaFieldChanges;
	readonly global?: readonly DeltaDetachedNodeChanges[];
	readonly rename?: readonly DeltaDetachedNodeRename[];
}
export interface FieldChangeHandler<
	TChangeset,
	TEditor extends FieldEditor<TChangeset> = FieldEditor<TChangeset>,
> {
	_typeCheck?: Invariant<TChangeset>;
	readonly rebaser: FieldChangeRebaser<TChangeset>;
	readonly codecsFactory: (
		revisionTagCodec: JsonCodecPart<
			RevisionTag,
			typeof RevisionTagSchema,
			ChangeEncodingContext
		>,
	) => ICodecFamily<TChangeset, FieldChangeEncodingContext, FieldChangeDecodingContext>;
	readonly editor: TEditor;
	intoDelta(change: TChangeset, deltaFromChild: ToDelta): FieldChangeDelta;
	readonly relevantRemovedRoots: (
		change: TChangeset,
		relevantRemovedRootsFromChild: RelevantRemovedRootsFromChild,
	) => Iterable<DeltaDetachedNodeId>;
	isEmpty(change: TChangeset): boolean;
	getNestedChanges(change: TChangeset): ChildChangeInfo[];
	getCrossFieldKeys(change: TChangeset): CrossFieldKeyRange[];
	createEmpty(): TChangeset;
}
export interface FieldChangeRebaser<TChangeset> {
	compose(
		change1: TChangeset,
		change2: TChangeset,
		composeChild: NodeChangeComposer,
		genId: IdAllocator,
		crossFieldManager: CrossFieldManager,
		revisionMetadata: RevisionMetadataSource,
	): TChangeset;
	invert(
		change: TChangeset,
		isRollback: boolean,
		genId: AtomIdAliasAllocator,
		revision: RevisionTag | undefined,
		crossFieldManager: CrossFieldManager,
		revisionMetadata: RevisionMetadataSource,
	): TChangeset;
	rebase(
		change: TChangeset,
		over: TChangeset,
		rebaseChild: NodeChangeRebaser,
		genId: IdAllocator,
		crossFieldManager: CrossFieldManager,
		revisionMetadata: RebaseRevisionMetadata,
	): TChangeset;
	prune(change: TChangeset, pruneChild: NodeChangePruner): TChangeset;
	replaceRevisions(change: TChangeset, replacer: RevisionReplacer): TChangeset;
	filterEdits(
		change: TChangeset,
		options: {
			filterDetach: FilterDetachFunc;
			filterAttach: FilterAttachFunc;
			preserveOtherEdits: boolean;
		},
	): TChangeset;
}
export type FilterDetachFunc = (
	detachId: ChangeAtomId,
	count: number,
	inputRootId: ChangeAtomId | undefined,
	endpoint?: ChangeAtomId,
) => RangeQueryResult<FilterDetachResult>;
export type FilterAttachFunc = (
	attachId: ChangeAtomId,
	count: number,
	outputRootId: ChangeAtomId | undefined,
	endpoint?: ChangeAtomId,
) => RangeQueryResult<FilterAttachResult>;
export interface FilterDetachResult {
	readonly action: EditFilterStatus;
	readonly shouldRemoveChild?: boolean;
}
export interface FilterAttachResult {
	readonly action: EditFilterStatus;
	readonly nodeId?: NodeId;
	readonly newAttachId?: ChangeAtomId;
}
export enum EditFilterStatus {
	Remove,
	Preserve,
	PreserveWithoutMove,
}
export function referenceFreeFieldChangeRebaser<TChangeset>(data: {
	compose: (change1: TChangeset, change2: TChangeset) => TChangeset;
	invert: (change: TChangeset) => TChangeset;
	rebase: (change: TChangeset, over: TChangeset) => TChangeset;
	filterEdits: FieldChangeRebaser<TChangeset>["filterEdits"];
}): FieldChangeRebaser<TChangeset> {
	return isolatedFieldChangeRebaser({
		compose: (change1, change2, _composeChild, _genId) => data.compose(change1, change2),
		invert: (change, _invertChild, _genId) => data.invert(change),
		rebase: (change, over, _rebaseChild, _genId) => data.rebase(change, over),
		filterEdits: (change, options) => data.filterEdits(change, options),
	});
}
export function isolatedFieldChangeRebaser<TChangeset>(data: {
	compose: FieldChangeRebaser<TChangeset>["compose"];
	invert: FieldChangeRebaser<TChangeset>["invert"];
	rebase: FieldChangeRebaser<TChangeset>["rebase"];
	filterEdits: FieldChangeRebaser<TChangeset>["filterEdits"];
}): FieldChangeRebaser<TChangeset> {
	return {
		...data,
		prune: (change) => change,
		replaceRevisions: (change) => change,
	};
}
export interface FieldEditor<TChangeset> {
	buildChildChanges(changes: Iterable<[index: number, change: NodeId]>): TChangeset;
}
export type ToDelta = (child: NodeId) => DeltaFieldMap;
export type NodeChangeInverter = (change: NodeId) => NodeId;
export enum NodeAttachState {
	Attached,
	Detached,
}
export type NodeChangeRebaser = (
	change: NodeId | undefined,
	baseChange: NodeId | undefined,
	state?: NodeAttachState,
) => NodeId | undefined;
export type NodeChangeComposer = (
	change1: NodeId | undefined,
	change2: NodeId | undefined,
) => NodeId;
export type NodeChangePruner = (change: NodeId) => NodeId | undefined;
export type RelevantRemovedRootsFromChild = (child: NodeId) => Iterable<DeltaDetachedNodeId>;
export interface RebaseRevisionMetadata extends RevisionMetadataSource {
	readonly getRevisionToRebase: () => RevisionTag | undefined;
	readonly getBaseRevisions: () => RevisionTag[];
}
export interface FieldChangeEncodingContext {
	readonly baseContext: ChangeEncodingContext;
	encodeNode(nodeId: NodeId): EncodedNodeChangeset;
}
export interface FieldChangeDecodingContext {
	readonly baseContext: ChangeEncodingContext;
	decodeNode(encodedNode: EncodedNodeChangeset): NodeId;
}
export interface AtomIdAliasAllocator extends IdAllocator<ChangesetLocalId> {
	reserve(
		originalRevision: RevisionTag | undefined,
		originalMaxLocalId: ChangesetLocalId,
	): void;
	getAlias(
		originalRevision: RevisionTag | undefined,
		originalLocalId: ChangesetLocalId,
	): ChangesetLocalId;
}
```

### Decision procedure: `feature-libraries/modular-schema/fieldKind.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/fieldKind.ts:1-121`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class FlexFieldKind<
	TEditor extends FieldEditor<any> = FieldEditor<any>,
	TName extends FieldKindIdentifier = FieldKindIdentifier,
	TMultiplicity extends Multiplicity = Multiplicity,
> implements FieldKindData
{
	protected _typeCheck!: MakeNominal;
	public readonly changeHandler: FieldChangeHandler<any, TEditor>;
	public constructor(
		public readonly identifier: TName,
		public readonly multiplicity: TMultiplicity,
		public readonly options: FieldKindOptions<FieldChangeHandler<any, TEditor>>,
	) {
		this.changeHandler = options.changeHandler;
	}
}
export interface FieldKindOptions<TFieldChangeHandler> {
	readonly changeHandler: TFieldChangeHandler;
	readonly allowMonotonicUpgradeFrom: ReadonlySet<FieldKindIdentifier>;
}
export interface FullSchemaPolicy extends SchemaPolicy {
	readonly fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>;
}
```

### Decision procedure: `feature-libraries/modular-schema/fieldKindConfiguration.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/fieldKindConfiguration.ts:1-27`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface FieldKindConfigurationEntry {
	readonly kind: FlexFieldKind;
	readonly formatVersion: number;
}
export type FieldKindConfiguration = ReadonlyMap<
	FieldKindIdentifier,
	FieldKindConfigurationEntry
>;
```

### Decision procedure: `feature-libraries/modular-schema/filterEdits.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/filterEdits.ts:1-118`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function removeAllDetachesFilter(
	_id: ChangeAtomId,
	count: number,
	_rootId: ChangeAtomId | undefined,
	_endpointId?: ChangeAtomId,
): RangeQueryResult<FilterDetachResult> {
	return {
		value: { action: EditFilterStatus.Remove, shouldRemoveChild: false },
		length: count,
	};
}
export function removeAllAttachesFilter(
	_id: ChangeAtomId,
	count: number,
	_rootId: ChangeAtomId | undefined,
	_endpointId?: ChangeAtomId,
): RangeQueryResult<FilterAttachResult> {
	return { value: { action: EditFilterStatus.Remove }, length: count };
}
export function filterEdits(
	change: ModularChangeset,
	filterFieldEdits: (fieldChange: FieldChange, fieldId: FieldId) => FieldChange,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): ModularChangeset {
	strictRebaseValidation("Malformed filterEdits input", () =>
		isChangesetValid(change, fieldKinds),
	);
	const filteredFieldChanges = filterFieldMapEdits(
		change.fieldChanges,
		undefined,
		filterFieldEdits,
	);
	const filteredNodeChanges: ChangeAtomIdBTree<NodeChangeset> = brand(
		change.nodeChanges.mapValues((v, k) =>
			filterNodeEdits(makeChangeAtomId(k[1], k[0]), v, filterFieldEdits),
		),
	);
	const { crossFieldKeys: filteredCrossFieldKeys, nodeToParent: filteredNodeToParent } =
		makeChangesetInversions(
			filteredFieldChanges,
			filteredNodeChanges,
			fieldKinds,
			change.nodeAliases,
		);
	return pruneChangeset(
		{
			...change,
			fieldChanges: filteredFieldChanges,
			nodeChanges: filteredNodeChanges,
			crossFieldKeys: filteredCrossFieldKeys,
			nodeToParent: filteredNodeToParent,
		},
		fieldKinds,
	);
}
function filterFieldMapEdits(
	change: FieldChangeMap,
	nodeId: NodeId | undefined,
	filterFieldEdits: (fieldChange: FieldChange, fieldId: FieldId) => FieldChange,
): FieldChangeMap {
	return new Map(
		Array.from(change.entries(), ([field, fieldChange]) => [
			field,
			filterFieldEdits(fieldChange, { nodeId, field }),
		]),
	);
}
function filterNodeEdits(
	nodeId: NodeId,
	change: NodeChangeset,
	filterFieldEdits: (fieldChange: FieldChange, fieldId: FieldId) => FieldChange,
): NodeChangeset {
	if (change.fieldChanges === undefined) {
		return change;
	}
	return {
		...change,
		fieldChanges: filterFieldMapEdits(change.fieldChanges, nodeId, filterFieldEdits),
	};
}
```

### Decision procedure: `feature-libraries/modular-schema/genericFieldKind.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/genericFieldKind.ts:1-199`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const genericChangeHandler: FieldChangeHandler<GenericChangeset> = {
	rebaser: {
		compose,
		invert: (change: GenericChangeset): GenericChangeset => change,
		rebase: rebaseGenericChange,
		prune: pruneGenericChange,
		replaceRevisions,
		filterEdits: (change: GenericChangeset): GenericChangeset => change,
	},
	codecsFactory: makeGenericChangeCodec,
	editor: {
		buildChildChanges(changes: Iterable<[number, NodeId]>): GenericChangeset {
			return newGenericChangeset([...changes]);
		},
	},
	intoDelta: (change: GenericChangeset, deltaFromChild: ToDelta): FieldChangeDelta => {
		let nodeIndex = 0;
		const markList: DeltaMark[] = [];
		for (const [index, nodeChange] of change.entries()) {
			if (nodeIndex < index) {
				const offset = index - nodeIndex;
				markList.push({ count: offset });
				nodeIndex = index;
			}
			markList.push({ count: 1, fields: deltaFromChild(nodeChange) });
			nodeIndex += 1;
		}
		return { local: { marks: markList } };
	},
	relevantRemovedRoots,
	isEmpty: (change: GenericChangeset): boolean => change.length === 0,
	getNestedChanges,
	createEmpty: newGenericChangeset,
	getCrossFieldKeys: (_change) => [],
};
function compose(
	change1: GenericChangeset,
	change2: GenericChangeset,
	composeChildren: NodeChangeComposer,
): GenericChangeset {
	const composed = change1.clone();
	for (const [index, id2] of change2.entries()) {
		const id1 = composed.get(index);
		const idComposed = id1 === undefined ? id2 : composeChildren(id1, id2);
		composed.set(index, idComposed);
	}
	return composed;
}
function getNestedChanges(change: GenericChangeset): ChildChangeInfo[] {
	return change.toArray().map(([_index, nodeChange]) => ({
		nodeId: nodeChange,
		inputRootId: undefined,
		detachId: undefined,
	}));
}
function rebaseGenericChange(
	change: GenericChangeset,
	over: GenericChangeset,
	rebaseChild: NodeChangeRebaser,
): GenericChangeset {
	const rebased: GenericChangeset = new BTree();
	let nextIndex = 0;
	while (true) {
		const newEntry = change.getPairOrNextHigher(nextIndex);
		const baseEntry = over.getPairOrNextHigher(nextIndex);
		if (baseEntry === undefined && newEntry === undefined) {
			break;
		}
		const newIndex = newEntry?.[0] ?? Number.POSITIVE_INFINITY;
		const baseIndex = baseEntry?.[0] ?? Number.POSITIVE_INFINITY;
		let newNodeChange: NodeId | undefined;
		let baseNodeChange: NodeId | undefined;
		let index: number;
		if (newIndex === baseIndex) {
			assert(
				newEntry !== undefined && baseEntry !== undefined,
				0xa0d  ,
			);
			index = newIndex;
			newNodeChange = newEntry[1];
			baseNodeChange = baseEntry[1];
		} else if (newIndex < baseIndex) {
			assert(newEntry !== undefined, 0xa0e  );
			index = newIndex;
			newNodeChange = newEntry[1];
		} else {
			assert(baseEntry !== undefined, 0xa0f  );
			index = baseIndex;
			baseNodeChange = baseEntry[1];
		}
		const nodeChange = rebaseChild(newNodeChange, baseNodeChange);
		if (nodeChange !== undefined) {
			rebased.set(index, nodeChange);
		}
		nextIndex = index + 1;
	}
	return rebased;
}
function pruneGenericChange(
	changeset: GenericChangeset,
	pruneChild: NodeChangePruner,
): GenericChangeset {
	const pruned: GenericChangeset = new BTree();
	for (const [index, node] of changeset.entries()) {
		const prunedNode = pruneChild(node);
		if (prunedNode !== undefined) {
			pruned.set(index, prunedNode);
		}
	}
	return pruned;
}
function replaceRevisions(
	changeset: GenericChangeset,
	replacer: RevisionReplacer,
): GenericChangeset {
	return changeset.mapValues((node) => replacer.getUpdatedAtomId(node));
}
export const genericFieldKind: FlexFieldKind = new FlexFieldKind(
	brandConst("ModularEditBuilder.Generic")<FieldKindIdentifier>(),
	Multiplicity.Sequence,
	{
		changeHandler: genericChangeHandler,
		allowMonotonicUpgradeFrom: new Set(),
	},
);
export function convertGenericChange<TChange>(
	changeset: GenericChangeset,
	target: FieldChangeHandler<TChange>,
): TChange {
	return target.editor.buildChildChanges(changeset.entries());
}
function* relevantRemovedRoots(
	change: GenericChangeset,
	relevantRemovedRootsFromChild: RelevantRemovedRootsFromChild,
): Iterable<DeltaDetachedNodeId> {
	for (const nodeChange of change.values()) {
		yield* relevantRemovedRootsFromChild(nodeChange);
	}
}
```

### Decision procedure: `feature-libraries/modular-schema/genericFieldKindTypes.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/genericFieldKindTypes.ts:1-17`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type GenericChangeset = BTree<number, NodeId>;
export function newGenericChangeset(nodes: [number, NodeId][] = []): GenericChangeset {
	return new BTree(nodes);
}
```

### Decision procedure: `feature-libraries/modular-schema/invert.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/invert.ts:1-321`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function invertModularChange(
	change: TaggedChange<ModularChangeset>,
	isRollback: boolean,
	revisionForInvert: RevisionTag,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): ModularChangeset {
	strictRebaseValidation("Malformed invert input", () =>
		isChangesetValid(change.change, fieldKinds),
	);
	const destroys = isRollback ? invertBuilds(change.change.builds) : undefined;
	assert(
		change.change.destroys === undefined,
		0x89a  ,
	);
	const revInfos: RevisionInfo[] = isRollback
		? [{ revision: revisionForInvert, rollbackOf: change.revision }]
		: [{ revision: revisionForInvert }];
	const [noChangeConstraint, noChangeConstraintOnRevert] = isRollback
		?
			[undefined, undefined]
		: [change.change.noChangeConstraintOnRevert, change.change.noChangeConstraint];
	if (hasConflicts(change.change)) {
		return makeModularChangeset({
			maxId: change.change.maxId as number,
			revisions: revInfos,
			destroys,
		});
	}
	const genId = new DefaultAtomIdAliasAllocator();
	const crossFieldTable: InvertTable = {
		...newCrossFieldTable<FieldChange>(),
		originalFieldToContext: new Map(),
	};
	const { revInfos: oldRevInfos } = getRevInfoFromTaggedChanges([change]);
	const revisionMetadata = revisionMetadataSourceFromInfo(oldRevInfos);
	if (change.change.maxId !== undefined) {
		for (const { revision } of oldRevInfos) {
			genId.reserve(revision, change.change.maxId);
		}
	}
	const invertedFields = invertFieldMap(
		change.change.fieldChanges,
		undefined,
		isRollback,
		genId,
		crossFieldTable,
		revisionMetadata,
		revisionForInvert,
		fieldKinds,
	);
	const invertedNodes = newChangeAtomIdBTree<NodeChangeset>();
	change.change.nodeChanges.forEachPair(([revision, localId], nodeChangeset) => {
		invertedNodes.set(
			[revision, localId],
			invertNodeChange(
				nodeChangeset,
				{ revision, localId },
				isRollback,
				genId,
				crossFieldTable,
				revisionMetadata,
				revisionForInvert,
				fieldKinds,
			),
		);
	});
	if (crossFieldTable.invalidatedFields.size > 0) {
		const fieldsToUpdate = crossFieldTable.invalidatedFields;
		crossFieldTable.invalidatedFields = new Set();
		for (const fieldChange of fieldsToUpdate) {
			const originalFieldChange = fieldChange.change;
			const context = crossFieldTable.originalFieldToContext.get(fieldChange);
			assert(
				context !== undefined,
				0x851  ,
			);
			const { invertedField, fieldId } = context;
			const amendedChange = getChangeHandler(fieldKinds, fieldChange.fieldKind).rebaser.invert(
				originalFieldChange,
				isRollback,
				genId,
				revisionForInvert,
				new InvertManager(crossFieldTable, fieldChange, fieldId),
				revisionMetadata,
			);
			invertedField.change = brand(amendedChange);
		}
	}
	const { crossFieldKeys, nodeToParent } = makeChangesetInversions(
		invertedFields,
		invertedNodes,
		fieldKinds,
		change.change.nodeAliases,
	);
	const constraintState = newConstraintState(0);
	if (!isRollback) {
		updateConstraintsForFields(
			invertedFields,
			NodeAttachState.Attached,
			constraintState,
			invertedNodes,
			change.change.nodeAliases,
			fieldKinds,
		);
	}
	const inverse = makeModularChangeset({
		fieldChanges: invertedFields,
		nodeChanges: invertedNodes,
		nodeToParent,
		nodeAliases: change.change.nodeAliases,
		crossFieldKeys,
		maxId: genId.getMaxId(),
		revisions: revInfos,
		constraintViolationCount: constraintState.violationCount,
		noChangeConstraint,
		noChangeConstraintOnRevert,
		destroys,
	});
	strictRebaseValidation("Malformed invert output", () =>
		isChangesetValid(inverse, fieldKinds),
	);
	return inverse;
}
function invertFieldMap(
	changes: FieldChangeMap,
	parentId: NodeId | undefined,
	isRollback: boolean,
	genId: AtomIdAliasAllocator,
	crossFieldTable: InvertTable,
	revisionMetadata: RevisionMetadataSource,
	revisionForInvert: RevisionTag,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): FieldChangeMap {
	const invertedFields: FieldChangeMap = new Map();
	for (const [field, fieldChange] of changes) {
		const fieldId = { nodeId: parentId, field };
		const manager = new InvertManager(crossFieldTable, fieldChange, fieldId);
		const invertedChange = getChangeHandler(fieldKinds, fieldChange.fieldKind).rebaser.invert(
			fieldChange.change,
			isRollback,
			genId,
			revisionForInvert,
			manager,
			revisionMetadata,
		);
		const invertedFieldChange: FieldChange = {
			...fieldChange,
			change: brand(invertedChange),
		};
		invertedFields.set(field, invertedFieldChange);
		crossFieldTable.originalFieldToContext.set(fieldChange, {
			fieldId,
			invertedField: invertedFieldChange,
		});
	}
	return invertedFields;
}
function invertNodeChange(
	change: NodeChangeset,
	id: NodeId,
	isRollback: boolean,
	genId: AtomIdAliasAllocator,
	crossFieldTable: InvertTable,
	revisionMetadata: RevisionMetadataSource,
	revisionForInvert: RevisionTag,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): NodeChangeset {
	const inverse: NodeChangeset = {};
	if (!isRollback) {
		if (change.nodeExistsConstraint !== undefined) {
			inverse.nodeExistsConstraintOnRevert = change.nodeExistsConstraint;
		}
		if (change.nodeExistsConstraintOnRevert !== undefined) {
			inverse.nodeExistsConstraint = change.nodeExistsConstraintOnRevert;
		}
	}
	if (change.fieldChanges !== undefined) {
		inverse.fieldChanges = invertFieldMap(
			change.fieldChanges,
			id,
			isRollback,
			genId,
			crossFieldTable,
			revisionMetadata,
			revisionForInvert,
			fieldKinds,
		);
	}
	return inverse;
}
function invertBuilds(
	builds: ChangeAtomIdBTree<TreeChunk> | undefined,
): ChangeAtomIdBTree<number> | undefined {
	if (builds !== undefined) {
		return brand(builds.mapValues((chunk) => chunk.topLevelLength));
	}
	return undefined;
}
interface InvertTable extends CrossFieldTable<FieldChange> {
	originalFieldToContext: Map<FieldChange, InvertContext>;
}
interface InvertContext {
	fieldId: FieldId;
	invertedField: FieldChange;
}
class InvertManager extends CrossFieldManagerI<FieldChange> {
	public constructor(
		table: InvertTable,
		field: FieldChange,
		private readonly fieldId: FieldId,
		allowInval = true,
	) {
		super(table, field, allowInval);
	}
	public override onMoveIn(id: ChangeAtomId): void {}
	public override moveKey(
		target: CrossFieldTarget,
		revision: RevisionTag | undefined,
		id: ChangesetLocalId,
		count: number,
	): void {
		fail(0x9c5  );
	}
	private get table(): InvertTable {
		return this.crossFieldTable as InvertTable;
	}
}
```

### Decision procedure: `feature-libraries/modular-schema/isNeverTree.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/isNeverTree.ts:1-116`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function isNeverField(
	policy: SchemaPolicy,
	originalData: TreeStoredSchema,
	field: TreeFieldStoredSchema,
): boolean {
	return isNeverFieldRecursive(policy, originalData, field, new Set());
}
export function isNeverFieldRecursive(
	policy: SchemaPolicy,
	originalData: TreeStoredSchema,
	field: TreeFieldStoredSchema,
	parentTypeStack: Set<TreeNodeStoredSchema>,
): boolean {
	if (
		(policy.fieldKinds.get(field.kind) ?? fail(0xb1c  ))
			.multiplicity === Multiplicity.Single &&
		field.types !== undefined
	) {
		for (const type of field.types) {
			if (
				!isNeverTreeRecursive(
					policy,
					originalData,
					originalData.nodeSchema.get(type),
					parentTypeStack,
				)
			) {
				return false;
			}
		}
		return true;
	}
	return false;
}
export function isNeverTree(
	policy: SchemaPolicy,
	originalData: TreeStoredSchema,
	treeNode: TreeNodeStoredSchema | undefined,
): boolean {
	return isNeverTreeRecursive(policy, originalData, treeNode, new Set());
}
export function isNeverTreeRecursive(
	policy: SchemaPolicy,
	originalData: TreeStoredSchema,
	treeNode: TreeNodeStoredSchema | undefined,
	parentTypeStack: Set<TreeNodeStoredSchema>,
): boolean {
	if (treeNode === undefined) {
		return true;
	}
	if (parentTypeStack.has(treeNode)) {
		return true;
	}
	try {
		parentTypeStack.add(treeNode);
		if (treeNode instanceof MapNodeStoredSchema) {
			return (
				(
					policy.fieldKinds.get(treeNode.mapFields.kind) ??
					fail(0xb1d  )
				).multiplicity === Multiplicity.Single
			);
		} else if (treeNode instanceof ObjectNodeStoredSchema) {
			for (const field of treeNode.objectNodeFields.values()) {
				if (isNeverFieldRecursive(policy, originalData, field, parentTypeStack)) {
					return true;
				}
			}
			return false;
		} else {
			assert(treeNode instanceof LeafNodeStoredSchema, 0x897  );
			return false;
		}
	} finally {
		parentTypeStack.delete(treeNode);
	}
}
```

### Decision procedure: `feature-libraries/modular-schema/minimizeModularChange.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/minimizeModularChange.ts:1-859`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function minimizeModularChangeset(
	change: ModularChangeset,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	forestFactory: () => IEditableForest,
): ModularChangeset {
	return new ModularChangeMinimizer(change, fieldKinds).minimize(forestFactory);
}
class ModularChangeMinimizer {
	private readonly builtNodeIds: ChangeAtomIdBTree<true>;
	private readonly builtRootIds: ChangeAtomIdRangeMap<true>;
	private readonly outputAttachStates: ChangeAtomIdBTree<NodeAttachState>;
	private readonly outputToInputRootId: ChangeAtomIdRangeMap<ChangeAtomId>;
	private readonly rootIdToNodeId: ChangeAtomIdBTree<NodeId>;
	private readonly attachedRootIds: ChangeAtomIdRangeSet;
	public constructor(
		private readonly change: ModularChangeset,
		private readonly fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	) {
		cheapRebaseValidation("Malformed minimize input", () =>
			isChangesetValid(change, fieldKinds),
		);
		this.outputAttachStates = getOutputNodeAttachStates(change, fieldKinds);
		const nodeInfo = getNodeInfo(change, fieldKinds);
		this.builtNodeIds = nodeInfo.builtNodeIds;
		this.builtRootIds = nodeInfo.builtRootIds;
		this.rootIdToNodeId = nodeInfo.rootIdToNodeId;
		const delta = intoDelta(makeAnonChange(change), fieldKinds);
		this.outputToInputRootId = outputToInputRootIdFromDelta(delta);
		this.attachedRootIds = collectAttachedRootIds(delta, this.outputToInputRootId);
	}
	public minimize(forestFactory: () => IEditableForest): ModularChangeset {
		const residualChange = filterEdits(
			this.change,
			this.filterEditsForResidualChange.bind(this),
			this.fieldKinds,
		);
		(residualChange as Mutable<ModularChangeset>).builds = this.squashBuilds(forestFactory);
		cheapRebaseValidation("Malformed minimize output", () =>
			isChangesetValid(residualChange, this.fieldKinds),
		);
		return residualChange;
	}
	private isNodeIdInBuiltTree(nodeId: NodeId | undefined): boolean {
		return (
			nodeId !== undefined &&
			getFromChangeAtomIdMap(
				this.builtNodeIds,
				normalizeNodeId(nodeId, this.change.nodeAliases),
			) === true
		);
	}
	private isNodeDetachedInOutput(nodeId: NodeId): boolean {
		return (
			(getFromChangeAtomIdMap(
				this.outputAttachStates,
				normalizeNodeId(nodeId, this.change.nodeAliases),
			) ?? fail(0xd37  )) ===
			NodeAttachState.Detached
		);
	}
	private isFieldDetachedInOutput(fieldId: FieldId): boolean {
		return fieldId.nodeId !== undefined && this.isNodeDetachedInOutput(fieldId.nodeId);
	}
	private shouldSquashDetach(
		fieldId: FieldId,
		inputRootId: ChangeAtomId | undefined,
	): boolean {
		return this.isNodeIdInBuiltTree(fieldId.nodeId) && inputRootId === undefined;
	}
	private shouldSquashAttach(
		fieldId: FieldId,
		rootInputId: ChangeAtomId,
		count: number,
		endpoint: FieldId | undefined,
	): RangeQueryResult<boolean> {
		if (!this.isNodeIdInBuiltTree(fieldId.nodeId)) {
			return { value: false, length: count };
		}
		let countProcessed = count;
		const isMoveOfBuiltRootEntry = this.builtRootIds.getFirst(rootInputId, countProcessed);
		countProcessed = isMoveOfBuiltRootEntry.length;
		const isAttachOfBuiltRoot = isMoveOfBuiltRootEntry?.value ?? false;
		const isMoveFromBuiltTree =
			endpoint?.nodeId !== undefined && this.isNodeIdInBuiltTree(endpoint.nodeId);
		const isAttachOfBuiltNode = isAttachOfBuiltRoot || isMoveFromBuiltTree;
		return { value: isAttachOfBuiltNode, length: countProcessed };
	}
	private shouldDropAttach(
		fieldId: FieldId,
		rootInputId: ChangeAtomId,
		count: number,
		endpoint: FieldId | undefined,
	): RangeQueryResult<boolean> {
		const isInDetachedTree = this.isFieldDetachedInOutput(fieldId);
		let countProcessed = count;
		const shouldSquashAttachEntry = this.shouldSquashAttach(
			fieldId,
			rootInputId,
			countProcessed,
			endpoint,
		);
		countProcessed = shouldSquashAttachEntry.length;
		const isBuiltRootEntry = this.builtRootIds.getFirst(rootInputId, countProcessed);
		countProcessed = isBuiltRootEntry.length;
		const isAttachOfBuild =
			isBuiltRootEntry.value ??
			(endpoint !== undefined && this.isNodeIdInBuiltTree(endpoint.nodeId));
		const isAttachedRootEntry = this.attachedRootIds.getFirst(rootInputId, countProcessed);
		countProcessed = isAttachedRootEntry.length;
		const isTransientAttachOfBuild = isAttachOfBuild && !isAttachedRootEntry.value;
		return {
			value: isInDetachedTree || shouldSquashAttachEntry.value || isTransientAttachOfBuild,
			length: countProcessed,
		};
	}
	private shouldDropDetach(
		fieldId: FieldId,
		detachId: ChangeAtomId,
		rootInputId: ChangeAtomId | undefined,
		count: number,
		endpoint: FieldId | undefined,
	): RangeQueryResult<boolean> {
		let countProcessed = count;
		if (this.shouldSquashDetach(fieldId, rootInputId)) {
			return { value: true, length: countProcessed };
		}
		if (rootInputId !== undefined) {
			const isDetachOfBuiltRootEntry = this.builtRootIds.getFirst(rootInputId, countProcessed);
			countProcessed = isDetachOfBuiltRootEntry.length;
			const isDetachOfBuiltRoot = isDetachOfBuiltRootEntry.value !== undefined;
			if (isDetachOfBuiltRoot)
				return {
					value: true,
					length: countProcessed,
				};
		}
		if (endpoint !== undefined) {
			const shouldDropAttachEntry = this.shouldDropAttach(
				endpoint,
				rootInputId ?? detachId,
				countProcessed,
				fieldId,
			);
			countProcessed = shouldDropAttachEntry.length;
			if (!shouldDropAttachEntry.value) {
				return { value: false, length: countProcessed };
			}
		}
		return { value: this.isFieldDetachedInOutput(fieldId), length: countProcessed };
	}
	private filterEditsForBuildChange(fieldChange: FieldChange, fieldId: FieldId): FieldChange {
		return {
			...fieldChange,
			change: brand(
				getChangeHandler(this.fieldKinds, fieldChange.fieldKind).rebaser.filterEdits(
					fieldChange.change,
					{
						filterDetach: (detachId, count, inputRootId, endpoint) =>
							this.filterDetachForBuildChange(fieldId, detachId, count, inputRootId, endpoint),
						filterAttach: (id, count, _outputRootId, endpoint) =>
							this.filterAttachForBuildChange(fieldId, id, count, endpoint),
						preserveOtherEdits: false,
					},
				),
			),
		};
	}
	private filterDetachForBuildChange(
		fieldId: FieldId,
		detachId: ChangeAtomId,
		count: number,
		inputRootId: ChangeAtomId | undefined,
		endpoint?: ChangeAtomId,
	): RangeQueryResult<FilterDetachResult> {
		if (!this.shouldSquashDetach(fieldId, inputRootId)) {
			return {
				value: { action: EditFilterStatus.Remove, shouldRemoveChild: false },
				length: count,
			};
		}
		let countProcessed = count;
		const moveEndpointEntry = this.change.crossFieldKeys.getFirst(
			{ ...(endpoint ?? detachId), target: CrossFieldTarget.Destination },
			countProcessed,
		);
		countProcessed = moveEndpointEntry.length;
		if (moveEndpointEntry.value !== undefined) {
			const willSquashEndpointEntry = this.shouldSquashAttach(
				moveEndpointEntry.value,
				inputRootId ?? detachId,
				countProcessed,
				fieldId,
			);
			countProcessed = willSquashEndpointEntry.length;
			const action = willSquashEndpointEntry.value
				? EditFilterStatus.Preserve
				: EditFilterStatus.PreserveWithoutMove;
			return { value: { action }, length: countProcessed };
		}
		return { value: { action: EditFilterStatus.Preserve }, length: countProcessed };
	}
	private filterAttachForBuildChange(
		fieldId: FieldId,
		id: ChangeAtomId,
		count: number,
		endpoint?: ChangeAtomId,
	): RangeQueryResult<FilterAttachResult> {
		let countProcessed = count;
		const moveId = endpoint ?? id;
		const moveEndpointEntry = this.change.crossFieldKeys.getFirst(
			{ ...moveId, target: CrossFieldTarget.Source },
			countProcessed,
		);
		countProcessed = moveEndpointEntry.length;
		const inputIdEntry = this.outputToInputRootId.getFirst(moveId, countProcessed);
		countProcessed = inputIdEntry.length;
		const rootInputId = inputIdEntry.value ?? moveId;
		const shouldSquashEntry = this.shouldSquashAttach(
			fieldId,
			rootInputId,
			countProcessed,
			moveEndpointEntry.value,
		);
		countProcessed = shouldSquashEntry.length;
		const isMove = moveEndpointEntry.value !== undefined;
		if (!shouldSquashEntry.value) {
			return { value: { action: EditFilterStatus.Remove }, length: countProcessed };
		}
		if (isMove) {
			const movedNodeId = getFromChangeAtomIdMap(this.rootIdToNodeId, moveId);
			return {
				value: {
					action: EditFilterStatus.PreserveWithoutMove,
					nodeId: movedNodeId,
					newAttachId: rootInputId,
				},
				length: countProcessed,
			};
		}
		return {
			value: { action: EditFilterStatus.Preserve },
			length: countProcessed,
		};
	}
	private filterEditsForResidualChange(
		fieldChange: FieldChange,
		fieldId: FieldId,
	): FieldChange {
		return {
			...fieldChange,
			change: brand(
				getChangeHandler(this.fieldKinds, fieldChange.fieldKind).rebaser.filterEdits(
					fieldChange.change,
					{
						filterDetach: (...args) => this.filterDetachForResidualChange(fieldId, ...args),
						filterAttach: (...args) => this.filterAttachForResidualChange(fieldId, ...args),
						preserveOtherEdits: false,
					},
				),
			),
		};
	}
	private filterDetachForResidualChange(
		fieldId: FieldId,
		detachId: ChangeAtomId,
		count: number,
		inputRootId: ChangeAtomId | undefined,
		endpoint?: ChangeAtomId,
	): RangeQueryResult<FilterDetachResult> {
		let countProcessed = count;
		const moveId = endpoint ?? detachId;
		const moveEndpointEntry = this.change.crossFieldKeys.getFirst(
			{ ...moveId, target: CrossFieldTarget.Destination },
			count,
		);
		countProcessed = moveEndpointEntry.length;
		const shouldDropEntry = this.shouldDropDetach(
			fieldId,
			detachId,
			inputRootId,
			countProcessed,
			moveEndpointEntry.value,
		);
		countProcessed = shouldDropEntry.length;
		let hasPreservedAttach = false;
		let hasDroppedAttach = false;
		if (moveEndpointEntry.value !== undefined) {
			const willDropAttachEntry = this.shouldDropAttach(
				moveEndpointEntry.value,
				inputRootId ?? detachId,
				countProcessed,
				fieldId,
			);
			countProcessed = willDropAttachEntry.length;
			hasDroppedAttach = willDropAttachEntry.value;
			hasPreservedAttach = !willDropAttachEntry.value;
		}
		if (shouldDropEntry.value) {
			return {
				value: { action: EditFilterStatus.Remove, shouldRemoveChild: hasPreservedAttach },
				length: countProcessed,
			};
		}
		return {
			value: {
				action: hasDroppedAttach
					? EditFilterStatus.PreserveWithoutMove
					: EditFilterStatus.Preserve,
			},
			length: countProcessed,
		};
	}
	private filterAttachForResidualChange(
		fieldId: FieldId,
		id: ChangeAtomId,
		count: number,
		outputRootId: ChangeAtomId | undefined,
		endpoint?: ChangeAtomId,
	): RangeQueryResult<FilterAttachResult> {
		let countProcessed = count;
		const moveId = endpoint ?? id;
		const moveEndpointEntry = this.change.crossFieldKeys.getFirst(
			{ ...moveId, target: CrossFieldTarget.Source },
			countProcessed,
		);
		countProcessed = moveEndpointEntry.length;
		const inputIdEntry = this.outputToInputRootId.getFirst(moveId, countProcessed);
		countProcessed = inputIdEntry.length;
		const rootInputId = inputIdEntry.value ?? moveId;
		const shouldDropEntry = this.shouldDropAttach(
			fieldId,
			rootInputId,
			countProcessed,
			moveEndpointEntry.value,
		);
		countProcessed = shouldDropEntry.length;
		if (shouldDropEntry.value) {
			return {
				value: { action: EditFilterStatus.Remove },
				length: countProcessed,
			};
		}
		if (moveEndpointEntry.value !== undefined) {
			const willDropEndpointEntry = this.shouldDropDetach(
				moveEndpointEntry.value,
				moveId,
				inputIdEntry.value,
				countProcessed,
				fieldId,
			);
			countProcessed = willDropEndpointEntry.length;
			if (willDropEndpointEntry.value) {
				const movedNodeId = getFromChangeAtomIdMap(this.rootIdToNodeId, moveId);
				return {
					value: {
						action: EditFilterStatus.PreserveWithoutMove,
						nodeId: movedNodeId,
						newAttachId: inputIdEntry.value ?? moveId,
					},
					length: countProcessed,
				};
			}
		}
		return {
			value: { action: EditFilterStatus.Preserve },
			length: countProcessed,
		};
	}
	private squashBuilds(forestFactory: () => IEditableForest): ChangeAtomIdBTree<TreeChunk> {
		const changeForBuilds = filterEdits(
			this.change,
			this.filterEditsForBuildChange.bind(this),
			this.fieldKinds,
		);
		const deltaForBuilds = intoDelta(makeAnonChange(changeForBuilds), this.fieldKinds);
		assert(
			!deltaFieldMapHasChanges(deltaForBuilds.fields),
			0xd38  ,
		);
		(deltaForBuilds as Mutable<DeltaRoot<unknown>>).fields = new Map();
		const forest = forestFactory();
		const detachedFieldIndex = makeDetachedFieldIndex();
		visitDelta(deltaForBuilds, forest.acquireVisitor(), detachedFieldIndex, undefined);
		const squashedBuilds = newChangeAtomIdBTree<TreeChunk>();
		const cursor = forest.getCursorAboveDetachedFields();
		for (const entry of detachedFieldIndex.entries()) {
			cursor.enterField(detachedFieldIndex.toFieldKey(entry.root));
			const chunks = forest.chunkField(cursor);
			assert(hasSingle(chunks), 0xd39  );
			const chunk = chunks[0];
			assert(chunk.topLevelLength === 1, 0xd3a  );
			const rootId: ChangeAtomId = {
				revision: entry.id.major,
				localId: brand(entry.id.minor),
			};
			const isAttachedEntry = this.attachedRootIds.getFirst(rootId, chunk.topLevelLength);
			assert(
				isAttachedEntry.length === chunk.topLevelLength,
				0xd3b  ,
			);
			if (isAttachedEntry.value) {
				setInChangeAtomIdMap(squashedBuilds, rootId, chunk);
			}
			cursor.exitField();
		}
		return squashedBuilds;
	}
}
function getOutputNodeAttachStates(
	change: ModularChangeset,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): ChangeAtomIdBTree<NodeAttachState> {
	const inverse = invertModularChange(makeAnonChange(change), true, "root", fieldKinds);
	return getInputNodeAttachStates(inverse, fieldKinds);
}
function getInputNodeAttachStates(
	change: ModularChangeset,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): ChangeAtomIdBTree<NodeAttachState> {
	const nodeAttachStates = newChangeAtomIdBTree<NodeAttachState>();
	addInputNodeAttachStatesForFields(
		NodeAttachState.Attached,
		change.fieldChanges,
		change.nodeChanges,
		change.nodeAliases,
		fieldKinds,
		nodeAttachStates,
	);
	return nodeAttachStates;
}
function addInputNodeAttachStatesForFields(
	parentState: NodeAttachState,
	fields: FieldChangeMap,
	nodes: ChangeAtomIdBTree<NodeChangeset>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	nodeAttachStates: ChangeAtomIdBTree<NodeAttachState>,
): void {
	for (const fieldChange of fields.values()) {
		const children = getChangeHandler(fieldKinds, fieldChange.fieldKind).getNestedChanges(
			fieldChange.change,
		);
		for (const { nodeId, inputRootId: inputId } of children) {
			const normalizedNodeId = normalizeNodeId(nodeId, nodeAliases);
			const attachState =
				parentState === NodeAttachState.Attached && inputId === undefined
					? NodeAttachState.Attached
					: NodeAttachState.Detached;
			nodeAttachStates.set([normalizedNodeId.revision, normalizedNodeId.localId], attachState);
			const nodeChangeset = nodeChangeFromId(nodes, normalizedNodeId, nodeAliases);
			if (nodeChangeset.fieldChanges !== undefined) {
				addInputNodeAttachStatesForFields(
					attachState,
					nodeChangeset.fieldChanges,
					nodes,
					nodeAliases,
					fieldKinds,
					nodeAttachStates,
				);
			}
		}
	}
}
function getNodeInfo(
	change: ModularChangeset,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): {
	readonly builtRootIds: ChangeAtomIdRangeMap<true>;
	readonly builtNodeIds: ChangeAtomIdBTree<true>;
	readonly rootIdToNodeId: ChangeAtomIdBTree<NodeId>;
} {
	const builtRootIds = newChangeAtomIdRangeMap<true>();
	if (change.builds !== undefined) {
		for (const [rootId, chunk] of change.builds.entries()) {
			builtRootIds.set(makeChangeAtomId(rootId[1], rootId[0]), chunk.topLevelLength, true);
		}
	}
	const builtNodeIds = newChangeAtomIdBTree<true>();
	const rootIdToNodeId = newChangeAtomIdBTree<NodeId>();
	addNodeInfoForFields(
		false,
		change.fieldChanges,
		change.nodeChanges,
		change.nodeAliases,
		builtRootIds,
		fieldKinds,
		builtNodeIds,
		rootIdToNodeId,
	);
	return { builtRootIds, builtNodeIds, rootIdToNodeId };
}
function addNodeInfoForFields(
	parentIsBuilt: boolean,
	fields: FieldChangeMap,
	nodes: ChangeAtomIdBTree<NodeChangeset>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
	buildIds: ChangeAtomIdRangeMap<true>,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	builtNodeIds: ChangeAtomIdBTree<true>,
	rootIdToNodeId: ChangeAtomIdBTree<NodeId>,
): void {
	for (const fieldChange of fields.values()) {
		const children = getChangeHandler(fieldKinds, fieldChange.fieldKind).getNestedChanges(
			fieldChange.change,
		);
		for (const { nodeId, inputRootId: inputId, detachId } of children) {
			const normalizedNodeId = normalizeNodeId(nodeId, nodeAliases);
			const isPartOfBuild =
				parentIsBuilt ||
				(inputId !== undefined && buildIds.getFirst(inputId, 1).value === true);
			if (isPartOfBuild) {
				builtNodeIds.set([normalizedNodeId.revision, normalizedNodeId.localId], true);
			}
			if (inputId !== undefined) {
				setInChangeAtomIdMap(rootIdToNodeId, inputId, normalizedNodeId);
			}
			if (detachId !== undefined) {
				setInChangeAtomIdMap(rootIdToNodeId, detachId, normalizedNodeId);
			}
			const nodeChangeset = nodeChangeFromId(nodes, normalizedNodeId, nodeAliases);
			if (nodeChangeset.fieldChanges !== undefined) {
				addNodeInfoForFields(
					isPartOfBuild,
					nodeChangeset.fieldChanges,
					nodes,
					nodeAliases,
					buildIds,
					fieldKinds,
					builtNodeIds,
					rootIdToNodeId,
				);
			}
		}
	}
}
interface ChangeAtomIdRange {
	readonly id: ChangeAtomId;
	readonly count: number;
}
type ChangeAtomIdRangeSet = ChangeAtomIdRangeMap<true>;
function collectAttachedRootIds(
	delta: DeltaRoot,
	outputToInputRootId: ChangeAtomIdRangeMap<ChangeAtomId>,
): ChangeAtomIdRangeSet {
	const detachIdToNodeChanges = getDeltaNodeChangesByDetachId(delta);
	const attached: ChangeAtomIdRangeSet = newChangeAtomIdRangeMap<true>();
	const worklist: ChangeAtomIdRange[] = [];
	const markLive = (attachId: ChangeAtomId, count: number): void => {
		for (const inputIdEntry of outputToInputRootId.getAll(attachId, count)) {
			const inputId = inputIdEntry.value ?? offsetChangeAtomId(attachId, inputIdEntry.offset);
			for (const fragment of attached.getAll(inputId, inputIdEntry.length)) {
				if (fragment.value === undefined) {
					const runStart = offsetChangeAtomId(inputId, fragment.offset);
					attached.set(runStart, fragment.length, true);
					worklist.push({ id: runStart, count: fragment.length });
				}
			}
		}
	};
	const visitLiveFields = (fields: DeltaFieldMap | undefined): void => {
		if (fields === undefined) {
			return;
		}
		for (const field of fields.values()) {
			for (const mark of field.marks) {
				if (mark.attach !== undefined) {
					markLive(
						{ revision: mark.attach.major, localId: brand(mark.attach.minor) },
						mark.count,
					);
				}
				if (mark.detach === undefined) {
					visitLiveFields(mark.fields);
				}
			}
		}
	};
	visitLiveFields(delta.fields);
	while (worklist.length > 0) {
		const next = worklist.pop();
		if (next === undefined) {
			break;
		}
		const { id, count } = next;
		for (let offset = 0; offset < count; offset += 1) {
			visitLiveFields(detachIdToNodeChanges.get(id.revision)?.get(brand(id.localId + offset)));
		}
	}
	return attached;
}
function getDeltaNodeChangesByDetachId(delta: DeltaRoot): ChangeAtomIdMap<DeltaFieldMap> {
	const detachIdToChanges: ChangeAtomIdMap<DeltaFieldMap> = new Map();
	const visitFields = (fields: DeltaFieldMap): void => {
		for (const fieldChange of fields.values()) {
			for (const mark of fieldChange.marks) {
				if (mark.fields !== undefined) {
					visitFields(mark.fields);
					if (mark.detach !== undefined) {
						setInNestedMap(
							detachIdToChanges,
							mark.detach.major,
							mark.detach.minor,
							mark.fields,
						);
					}
				}
			}
		}
	};
	if (delta.fields !== undefined) {
		visitFields(delta.fields);
	}
	if (delta.global !== undefined) {
		for (const { id, fields } of delta.global) {
			setInNestedMap(detachIdToChanges, id.major, id.minor, fields);
			visitFields(fields);
		}
	}
	return detachIdToChanges;
}
function outputToInputRootIdFromDelta(delta: DeltaRoot): ChangeAtomIdRangeMap<ChangeAtomId> {
	const outputToInputRootId = newChangeAtomIdTransform();
	if (delta.rename !== undefined) {
		for (const { oldId, newId, count } of delta.rename) {
			outputToInputRootId.set(
				makeChangeAtomId(brand(newId.minor), newId.major),
				count,
				makeChangeAtomId(brand(oldId.minor), oldId.major),
			);
		}
	}
	return outputToInputRootId;
}
```

### Decision procedure: `feature-libraries/modular-schema/modularChangeFamily.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:1-2630`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class ModularChangeFamily
	implements
		ChangeFamily<ModularEditBuilder, ModularChangeset, ModularChangeFamily>,
		ChangeRebaser<ModularChangeset>
{
	public static readonly emptyChange: ModularChangeset = makeModularChangeset();
	public readonly fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>;
	public readonly validator = (change: ModularChangeset): true | string => {
		return debugOnlyChangesetValidator(change, this.fieldKinds);
	};
	public constructor(
		fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
		public readonly codecs: ICodecFamily<
			ModularChangeset,
			ChangeEncodingContext,
			ChangeDecodingContext
		>,
		public readonly codecOptions: CodecWriteOptions,
	) {
		this.fieldKinds = fieldKinds;
	}
	public get rebaser(): ChangeRebaser<ModularChangeset> {
		return this;
	}
	public hasSchemaChange(_change: ModularChangeset): boolean {
		return false;
	}
	public buildProcessor(
		processFn: ProcessChangeFn<ModularChangeset, ModularChangeFamily>,
	): (change: ModularChangeset) => ModularChangeset {
		return (change: ModularChangeset) => {
			strictRebaseValidation("Malformed processor input", () =>
				isChangesetValid(change, this.fieldKinds),
			);
			const processed = processFn(change, this);
			strictRebaseValidation("Malformed processor output", () =>
				isChangesetValid(processed, this.fieldKinds),
			);
			return processed;
		};
	}
	private normalizeFieldChanges(
		change1: FieldChange,
		change2: FieldChange,
	): {
		fieldKind: FieldKindIdentifier;
		changeHandler: FieldChangeHandler<unknown>;
		change1: FieldChangeset;
		change2: FieldChangeset;
	} {
		const kind =
			change1.fieldKind === genericFieldKind.identifier
				? change2.fieldKind
				: change1.fieldKind;
		if (kind === genericFieldKind.identifier) {
			return {
				fieldKind: genericFieldKind.identifier,
				changeHandler: genericFieldKind.changeHandler,
				change1: change1.change,
				change2: change2.change,
			};
		}
		const changeHandler = getChangeHandler(this.fieldKinds, kind);
		const normalizedChange1 = this.normalizeFieldChange(change1, changeHandler);
		const normalizedChange2 = this.normalizeFieldChange(change2, changeHandler);
		return {
			fieldKind: kind,
			changeHandler,
			change1: normalizedChange1,
			change2: normalizedChange2,
		};
	}
	private normalizeFieldChange<T>(
		fieldChange: FieldChange,
		handler: FieldChangeHandler<T>,
	): FieldChangeset {
		if (fieldChange.fieldKind !== genericFieldKind.identifier) {
			return fieldChange.change;
		}
		const genericChange = fieldChange.change as unknown as GenericChangeset;
		const convertedChange = convertGenericChange(genericChange, handler) as FieldChangeset;
		return convertedChange;
	}
	public compose(changes: TaggedChange<ModularChangeset>[]): ModularChangeset {
		const { revInfos, maxId } = getRevInfoFromTaggedChanges(changes);
		const idState: IdAllocationState = { maxId };
		const pairwiseDelegate = (
			left: ModularChangeset,
			right: ModularChangeset,
		): ModularChangeset => {
			return this.composePair(left, right, revInfos, idState);
		};
		const innerChanges = changes.map((change) => change.change);
		return balancedReduce(innerChanges, pairwiseDelegate, makeModularChangeset);
	}
	private composePair(
		change1: ModularChangeset,
		change2: ModularChangeset,
		revInfos: RevisionInfo[],
		idState: IdAllocationState,
	): ModularChangeset {
		strictRebaseValidation("Malformed composePair input1", () =>
			isChangesetValid(change1, this.fieldKinds),
		);
		strictRebaseValidation("Malformed composePair input2", () =>
			isChangesetValid(change2, this.fieldKinds),
		);
		const { fieldChanges, nodeChanges, nodeToParent, nodeAliases, crossFieldKeys } =
			this.composeAllFields(change1, change2, revInfos, idState);
		const { allBuilds, allDestroys, allRefreshers } = composeBuildsDestroysAndRefreshers(
			change1,
			change2,
		);
		const noChangeConstraint = change1.noChangeConstraint ?? change2.noChangeConstraint;
		const noChangeConstraintOnRevert =
			change1.noChangeConstraintOnRevert ?? change2.noChangeConstraintOnRevert;
		const composed = makeModularChangeset({
			fieldChanges,
			nodeChanges,
			nodeToParent,
			nodeAliases,
			crossFieldKeys,
			maxId: idState.maxId,
			revisions: revInfos,
			noChangeConstraint,
			noChangeConstraintOnRevert,
			builds: allBuilds,
			destroys: allDestroys,
			refreshers: allRefreshers,
		});
		strictRebaseValidation("Malformed composePair output", () =>
			isChangesetValid(composed, this.fieldKinds),
		);
		return composed;
	}
	private composeAllFields(
		potentiallyConflictedChange1: ModularChangeset,
		potentiallyConflictedChange2: ModularChangeset,
		revInfos: RevisionInfo[],
		idState: IdAllocationState,
	): ModularChangesetContent {
		const change1 = this.getEffectiveChange(potentiallyConflictedChange1);
		const change2 = this.getEffectiveChange(potentiallyConflictedChange2);
		const genId: IdAllocator = idAllocatorFromState(idState);
		const revisionMetadata: RevisionMetadataSource = revisionMetadataSourceFromInfo(revInfos);
		const composedNodeChanges: ChangeAtomIdBTree<NodeChangeset> = brand(
			mergeTupleBTrees(change1.nodeChanges, change2.nodeChanges),
		);
		const composedNodeToParent: ChangeAtomIdBTree<FieldId> = brand(
			mergeTupleBTrees(change1.nodeToParent, change2.nodeToParent),
		);
		const crossFieldTable = newComposeTable(change1, change2, composedNodeToParent);
		const composedFields = this.composeFieldMaps(
			change1.fieldChanges,
			change2.fieldChanges,
			undefined,
			genId,
			crossFieldTable,
			revisionMetadata,
		);
		this.composeInvalidatedElements(
			crossFieldTable,
			composedFields,
			composedNodeChanges,
			composedNodeToParent,
			genId,
			revisionMetadata,
		);
		const composedCrossFieldKeys = RangeMap.union(
			change1.crossFieldKeys,
			change2.crossFieldKeys,
		);
		const composedNodeAliases = composeNodeAliases(
			change1.nodeAliases,
			change2.nodeAliases,
			crossFieldTable.newToBaseNodeId,
		);
		return {
			fieldChanges: composedFields,
			nodeChanges: composedNodeChanges,
			nodeToParent: composedNodeToParent,
			nodeAliases: composedNodeAliases,
			crossFieldKeys: composedCrossFieldKeys,
		};
	}
	private composeInvalidatedField(
		fieldChange: FieldChange,
		crossFieldTable: ComposeTable,
		genId: IdAllocator,
		revisionMetadata: RevisionMetadataSource,
	): void {
		const context = crossFieldTable.fieldToContext.get(fieldChange);
		assert(context !== undefined, 0x8cc  );
		const { fieldId, change1: fieldChange1, change2: fieldChange2, composedChange } = context;
		const rebaser = getChangeHandler(this.fieldKinds, composedChange.fieldKind).rebaser;
		const composeNodes = (child1: NodeId | undefined, child2: NodeId | undefined): NodeId => {
			if (
				child1 !== undefined &&
				child2 !== undefined &&
				getFromChangeAtomIdMap(crossFieldTable.newToBaseNodeId, child2) === undefined
			) {
				setInChangeAtomIdMap(crossFieldTable.newToBaseNodeId, child2, child1);
				crossFieldTable.pendingCompositions.nodeIdsToCompose.push([child1, child2]);
			}
			return child1 ?? child2 ?? fail(0xb22  );
		};
		const amendedChange = rebaser.compose(
			fieldChange1,
			fieldChange2,
			composeNodes,
			genId,
			new ComposeManager(crossFieldTable, fieldChange, fieldId, false),
			revisionMetadata,
		);
		composedChange.change = brand(amendedChange);
	}
	private composeInvalidatedElements(
		table: ComposeTable,
		composedFields: FieldChangeMap,
		composedNodes: ChangeAtomIdBTree<NodeChangeset>,
		composedNodeToParent: ChangeAtomIdBTree<FieldId>,
		genId: IdAllocator,
		metadata: RevisionMetadataSource,
	): void {
		const pending = table.pendingCompositions;
		while (
			table.invalidatedFields.size > 0 ||
			pending.nodeIdsToCompose.length > 0 ||
			pending.affectedBaseFields.length > 0 ||
			pending.affectedNewFields.length > 0
		) {
			for (const [id1, id2] of pending.nodeIdsToCompose) {
				this.composeNodesById(
					table.baseChange.nodeChanges,
					table.newChange.nodeChanges,
					composedNodes,
					composedNodeToParent,
					id1,
					id2,
					genId,
					table,
					metadata,
				);
			}
			pending.nodeIdsToCompose.length = 0;
			this.composeAffectedFields(
				table,
				table.baseChange,
				true,
				pending.affectedBaseFields,
				composedFields,
				composedNodes,
				genId,
				metadata,
			);
			this.composeAffectedFields(
				table,
				table.newChange,
				false,
				pending.affectedNewFields,
				composedFields,
				composedNodes,
				genId,
				metadata,
			);
			this.processInvalidatedCompositions(table, genId, metadata);
		}
	}
	private processInvalidatedCompositions(
		table: ComposeTable,
		genId: IdAllocator,
		metadata: RevisionMetadataSource,
	): void {
		const fieldsToUpdate = table.invalidatedFields;
		table.invalidatedFields = new Set();
		for (const fieldChange of fieldsToUpdate) {
			this.composeInvalidatedField(fieldChange, table, genId, metadata);
		}
	}
	private composeAffectedFields(
		table: ComposeTable,
		change: ModularChangeset,
		areBaseFields: boolean,
		affectedFields: BTree<FieldIdKey, true>,
		composedFields: FieldChangeMap,
		composedNodes: ChangeAtomIdBTree<NodeChangeset>,
		genId: IdAllocator,
		metadata: RevisionMetadataSource,
	): void {
		for (const fieldIdKey of affectedFields.keys()) {
			const fieldId = normalizeFieldId(fieldIdFromFieldIdKey(fieldIdKey), change.nodeAliases);
			const fieldChange = fieldChangeFromId(
				change.fieldChanges,
				change.nodeChanges,
				change.nodeAliases,
				fieldId,
			);
			if (
				table.fieldToContext.has(fieldChange) ||
				table.newFieldToBaseField.has(fieldChange)
			) {
				continue;
			}
			const emptyChange = this.createEmptyFieldChange(fieldChange.fieldKind);
			const [change1, change2] = areBaseFields
				? [fieldChange, emptyChange]
				: [emptyChange, fieldChange];
			const composedField = this.composeFieldChanges(
				fieldId,
				change1,
				change2,
				genId,
				table,
				metadata,
			);
			if (fieldId.nodeId === undefined) {
				composedFields.set(fieldId.field, composedField);
				continue;
			}
			const nodeId =
				getFromChangeAtomIdMap(table.newToBaseNodeId, fieldId.nodeId) ?? fieldId.nodeId;
			let nodeChangeset = nodeChangeFromId(
				composedNodes,
				nodeId,
				table.baseChange.nodeAliases,
			);
			if (!table.composedNodes.has(nodeChangeset)) {
				nodeChangeset = cloneNodeChangeset(nodeChangeset);
				setInChangeAtomIdMap(composedNodes, nodeId, nodeChangeset);
			}
			if (nodeChangeset.fieldChanges === undefined) {
				nodeChangeset.fieldChanges = new Map();
			}
			nodeChangeset.fieldChanges.set(fieldId.field, composedField);
		}
		affectedFields.clear();
	}
	private composeFieldMaps(
		change1: FieldChangeMap | undefined,
		change2: FieldChangeMap | undefined,
		parentId: NodeId | undefined,
		genId: IdAllocator,
		crossFieldTable: ComposeTable,
		revisionMetadata: RevisionMetadataSource,
	): FieldChangeMap {
		const composedFields: FieldChangeMap = new Map();
		if (change1 === undefined || change2 === undefined) {
			return change1 ?? change2 ?? composedFields;
		}
		for (const [field, fieldChange1] of change1) {
			const fieldId: FieldId = { nodeId: parentId, field };
			const fieldChange2 = change2.get(field);
			const composedField =
				fieldChange2 === undefined
					? fieldChange1
					: this.composeFieldChanges(
							fieldId,
							fieldChange1,
							fieldChange2,
							genId,
							crossFieldTable,
							revisionMetadata,
						);
			composedFields.set(field, composedField);
		}
		for (const [field, fieldChange2] of change2) {
			if (!change1?.has(field)) {
				composedFields.set(field, fieldChange2);
			}
		}
		return composedFields;
	}
	private composeFieldChanges(
		fieldId: FieldId,
		change1: FieldChange,
		change2: FieldChange,
		idAllocator: IdAllocator,
		crossFieldTable: ComposeTable,
		revisionMetadata: RevisionMetadataSource,
	): FieldChange {
		const {
			fieldKind,
			changeHandler,
			change1: change1Normalized,
			change2: change2Normalized,
		} = this.normalizeFieldChanges(change1, change2);
		const manager = new ComposeManager(crossFieldTable, change1, fieldId);
		const composedChange = changeHandler.rebaser.compose(
			change1Normalized,
			change2Normalized,
			(child1, child2) => {
				if (child1 !== undefined && child2 !== undefined) {
					setInChangeAtomIdMap(crossFieldTable.newToBaseNodeId, child2, child1);
					crossFieldTable.pendingCompositions.nodeIdsToCompose.push([child1, child2]);
				}
				return child1 ?? child2 ?? fail(0xb23  );
			},
			idAllocator,
			manager,
			revisionMetadata,
		);
		const composedField: FieldChange = {
			fieldKind,
			change: brand(composedChange),
		};
		crossFieldTable.fieldToContext.set(change1, {
			fieldId,
			change1: change1Normalized,
			change2: change2Normalized,
			composedChange: composedField,
		});
		crossFieldTable.newFieldToBaseField.set(change2, change1);
		return composedField;
	}
	private composeNodesById(
		nodeChanges1: ChangeAtomIdBTree<NodeChangeset>,
		nodeChanges2: ChangeAtomIdBTree<NodeChangeset>,
		composedNodes: ChangeAtomIdBTree<NodeChangeset>,
		composedNodeToParent: ChangeAtomIdBTree<FieldId>,
		id1: NodeId,
		id2: NodeId,
		idAllocator: IdAllocator,
		crossFieldTable: ComposeTable,
		revisionMetadata: RevisionMetadataSource,
	): void {
		const normalizedId1 = normalizeNodeId(id1, crossFieldTable.baseChange.nodeAliases);
		const normalizedId2 = normalizeNodeId(id2, crossFieldTable.newChange.nodeAliases);
		const nodeChangeset1 = nodeChangeFromId(
			nodeChanges1,
			normalizedId1,
			crossFieldTable.baseChange.nodeAliases,
		);
		const nodeChangeset2 = nodeChangeFromId(
			nodeChanges2,
			normalizedId2,
			crossFieldTable.newChange.nodeAliases,
		);
		const composedNodeChangeset = this.composeNodeChanges(
			normalizedId1,
			nodeChangeset1,
			nodeChangeset2,
			idAllocator,
			crossFieldTable,
			revisionMetadata,
		);
		const parentFieldId = getParentFieldId(crossFieldTable.baseChange, normalizedId1);
		const composedId = id1;
		composedNodes.delete([normalizedId1.revision, normalizedId1.localId]);
		composedNodes.delete([normalizedId2.revision, normalizedId2.localId]);
		composedNodeToParent.delete([normalizedId1.revision, normalizedId1.localId]);
		composedNodeToParent.delete([normalizedId2.revision, normalizedId2.localId]);
		setInChangeAtomIdMap(composedNodes, composedId, composedNodeChangeset);
		setInChangeAtomIdMap(composedNodeToParent, composedId, parentFieldId);
		crossFieldTable.composedNodes.add(composedNodeChangeset);
	}
	private composeNodeChanges(
		nodeId: NodeId,
		change1: NodeChangeset,
		change2: NodeChangeset,
		genId: IdAllocator,
		crossFieldTable: ComposeTable,
		revisionMetadata: RevisionMetadataSource,
	): NodeChangeset {
		const nodeExistsConstraint = change1.nodeExistsConstraint ?? change2.nodeExistsConstraint;
		const nodeExistsConstraintOnRevert =
			change1.nodeExistsConstraintOnRevert ?? change2.nodeExistsConstraintOnRevert;
		const composedFieldChanges = this.composeFieldMaps(
			change1.fieldChanges,
			change2.fieldChanges,
			nodeId,
			genId,
			crossFieldTable,
			revisionMetadata,
		);
		const composedNodeChange: NodeChangeset = {};
		if (composedFieldChanges.size > 0) {
			composedNodeChange.fieldChanges = composedFieldChanges;
		}
		if (nodeExistsConstraint !== undefined) {
			composedNodeChange.nodeExistsConstraint = nodeExistsConstraint;
		}
		if (nodeExistsConstraintOnRevert !== undefined) {
			composedNodeChange.nodeExistsConstraintOnRevert = nodeExistsConstraintOnRevert;
		}
		return composedNodeChange;
	}
	public invert(
		change: TaggedChange<ModularChangeset>,
		isRollback: boolean,
		revisionForInvert: RevisionTag,
	): ModularChangeset {
		return invertModularChange(change, isRollback, revisionForInvert, this.fieldKinds);
	}
	public rebase(
		taggedChange: TaggedChange<ModularChangeset>,
		potentiallyConflictedOver: TaggedChange<ModularChangeset>,
		revisionMetadata: RevisionMetadataSource,
		ignoreNoChangeViolation: boolean = false,
	): ModularChangeset {
		strictRebaseValidation("Malformed rebase input change", () =>
			isChangesetValid(taggedChange.change, this.fieldKinds),
		);
		strictRebaseValidation("Malformed rebase input base", () =>
			isChangesetValid(potentiallyConflictedOver.change, this.fieldKinds),
		);
		const over = mapTaggedChange(
			potentiallyConflictedOver,
			this.getEffectiveChange(potentiallyConflictedOver.change),
		);
		const change = taggedChange.change;
		const maxId = Math.max(change.maxId ?? -1, over.change.maxId ?? -1);
		const idState: IdAllocationState = { maxId };
		const genId: IdAllocator = idAllocatorFromState(idState);
		const crossFieldTable: RebaseTable = {
			...newCrossFieldTable<FieldChange>(),
			newChange: change,
			baseChange: over.change,
			baseFieldToContext: new Map(),
			baseToRebasedNodeId: newChangeAtomIdBTree(),
			rebasedFields: new Set(),
			rebasedNodeToParent: brand(change.nodeToParent.clone()),
			rebasedCrossFieldKeys: change.crossFieldKeys.clone(),
			nodeIdPairs: [],
			affectedBaseFields: newFieldIdKeyBTree(),
			fieldsWithUnattachedChild: new Set(),
		};
		const getBaseRevisions = (): RevisionTag[] =>
			revisionInfoFromTaggedChange(over).map((info) => info.revision);
		const rebaseMetadata: RebaseRevisionMetadata = {
			...revisionMetadata,
			getRevisionToRebase: () => taggedChange.revision,
			getBaseRevisions,
		};
		const rebasedNodes: ChangeAtomIdBTree<NodeChangeset> = brand(change.nodeChanges.clone());
		const rebasedFields = this.rebaseIntersectingFields(
			crossFieldTable,
			rebasedNodes,
			genId,
			rebaseMetadata,
		);
		this.rebaseInvalidatedElements(
			rebasedFields,
			rebasedNodes,
			crossFieldTable,
			rebaseMetadata,
			genId,
		);
		const constraintState = newConstraintState(change.constraintViolationCount ?? 0);
		let noChangeConstraint = change.noChangeConstraint;
		if (
			noChangeConstraint !== undefined &&
			!noChangeConstraint.violated &&
			!ignoreNoChangeViolation
		) {
			noChangeConstraint = { violated: true };
			constraintState.violationCount += 1;
		}
		updateConstraintsForFields(
			rebasedFields,
			NodeAttachState.Attached,
			constraintState,
			rebasedNodes,
			change.nodeAliases,
			this.fieldKinds,
		);
		const rebased = makeModularChangeset({
			fieldChanges: rebasedFields,
			nodeChanges: rebasedNodes,
			nodeToParent: crossFieldTable.rebasedNodeToParent,
			nodeAliases: change.nodeAliases,
			crossFieldKeys: crossFieldTable.rebasedCrossFieldKeys,
			maxId: idState.maxId,
			revisions: change.revisions,
			constraintViolationCount: constraintState.violationCount,
			noChangeConstraint,
			noChangeConstraintOnRevert: change.noChangeConstraintOnRevert,
			builds: change.builds,
			destroys: change.destroys,
			refreshers: change.refreshers,
		});
		return pruneChangeset(rebased, this.fieldKinds);
	}
	private rebaseIntersectingFields(
		crossFieldTable: RebaseTable,
		rebasedNodes: ChangeAtomIdBTree<NodeChangeset>,
		genId: IdAllocator,
		metadata: RebaseRevisionMetadata,
	): FieldChangeMap {
		const change = crossFieldTable.newChange;
		const baseChange = crossFieldTable.baseChange;
		const rebasedFields = this.rebaseFieldMap(
			change.fieldChanges,
			baseChange.fieldChanges,
			undefined,
			genId,
			crossFieldTable,
			metadata,
		);
		for (const [newId, baseId, _attachState] of crossFieldTable.nodeIdPairs) {
			const rebasedNode = this.rebaseNodeChange(
				newId,
				baseId,
				genId,
				crossFieldTable,
				metadata,
			);
			const normalizedNewId = normalizeNodeId(newId, crossFieldTable.newChange.nodeAliases);
			setInChangeAtomIdMap(rebasedNodes, normalizedNewId, rebasedNode);
		}
		return rebasedFields;
	}
	private rebaseFieldsWithoutNewChanges(
		rebasedFields: FieldChangeMap,
		rebasedNodes: ChangeAtomIdBTree<NodeChangeset>,
		crossFieldTable: RebaseTable,
		genId: IdAllocator,
		metadata: RebaseRevisionMetadata,
	): void {
		const baseChange = crossFieldTable.baseChange;
		for (const [revision, localId, fieldKey] of crossFieldTable.affectedBaseFields.keys()) {
			const baseNodeId =
				localId === undefined
					? undefined
					: normalizeNodeId({ revision, localId }, baseChange.nodeAliases);
			const baseFieldChange = fieldMapFromNodeId(
				baseChange.fieldChanges,
				baseChange.nodeChanges,
				baseChange.nodeAliases,
				baseNodeId,
			).get(fieldKey);
			assert(
				baseFieldChange !== undefined,
				0x9c2  ,
			);
			if (crossFieldTable.baseFieldToContext.has(baseFieldChange)) {
				continue;
			}
			const handler = getChangeHandler(this.fieldKinds, baseFieldChange.fieldKind);
			const fieldChange: FieldChange = {
				...baseFieldChange,
				change: brand(handler.createEmpty()),
			};
			const rebasedNodeId =
				baseNodeId === undefined
					? undefined
					: rebasedNodeIdFromBaseNodeId(crossFieldTable, baseNodeId);
			const fieldId: FieldId = { nodeId: rebasedNodeId, field: fieldKey };
			const rebasedField: unknown = handler.rebaser.rebase(
				fieldChange.change,
				baseFieldChange.change,
				noNewChangesRebaseChild,
				genId,
				new RebaseManager(crossFieldTable, baseFieldChange, fieldId),
				metadata,
			);
			const rebasedFieldChange: FieldChange = {
				...baseFieldChange,
				change: brand(rebasedField),
			};
			crossFieldTable.baseFieldToContext.set(baseFieldChange, {
				newChange: fieldChange,
				baseChange: baseFieldChange,
				rebasedChange: rebasedFieldChange,
				fieldId,
				baseNodeIds: [],
			});
			crossFieldTable.rebasedFields.add(rebasedFieldChange);
			this.attachRebasedField(
				rebasedFields,
				rebasedNodes,
				crossFieldTable,
				rebasedFieldChange,
				fieldId,
				genId,
				metadata,
			);
		}
	}
	private rebaseInvalidatedElements(
		rebasedFields: FieldChangeMap,
		rebasedNodes: ChangeAtomIdBTree<NodeChangeset>,
		table: RebaseTable,
		metadata: RebaseRevisionMetadata,
		idAllocator: IdAllocator,
	): void {
		this.rebaseFieldsWithoutNewChanges(
			rebasedFields,
			rebasedNodes,
			table,
			idAllocator,
			metadata,
		);
		this.rebaseFieldsWithUnattachedChild(table, metadata, idAllocator);
		this.rebaseInvalidatedFields(table, metadata, idAllocator);
	}
	private rebaseInvalidatedFields(
		crossFieldTable: RebaseTable,
		rebaseMetadata: RebaseRevisionMetadata,
		genId: IdAllocator,
	): void {
		const fieldsToUpdate = crossFieldTable.invalidatedFields;
		crossFieldTable.invalidatedFields = new Set();
		for (const field of fieldsToUpdate) {
			this.rebaseInvalidatedField(field, crossFieldTable, rebaseMetadata, genId);
		}
	}
	private rebaseFieldsWithUnattachedChild(
		table: RebaseTable,
		metadata: RebaseRevisionMetadata,
		idAllocator: IdAllocator,
	): void {
		for (const field of table.fieldsWithUnattachedChild) {
			table.invalidatedFields.delete(field);
			this.rebaseInvalidatedField(field, table, metadata, idAllocator, true);
		}
	}
	private rebaseInvalidatedField(
		baseField: FieldChange,
		crossFieldTable: RebaseTable,
		rebaseMetadata: RebaseRevisionMetadata,
		genId: IdAllocator,
		allowInval = false,
	): void {
		const context = crossFieldTable.baseFieldToContext.get(baseField);
		assert(context !== undefined, 0x852  );
		const {
			changeHandler,
			change1: fieldChangeset,
			change2: baseChangeset,
		} = this.normalizeFieldChanges(context.newChange, context.baseChange);
		const rebaseChild = (
			curr: NodeId | undefined,
			base: NodeId | undefined,
		): NodeId | undefined => {
			if (curr !== undefined) {
				return curr;
			}
			if (base !== undefined) {
				const normalizedBase = normalizeNodeId(base, crossFieldTable.baseChange.nodeAliases);
				for (const id of context.baseNodeIds) {
					if (areEqualChangeAtomIds(normalizedBase, id)) {
						return normalizedBase;
					}
				}
			}
			return undefined;
		};
		context.rebasedChange.change = brand(
			changeHandler.rebaser.rebase(
				fieldChangeset,
				baseChangeset,
				rebaseChild,
				genId,
				new RebaseManager(crossFieldTable, baseField, context.fieldId, allowInval),
				rebaseMetadata,
			),
		);
	}
	private attachRebasedField(
		rebasedFields: FieldChangeMap,
		rebasedNodes: ChangeAtomIdBTree<NodeChangeset>,
		table: RebaseTable,
		rebasedField: FieldChange,
		{ nodeId, field: fieldKey }: FieldId,
		idAllocator: IdAllocator,
		metadata: RebaseRevisionMetadata,
	): void {
		if (nodeId === undefined) {
			rebasedFields.set(fieldKey, rebasedField);
			return;
		}
		const rebasedNode = getFromChangeAtomIdMap(rebasedNodes, nodeId);
		if (rebasedNode !== undefined) {
			if (rebasedNode.fieldChanges === undefined) {
				rebasedNode.fieldChanges = new Map([[fieldKey, rebasedField]]);
				return;
			}
			assert(!rebasedNode.fieldChanges.has(fieldKey), 0x9c4  );
			rebasedNode.fieldChanges.set(fieldKey, rebasedField);
			return;
		}
		const newNode: NodeChangeset = {
			fieldChanges: new Map([[fieldKey, rebasedField]]),
		};
		setInChangeAtomIdMap(rebasedNodes, nodeId, newNode);
		setInChangeAtomIdMap(table.baseToRebasedNodeId, nodeId, nodeId);
		const parentFieldId = getParentFieldId(table.baseChange, nodeId);
		this.attachRebasedNode(
			rebasedFields,
			rebasedNodes,
			table,
			nodeId,
			parentFieldId,
			idAllocator,
			metadata,
		);
	}
	private attachRebasedNode(
		rebasedFields: FieldChangeMap,
		rebasedNodes: ChangeAtomIdBTree<NodeChangeset>,
		table: RebaseTable,
		baseNodeId: NodeId,
		parentFieldIdBase: FieldId,
		idAllocator: IdAllocator,
		metadata: RebaseRevisionMetadata,
	): void {
		const baseFieldChange = fieldChangeFromId(
			table.baseChange.fieldChanges,
			table.baseChange.nodeChanges,
			table.baseChange.nodeAliases,
			parentFieldIdBase,
		);
		const rebasedFieldId = rebasedFieldIdFromBaseId(table, parentFieldIdBase);
		setInChangeAtomIdMap(table.rebasedNodeToParent, baseNodeId, rebasedFieldId);
		const context = table.baseFieldToContext.get(baseFieldChange);
		if (context !== undefined) {
			context.baseNodeIds.push(baseNodeId);
			table.fieldsWithUnattachedChild.add(baseFieldChange);
			return;
		}
		const handler = getChangeHandler(this.fieldKinds, baseFieldChange.fieldKind);
		const fieldChange: FieldChange = {
			...baseFieldChange,
			change: brand(handler.createEmpty()),
		};
		const rebasedChangeset = handler.rebaser.rebase(
			handler.createEmpty(),
			baseFieldChange.change,
			(_idNew, idBase) => {
				if (idBase === undefined) {
					return undefined;
				}
				const normalizedBase = normalizeNodeId(idBase, table.baseChange.nodeAliases);
				return areEqualChangeAtomIds(normalizedBase, baseNodeId) ? baseNodeId : undefined;
			},
			idAllocator,
			new RebaseManager(table, baseFieldChange, rebasedFieldId),
			metadata,
		);
		const rebasedField: FieldChange = { ...baseFieldChange, change: brand(rebasedChangeset) };
		table.rebasedFields.add(rebasedField);
		table.baseFieldToContext.set(baseFieldChange, {
			newChange: fieldChange,
			baseChange: baseFieldChange,
			rebasedChange: rebasedField,
			fieldId: rebasedFieldId,
			baseNodeIds: [],
		});
		this.attachRebasedField(
			rebasedFields,
			rebasedNodes,
			table,
			rebasedField,
			rebasedFieldId,
			idAllocator,
			metadata,
		);
	}
	private rebaseFieldMap(
		change: FieldChangeMap,
		over: FieldChangeMap,
		parentId: NodeId | undefined,
		genId: IdAllocator,
		crossFieldTable: RebaseTable,
		revisionMetadata: RebaseRevisionMetadata,
	): FieldChangeMap {
		const rebasedFields: FieldChangeMap = new Map();
		const rebaseChild = (
			child: NodeId | undefined,
			baseChild: NodeId | undefined,
			stateChange: NodeAttachState | undefined,
		): NodeId | undefined => {
			if (child !== undefined && baseChild !== undefined) {
				crossFieldTable.nodeIdPairs.push([child, baseChild, stateChange]);
			}
			return child;
		};
		for (const [field, fieldChange] of change) {
			const fieldId: FieldId = { nodeId: parentId, field };
			const baseChange = over.get(field);
			if (baseChange === undefined) {
				rebasedFields.set(field, fieldChange);
				continue;
			}
			const {
				fieldKind,
				changeHandler,
				change1: fieldChangeset,
				change2: baseChangeset,
			} = this.normalizeFieldChanges(fieldChange, baseChange);
			const manager = new RebaseManager(crossFieldTable, baseChange, fieldId);
			const rebasedField = changeHandler.rebaser.rebase(
				fieldChangeset,
				baseChangeset,
				rebaseChild,
				genId,
				manager,
				revisionMetadata,
			);
			const rebasedFieldChange: FieldChange = {
				fieldKind,
				change: brand(rebasedField),
			};
			rebasedFields.set(field, rebasedFieldChange);
			crossFieldTable.baseFieldToContext.set(baseChange, {
				baseChange,
				newChange: fieldChange,
				rebasedChange: rebasedFieldChange,
				fieldId,
				baseNodeIds: [],
			});
			crossFieldTable.rebasedFields.add(rebasedFieldChange);
		}
		return rebasedFields;
	}
	private rebaseNodeChange(
		newId: NodeId,
		baseId: NodeId,
		genId: IdAllocator,
		crossFieldTable: RebaseTable,
		revisionMetadata: RebaseRevisionMetadata,
	): NodeChangeset {
		const change = nodeChangeFromId(
			crossFieldTable.newChange.nodeChanges,
			newId,
			crossFieldTable.newChange.nodeAliases,
		);
		const over = nodeChangeFromId(
			crossFieldTable.baseChange.nodeChanges,
			baseId,
			crossFieldTable.baseChange.nodeAliases,
		);
		const baseMap: FieldChangeMap = over?.fieldChanges ?? new Map<FieldKey, FieldChange>();
		const fieldChanges =
			change.fieldChanges !== undefined && over.fieldChanges !== undefined
				? this.rebaseFieldMap(
						change?.fieldChanges ?? new Map(),
						baseMap,
						newId,
						genId,
						crossFieldTable,
						revisionMetadata,
					)
				: change.fieldChanges;
		const rebasedChange: NodeChangeset = {};
		if (fieldChanges !== undefined && fieldChanges.size > 0) {
			rebasedChange.fieldChanges = fieldChanges;
		}
		if (change?.nodeExistsConstraint !== undefined) {
			rebasedChange.nodeExistsConstraint = change.nodeExistsConstraint;
		}
		if (change?.nodeExistsConstraintOnRevert !== undefined) {
			rebasedChange.nodeExistsConstraintOnRevert = change.nodeExistsConstraintOnRevert;
		}
		setInChangeAtomIdMap(
			crossFieldTable.baseToRebasedNodeId,
			normalizeNodeId(baseId, crossFieldTable.baseChange.nodeAliases),
			newId,
		);
		return rebasedChange;
	}
	public getRevisions(change: ModularChangeset): Set<RevisionTag | undefined> {
		if (change.revisions === undefined || change.revisions.length === 0) {
			return new Set([undefined]);
		}
		const aggregated: Set<RevisionTag | undefined> = new Set();
		for (const revInfo of change.revisions) {
			aggregated.add(revInfo.revision);
		}
		return aggregated;
	}
	public changeRevision(
		change: ModularChangeset,
		replacer: RevisionReplacer,
	): ModularChangeset {
		strictRebaseValidation("Malformed changeRevision input", () =>
			isChangesetValid(change, this.fieldKinds),
		);
		const updatedFields = this.replaceFieldMapRevisions(change.fieldChanges, replacer);
		const updatedNodes = replaceIdMapRevisions(change.nodeChanges, replacer, (nodeChangeset) =>
			this.replaceNodeChangesetRevisions(nodeChangeset, replacer),
		);
		const updatedNodeToParent = replaceIdMapRevisions(
			change.nodeToParent,
			replacer,
			(fieldId) =>
				replaceFieldIdRevision(normalizeFieldId(fieldId, change.nodeAliases), replacer),
		);
		const updated: Mutable<ModularChangeset> = {
			...change,
			fieldChanges: updatedFields,
			nodeChanges: updatedNodes,
			nodeToParent: updatedNodeToParent,
			nodeAliases: newChangeAtomIdBTree(),
			crossFieldKeys: replaceCrossFieldKeyTableRevisions(
				change.crossFieldKeys,
				replacer,
				change.nodeAliases,
			),
		};
		if (change.builds !== undefined) {
			updated.builds = replaceIdMapRevisions(change.builds, replacer);
		}
		if (change.destroys !== undefined) {
			updated.destroys = replaceIdMapRevisions(change.destroys, replacer);
		}
		if (change.refreshers !== undefined) {
			updated.refreshers = replaceIdMapRevisions(change.refreshers, replacer);
		}
		updated.revisions = [{ revision: replacer.updatedRevision }];
		strictRebaseValidation("Malformed changeRevision output", () =>
			isChangesetValid(updated, this.fieldKinds),
		);
		return updated;
	}
	private replaceNodeChangesetRevisions(
		nodeChangeset: NodeChangeset,
		replacer: RevisionReplacer,
	): NodeChangeset {
		const updated = { ...nodeChangeset };
		if (nodeChangeset.fieldChanges !== undefined) {
			updated.fieldChanges = this.replaceFieldMapRevisions(
				nodeChangeset.fieldChanges,
				replacer,
			);
		}
		return updated;
	}
	private replaceFieldMapRevisions(
		fields: FieldChangeMap,
		replacer: RevisionReplacer,
	): FieldChangeMap {
		const updatedFields: FieldChangeMap = new Map();
		for (const [field, fieldChange] of fields) {
			const updatedFieldChange = getChangeHandler(
				this.fieldKinds,
				fieldChange.fieldKind,
			).rebaser.replaceRevisions(fieldChange.change, replacer);
			updatedFields.set(field, { ...fieldChange, change: brand(updatedFieldChange) });
		}
		return updatedFields;
	}
	public buildEditor(
		mintRevisionTag: () => RevisionTag,
		changeReceiver: (change: TaggedChange<ModularChangeset>) => void,
	): ModularEditBuilder {
		return new ModularEditBuilder(
			this.rebaser,
			this.fieldKinds,
			changeReceiver,
			this.codecOptions,
		);
	}
	private createEmptyFieldChange(fieldKind: FieldKindIdentifier): FieldChange {
		const emptyChange = getChangeHandler(this.fieldKinds, fieldKind).createEmpty();
		return { fieldKind, change: brand(emptyChange) };
	}
	private getEffectiveChange(change: ModularChangeset): ModularChangeset {
		if (hasConflicts(change)) {
			return this.muteChange(change);
		}
		return change;
	}
	private muteChange(change: ModularChangeset): ModularChangeset {
		strictRebaseValidation("Malformed muteChange input", () =>
			isChangesetValid(change, this.fieldKinds),
		);
		const muted: Mutable<ModularChangeset> = {
			...change,
			crossFieldKeys: newCrossFieldKeyTable(),
			fieldChanges: this.muteFieldChanges(change.fieldChanges),
			nodeChanges: brand(change.nodeChanges.mapValues((v) => this.muteNodeChange(v))),
		};
		strictRebaseValidation("Malformed muteChange output", () =>
			isChangesetValid(muted, this.fieldKinds),
		);
		return muted;
	}
	private muteNodeChange(change: NodeChangeset): NodeChangeset {
		if (change.fieldChanges === undefined) {
			return change;
		}
		return {
			...change,
			fieldChanges: this.muteFieldChanges(change.fieldChanges),
		};
	}
	private muteFieldChanges(change: FieldChangeMap): FieldChangeMap {
		return new Map(
			Array.from(change.entries(), ([key, value]) => [key, this.muteFieldChange(value)]),
		);
	}
	private muteFieldChange(change: FieldChange): FieldChange {
		const handler = getChangeHandler(this.fieldKinds, change.fieldKind);
		return {
			fieldKind: change.fieldKind,
			change: brand(
				handler.rebaser.filterEdits(change.change, {
					filterDetach: removeAllDetachesFilter,
					filterAttach: removeAllAttachesFilter,
					preserveOtherEdits: false,
				}),
			),
		};
	}
}
function replaceCrossFieldKeyTableRevisions(
	table: CrossFieldKeyTable,
	replacer: RevisionReplacer,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
): CrossFieldKeyTable {
	const updated: CrossFieldKeyTable = newCrossFieldKeyTable();
	for (const entry of table.entries()) {
		const key = entry.start;
		const updatedKey: CrossFieldKey = replacer.getUpdatedAtomId(key, entry.length);
		const field = entry.value;
		const normalizedFieldId = normalizeFieldId(field, nodeAliases);
		const updatedNodeId =
			normalizedFieldId.nodeId === undefined
				? undefined
				: replacer.getUpdatedAtomId(normalizedFieldId.nodeId);
		const updatedValue: FieldId = {
			...normalizedFieldId,
			nodeId: updatedNodeId,
		};
		updated.set(updatedKey, entry.length, updatedValue);
	}
	return updated;
}
function replaceIdMapRevisions<T>(
	map: ChangeAtomIdBTree<T>,
	replacer: RevisionReplacer,
	valueMapper: (value: T) => T = (value) => value,
): ChangeAtomIdBTree<T> {
	const updated = newChangeAtomIdBTree<T>();
	for (const [[revision, localId], value] of map.entries()) {
		const newAtom = replacer.getUpdatedAtomId({ revision, localId });
		updated.set([newAtom.revision, newAtom.localId], valueMapper(value));
	}
	return updated;
}
interface BuildsDestroysAndRefreshers {
	readonly allBuilds: ChangeAtomIdBTree<TreeChunk>;
	readonly allDestroys: ChangeAtomIdBTree<number>;
	readonly allRefreshers: ChangeAtomIdBTree<TreeChunk>;
}
function composeBuildsDestroysAndRefreshers(
	change1: ModularChangeset,
	change2: ModularChangeset,
): BuildsDestroysAndRefreshers {
	const allBuilds: ChangeAtomIdBTree<TreeChunk> = brand(
		mergeTupleBTrees(
			change1.builds ?? newChangeAtomIdBTree(),
			change2.builds ?? newChangeAtomIdBTree(),
			true,
		),
	);
	const allDestroys: ChangeAtomIdBTree<number> = brand(
		mergeTupleBTrees(
			change1.destroys ?? newChangeAtomIdBTree(),
			change2.destroys ?? newChangeAtomIdBTree(),
		),
	);
	const allRefreshers: ChangeAtomIdBTree<TreeChunk> = brand(
		mergeTupleBTrees(
			change1.refreshers ?? newChangeAtomIdBTree(),
			change2.refreshers ?? newChangeAtomIdBTree(),
			true,
		),
	);
	if (change1.destroys !== undefined && change2.builds !== undefined) {
		for (const [key, chunk] of change2.builds.entries()) {
			const destroyCount = change1.destroys.get(key);
			if (destroyCount !== undefined) {
				assert(
					destroyCount === chunk.topLevelLength,
					0x89b  ,
				);
				allBuilds.delete(key);
				allDestroys.delete(key);
			}
		}
	}
	if (change1.builds !== undefined && change2.destroys !== undefined) {
		for (const [key, chunk] of change1.builds.entries()) {
			const destroyCount = change2.destroys.get(key);
			if (destroyCount !== undefined) {
				assert(
					destroyCount === chunk.topLevelLength,
					0x9f0  ,
				);
				allBuilds.delete(key);
				allDestroys.delete(key);
			}
		}
	}
	return { allBuilds, allDestroys, allRefreshers };
}
export function* relevantRemovedRoots(
	change: ModularChangeset,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): Iterable<DeltaDetachedNodeId> {
	yield* relevantRemovedRootsFromFields(
		change.fieldChanges,
		change.nodeChanges,
		change.nodeAliases,
		fieldKinds,
	);
}
function* relevantRemovedRootsFromNode(
	node: NodeId,
	nodeChanges: ChangeAtomIdBTree<NodeChangeset>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): Iterable<DeltaDetachedNodeId> {
	const nodeChangeset = nodeChangeFromId(nodeChanges, node, nodeAliases);
	if (nodeChangeset.fieldChanges !== undefined) {
		yield* relevantRemovedRootsFromFields(
			nodeChangeset.fieldChanges,
			nodeChanges,
			nodeAliases,
			fieldKinds,
		);
	}
}
function* relevantRemovedRootsFromFields(
	change: FieldChangeMap,
	nodeChanges: ChangeAtomIdBTree<NodeChangeset>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): Iterable<DeltaDetachedNodeId> {
	const delegate = (node: NodeId): Iterable<DeltaDetachedNodeId> =>
		relevantRemovedRootsFromNode(node, nodeChanges, nodeAliases, fieldKinds);
	for (const [_, fieldChange] of change) {
		const handler = getChangeHandler(fieldKinds, fieldChange.fieldKind);
		yield* handler.relevantRemovedRoots(fieldChange.change, delegate);
	}
}
export function updateRefreshers(
	change: ModularChangeset,
	getDetachedNode: (id: DeltaDetachedNodeId) => TreeChunk | undefined,
	removedRoots: Iterable<DeltaDetachedNodeId>,
	requireRefreshers: boolean = true,
): ModularChangeset {
	const refreshers = newChangeAtomIdBTree<TreeChunk>();
	const chunkLengths: Map<RevisionTag | undefined, BTree<number, number>> = new Map();
	if (change.builds !== undefined) {
		for (const [[revision, id], chunk] of change.builds.entries()) {
			const lengthTree = getOrCreate(chunkLengths, revision, () => new BTree());
			lengthTree.set(id, chunk.topLevelLength);
		}
	}
	for (const root of removedRoots) {
		if (change.builds !== undefined) {
			const lengthTree = chunkLengths.get(root.major);
			if (lengthTree !== undefined) {
				const lengthPair = lengthTree.getPairOrNextLower(root.minor);
				if (lengthPair !== undefined) {
					const [firstMinor, length] = lengthPair;
					if (root.minor < firstMinor + length) {
						continue;
					}
				}
			}
		}
		const node = getDetachedNode(root);
		if (node === undefined) {
			assert(!requireRefreshers, 0x8cd  );
		} else {
			refreshers.set([root.major, brand(root.minor)], node);
		}
	}
	return makeModularChangeset({
		...change,
		maxId: change.maxId,
		refreshers,
	});
}
export function intoDelta(
	taggedChange: TaggedChange<ModularChangeset>,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): DeltaRoot {
	const change = taggedChange.change;
	const rootDelta: Mutable<DeltaRoot> = {};
	const global: DeltaDetachedNodeChanges[] = [];
	const rename: DeltaDetachedNodeRename[] = [];
	if (!hasConflicts(change)) {
		const fieldDeltas = intoDeltaImpl(
			change.fieldChanges,
			change.nodeChanges,
			change.nodeAliases,
			fieldKinds,
			global,
			rename,
		);
		if (fieldDeltas.size > 0) {
			rootDelta.fields = fieldDeltas;
		}
		if (global.length > 0) {
			rootDelta.global = global;
		}
		if (rename.length > 0) {
			rootDelta.rename = rename;
		}
	}
	if (change.builds && change.builds.size > 0) {
		rootDelta.build = copyDetachedNodes(change.builds);
	}
	if (change.destroys !== undefined && change.destroys.size > 0) {
		const destroys: DeltaDetachedNodeDestruction[] = [];
		for (const [[major, minor], count] of change.destroys.entries()) {
			destroys.push({
				id: makeDetachedNodeId(major, minor),
				count,
			});
		}
		rootDelta.destroy = destroys;
	}
	if (change.refreshers && change.refreshers.size > 0) {
		rootDelta.refreshers = copyDetachedNodes(change.refreshers);
	}
	return rootDelta;
}
function copyDetachedNodes(
	detachedNodes: ChangeAtomIdBTree<TreeChunk>,
): DeltaDetachedNodeBuild[] | undefined {
	const copiedDetachedNodes: DeltaDetachedNodeBuild[] = [];
	for (const [[major, minor], chunk] of detachedNodes.entries()) {
		if (chunk.topLevelLength > 0) {
			chunk.referenceAdded();
			copiedDetachedNodes.push({
				id: makeDetachedNodeId(major, minor),
				trees: chunk,
			});
		}
	}
	return copiedDetachedNodes.length > 0 ? copiedDetachedNodes : undefined;
}
function intoDeltaImpl(
	change: FieldChangeMap,
	nodeChanges: ChangeAtomIdBTree<NodeChangeset>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	global: DeltaDetachedNodeChanges[],
	rename: DeltaDetachedNodeRename[],
): Map<FieldKey, DeltaFieldChanges> {
	const delta: Map<FieldKey, DeltaFieldChanges> = new Map();
	for (const [field, fieldChange] of change) {
		const {
			local: fieldChanges,
			global: fieldGlobal,
			rename: fieldRename,
		} = getChangeHandler(fieldKinds, fieldChange.fieldKind).intoDelta(
			fieldChange.change,
			(childChange): DeltaFieldMap => {
				const nodeChange = nodeChangeFromId(nodeChanges, childChange, nodeAliases);
				return deltaFromNodeChange(
					nodeChange,
					nodeChanges,
					nodeAliases,
					fieldKinds,
					global,
					rename,
				);
			},
		);
		if (fieldChanges !== undefined && fieldChanges.marks.length > 0) {
			delta.set(field, fieldChanges);
		}
		for (const c of fieldGlobal ?? []) {
			global.push(c);
		}
		for (const r of fieldRename ?? []) {
			rename.push(r);
		}
	}
	return delta;
}
function deltaFromNodeChange(
	change: NodeChangeset,
	nodeChanges: ChangeAtomIdBTree<NodeChangeset>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	global: DeltaDetachedNodeChanges[],
	rename: DeltaDetachedNodeRename[],
): DeltaFieldMap {
	if (change.fieldChanges !== undefined) {
		return intoDeltaImpl(
			change.fieldChanges,
			nodeChanges,
			nodeAliases,
			fieldKinds,
			global,
			rename,
		);
	}
	return new Map();
}
export function rebaseRevisionMetadataFromInfo(
	revInfos: readonly RevisionInfo[],
	revisionToRebase: RevisionTag | undefined,
	baseRevisions: (RevisionTag | undefined)[],
): RebaseRevisionMetadata {
	const filteredRevisions: RevisionTag[] = [];
	for (const revision of baseRevisions) {
		if (revision !== undefined) {
			filteredRevisions.push(revision);
		}
	}
	const getBaseRevisions = (): RevisionTag[] => filteredRevisions;
	return {
		...revisionMetadataSourceFromInfo(revInfos),
		getRevisionToRebase: () => revisionToRebase,
		getBaseRevisions,
	};
}
interface RebaseTable extends CrossFieldTable<FieldChange> {
	readonly baseChange: ModularChangeset;
	readonly newChange: ModularChangeset;
	readonly baseFieldToContext: Map<FieldChange, RebaseFieldContext>;
	readonly baseToRebasedNodeId: ChangeAtomIdBTree<NodeId>;
	readonly rebasedFields: Set<FieldChange>;
	readonly rebasedNodeToParent: ChangeAtomIdBTree<FieldId>;
	readonly rebasedCrossFieldKeys: CrossFieldKeyTable;
	readonly nodeIdPairs: [NodeId, NodeId, NodeAttachState | undefined][];
	readonly affectedBaseFields: TupleBTree<FieldIdKey, boolean>;
	readonly fieldsWithUnattachedChild: Set<FieldChange>;
}
type FieldIdKey = readonly [RevisionTag | undefined, ChangesetLocalId | undefined, FieldKey];
interface RebaseFieldContext {
	baseChange: FieldChange;
	newChange: FieldChange;
	rebasedChange: FieldChange;
	fieldId: FieldId;
	baseNodeIds: NodeId[];
}
function newComposeTable(
	baseChange: ModularChangeset,
	newChange: ModularChangeset,
	composedNodeToParent: ChangeAtomIdBTree<FieldId>,
): ComposeTable {
	return {
		...newCrossFieldTable<FieldChange>(),
		baseChange,
		newChange,
		fieldToContext: new Map(),
		newFieldToBaseField: new Map(),
		newToBaseNodeId: newChangeAtomIdBTree(),
		composedNodes: new Set(),
		composedNodeToParent,
		pendingCompositions: {
			nodeIdsToCompose: [],
			affectedBaseFields: newFieldIdKeyBTree(),
			affectedNewFields: newFieldIdKeyBTree(),
		},
	};
}
interface ComposeTable extends CrossFieldTable<FieldChange> {
	readonly baseChange: ModularChangeset;
	readonly newChange: ModularChangeset;
	readonly fieldToContext: Map<FieldChange, ComposeFieldContext>;
	readonly newFieldToBaseField: Map<FieldChange, FieldChange>;
	readonly newToBaseNodeId: ChangeAtomIdBTree<NodeId>;
	readonly composedNodes: Set<NodeChangeset>;
	readonly composedNodeToParent: ChangeAtomIdBTree<FieldId>;
	readonly pendingCompositions: PendingCompositions;
}
interface PendingCompositions {
	readonly nodeIdsToCompose: [NodeId, NodeId][];
	readonly affectedBaseFields: BTree<FieldIdKey, true>;
	readonly affectedNewFields: BTree<FieldIdKey, true>;
}
interface ComposeFieldContext {
	fieldId: FieldId;
	change1: FieldChangeset;
	change2: FieldChangeset;
	composedChange: FieldChange;
}
class RebaseManager extends CrossFieldManagerI<FieldChange> {
	public constructor(
		table: RebaseTable,
		currentField: FieldChange,
		private readonly fieldId: FieldId,
		allowInval = true,
	) {
		super(table, currentField, allowInval);
	}
	public override set(
		target: CrossFieldTarget,
		revision: RevisionTag | undefined,
		id: ChangesetLocalId,
		count: number,
		newValue: unknown,
		invalidateDependents: boolean,
	): void {
		if (invalidateDependents && this.allowInval) {
			const newFieldIds = getFieldsForCrossFieldKey(
				this.table.newChange,
				{
					target,
					revision,
					localId: id,
				},
				count,
			);
			assert(
				newFieldIds.length === 0,
				0x9c6  ,
			);
			const baseFieldIds = getFieldsForCrossFieldKey(
				this.table.baseChange,
				{
					target,
					revision,
					localId: id,
				},
				count,
			);
			assert(
				baseFieldIds.length > 0,
				0x9c7  ,
			);
			for (const baseFieldId of baseFieldIds) {
				this.table.affectedBaseFields.set(
					[baseFieldId.nodeId?.revision, baseFieldId.nodeId?.localId, baseFieldId.field],
					true,
				);
			}
		}
		super.set(target, revision, id, count, newValue, invalidateDependents);
	}
	public override onMoveIn(id: ChangeAtomId): void {
		setInChangeAtomIdMap(this.table.rebasedNodeToParent, id, this.fieldId);
	}
	public override moveKey(
		target: CrossFieldTarget,
		revision: RevisionTag | undefined,
		id: ChangesetLocalId,
		count: number,
	): void {
		this.table.rebasedCrossFieldKeys.set(
			{ target, revision, localId: id },
			count,
			this.fieldId,
		);
	}
	private get table(): RebaseTable {
		return this.crossFieldTable as RebaseTable;
	}
}
class ComposeManager extends CrossFieldManagerI<FieldChange> {
	public constructor(
		table: ComposeTable,
		currentField: FieldChange,
		private readonly fieldId: FieldId,
		allowInval = true,
	) {
		super(table, currentField, allowInval);
	}
	public override set(
		target: CrossFieldTarget,
		revision: RevisionTag | undefined,
		id: ChangesetLocalId,
		count: number,
		newValue: unknown,
		invalidateDependents: boolean,
	): void {
		if (invalidateDependents && this.allowInval) {
			const newFieldIds = getFieldsForCrossFieldKey(
				this.table.newChange,
				{
					target,
					revision,
					localId: id,
				},
				count,
			);
			if (newFieldIds.length > 0) {
				for (const newFieldId of newFieldIds) {
					this.table.pendingCompositions.affectedNewFields.set(
						[newFieldId.nodeId?.revision, newFieldId.nodeId?.localId, newFieldId.field],
						true,
					);
				}
			} else {
				const baseFieldIds = getFieldsForCrossFieldKey(
					this.table.baseChange,
					{
						target,
						revision,
						localId: id,
					},
					count,
				);
				assert(
					baseFieldIds.length > 0,
					0x9c8  ,
				);
				for (const baseFieldId of baseFieldIds) {
					this.table.pendingCompositions.affectedBaseFields.set(
						[baseFieldId.nodeId?.revision, baseFieldId.nodeId?.localId, baseFieldId.field],
						true,
					);
				}
			}
		}
		super.set(target, revision, id, count, newValue, invalidateDependents);
	}
	public override onMoveIn(id: ChangeAtomId): void {
		if (getFromChangeAtomIdMap(this.table.newToBaseNodeId, id) === undefined) {
			setInChangeAtomIdMap(this.table.composedNodeToParent, id, this.fieldId);
		}
	}
	public override moveKey(
		target: CrossFieldTarget,
		revision: RevisionTag | undefined,
		id: ChangesetLocalId,
		count: number,
	): void {
		throw new Error("Moving cross-field keys during compose is currently unsupported");
	}
	private get table(): ComposeTable {
		return this.crossFieldTable as ComposeTable;
	}
}
export class ModularEditBuilder extends EditBuilder<ModularChangeset> {
	private transactionDepth: number = 0;
	private idAllocator: IdAllocator;
	private readonly codecOptions: CodecWriteOptions;
	public constructor(
		private readonly rebaser: ChangeRebaser<ModularChangeset>,
		private readonly fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
		changeReceiver: (change: TaggedChange<ModularChangeset>) => void,
		codecOptions: CodecWriteOptions,
	) {
		super((change: TaggedChange<ModularChangeset>) => {
			strictRebaseValidation("Malformed built change", () =>
				isChangesetValid(change.change, fieldKinds),
			);
			changeReceiver(change);
		});
		this.idAllocator = idAllocatorFromMaxId();
		this.codecOptions = codecOptions;
	}
	public override enterTransaction(): void {
		this.transactionDepth += 1;
		if (this.transactionDepth === 1) {
			this.idAllocator = idAllocatorFromMaxId();
		}
	}
	public override exitTransaction(): void {
		assert(this.transactionDepth > 0, 0x5b9  );
		this.transactionDepth -= 1;
		if (this.transactionDepth === 0) {
			this.idAllocator = idAllocatorFromMaxId();
		}
	}
	public buildTrees(
		firstId: ChangesetLocalId,
		content: TreeChunk,
		revision: RevisionTag,
	): GlobalEditDescription {
		if (content.topLevelLength === 0) {
			return { type: "global", revision };
		}
		content.referenceAdded();
		const builds = newChangeAtomIdBTree<TreeChunk>();
		builds.set([revision, firstId], content);
		return {
			type: "global",
			builds,
			revision,
		};
	}
	public submitChange(
		field: FieldUpPath,
		fieldKind: FieldKindIdentifier,
		change: FieldChangeset,
		revision: RevisionTag,
	): void {
		const localCrossFieldKeys = getChangeHandler(this.fieldKinds, fieldKind).getCrossFieldKeys(
			change,
		);
		const modularChange = buildModularChangesetFromField({
			path: field,
			fieldChange: { fieldKind, change },
			nodeChanges: newChangeAtomIdBTree(),
			nodeToParent: newChangeAtomIdBTree(),
			crossFieldKeys: newCrossFieldKeyTable(),
			idAllocator: this.idAllocator,
			localCrossFieldKeys,
			revision,
		});
		this.applyChange(tagChange(modularChange, revision));
	}
	public submitChanges(changes: EditDescription[], revision: RevisionTag): void {
		const modularChange = this.buildChanges(changes);
		this.applyChange(tagChange(modularChange, revision));
	}
	public buildChanges(changes: EditDescription[]): ModularChangeset {
		const revisions: Set<RevisionTag> = new Set();
		const changeMaps = changes.map((change) => {
			revisions.add(change.revision);
			return makeAnonChange(
				change.type === "global"
					? makeModularChangeset({
							maxId: this.idAllocator.getMaxId(),
							builds: change.builds,
							revisions: [{ revision: change.revision }],
						})
					: buildModularChangesetFromField({
							path: change.field,
							fieldChange: {
								fieldKind: change.fieldKind,
								change: change.change,
							},
							nodeChanges: newChangeAtomIdBTree(),
							nodeToParent: newChangeAtomIdBTree(),
							crossFieldKeys: newCrossFieldKeyTable(),
							idAllocator: this.idAllocator,
							localCrossFieldKeys: getChangeHandler(
								this.fieldKinds,
								change.fieldKind,
							).getCrossFieldKeys(change.change),
							revision: change.revision,
						}),
			);
		});
		const revInfo = [...revisions].map((revision) => ({ revision }));
		const composedChange: Mutable<ModularChangeset> = {
			...this.rebaser.compose(changeMaps),
			revisions: revInfo,
		};
		const maxId: ChangesetLocalId = brand(this.idAllocator.getMaxId());
		if (maxId >= 0) {
			composedChange.maxId = maxId;
		}
		return composedChange;
	}
	public generateId(count?: number): ChangesetLocalId {
		return brand(this.idAllocator.allocate(count));
	}
	public addNodeExistsConstraint(path: UpPath, revision: RevisionTag): void {
		const nodeChange: NodeChangeset = {
			nodeExistsConstraint: { violated: false },
		};
		this.applyChange(
			tagChange(
				buildModularChangesetFromNode({
					path,
					nodeChange,
					nodeChanges: newChangeAtomIdBTree(),
					nodeToParent: newChangeAtomIdBTree(),
					crossFieldKeys: newCrossFieldKeyTable(),
					idAllocator: this.idAllocator,
					revision,
				}),
				revision,
			),
		);
	}
	public addNodeExistsConstraintOnRevert(path: UpPath, revision: RevisionTag): void {
		const nodeChange: NodeChangeset = {
			nodeExistsConstraintOnRevert: { violated: false },
		};
		this.applyChange(
			tagChange(
				buildModularChangesetFromNode({
					path,
					nodeChange,
					nodeChanges: newChangeAtomIdBTree(),
					nodeToParent: newChangeAtomIdBTree(),
					crossFieldKeys: newCrossFieldKeyTable(),
					idAllocator: this.idAllocator,
					revision,
				}),
				revision,
			),
		);
	}
	public addNoChangeConstraint(revision: RevisionTag): void {
		if (lt(this.codecOptions.minVersionForCollab, FluidClientVersion.v2_80)) {
			throw new UsageError(
				`No change constraints require min client version of at least ${FluidClientVersion.v2_80}`,
			);
		}
		const changeset = makeModularChangeset({
			maxId: -1,
			noChangeConstraint: { violated: false },
		});
		this.applyChange(tagChange(changeset, revision));
	}
	public addNoChangeConstraintOnRevert(revision: RevisionTag): void {
		if (lt(this.codecOptions.minVersionForCollab, FluidClientVersion.v2_80)) {
			throw new UsageError(
				`No change constraints require min client version of at least ${FluidClientVersion.v2_80}`,
			);
		}
		const changeset = makeModularChangeset({
			maxId: -1,
			noChangeConstraintOnRevert: { violated: false },
		});
		this.applyChange(tagChange(changeset, revision));
	}
}
function buildModularChangesetFromField(props: {
	path: FieldUpPath;
	fieldChange: FieldChange;
	nodeChanges: ChangeAtomIdBTree<NodeChangeset>;
	nodeToParent: ChangeAtomIdBTree<FieldId>;
	crossFieldKeys: CrossFieldKeyTable;
	localCrossFieldKeys?: CrossFieldKeyRange[];
	revision: RevisionTag;
	idAllocator?: IdAllocator;
	childId?: NodeId;
}): ModularChangeset {
	const {
		path,
		fieldChange,
		nodeChanges,
		nodeToParent,
		crossFieldKeys,
		idAllocator = idAllocatorFromMaxId(),
		localCrossFieldKeys = [],
		childId,
		revision,
	} = props;
	const fieldChanges: FieldChangeMap = new Map([[path.field, fieldChange]]);
	if (path.parent === undefined) {
		for (const { key, count } of localCrossFieldKeys) {
			crossFieldKeys.set(key, count, { nodeId: undefined, field: path.field });
		}
		if (childId !== undefined) {
			setInChangeAtomIdMap(nodeToParent, childId, {
				nodeId: undefined,
				field: path.field,
			});
		}
		return makeModularChangeset({
			fieldChanges,
			nodeChanges,
			nodeToParent,
			crossFieldKeys,
			maxId: idAllocator.getMaxId(),
			revisions: [{ revision }],
		});
	}
	const nodeChangeset: NodeChangeset = {
		fieldChanges,
	};
	const parentId: NodeId = { localId: brand(idAllocator.allocate()), revision };
	for (const { key, count } of localCrossFieldKeys) {
		crossFieldKeys.set(key, count, { nodeId: parentId, field: path.field });
	}
	if (childId !== undefined) {
		setInChangeAtomIdMap(nodeToParent, childId, {
			nodeId: parentId,
			field: path.field,
		});
	}
	return buildModularChangesetFromNode({
		path: path.parent,
		nodeChange: nodeChangeset,
		nodeChanges,
		nodeToParent,
		crossFieldKeys,
		idAllocator,
		revision,
		nodeId: parentId,
	});
}
function buildModularChangesetFromNode(props: {
	path: UpPath;
	nodeChange: NodeChangeset;
	nodeChanges: ChangeAtomIdBTree<NodeChangeset>;
	nodeToParent: ChangeAtomIdBTree<FieldId>;
	crossFieldKeys: CrossFieldKeyTable;
	idAllocator: IdAllocator;
	revision: RevisionTag;
	nodeId?: NodeId;
}): ModularChangeset {
	const {
		path,
		idAllocator,
		revision,
		nodeChanges,
		nodeChange,
		nodeId = { localId: brand(idAllocator.allocate()), revision },
	} = props;
	setInChangeAtomIdMap(nodeChanges, nodeId, nodeChange);
	const fieldChangeset = genericFieldKind.changeHandler.editor.buildChildChanges([
		[path.parentIndex, nodeId],
	]);
	const fieldChange: FieldChange = {
		fieldKind: genericFieldKind.identifier,
		change: fieldChangeset,
	};
	return buildModularChangesetFromField({
		...props,
		path: { parent: path.parent, field: path.parentField },
		fieldChange,
		localCrossFieldKeys: [],
		childId: nodeId,
	});
}
export interface FieldEditDescription {
	type: "field";
	field: FieldUpPath;
	fieldKind: FieldKindIdentifier;
	change: FieldChangeset;
	revision: RevisionTag;
}
export interface GlobalEditDescription {
	type: "global";
	revision: RevisionTag;
	builds?: ChangeAtomIdBTree<TreeChunk>;
}
export type EditDescription = FieldEditDescription | GlobalEditDescription;
function fieldChangeFromId(
	fields: FieldChangeMap,
	nodes: ChangeAtomIdBTree<NodeChangeset>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
	id: FieldId,
): FieldChange {
	const fieldMap = fieldMapFromNodeId(fields, nodes, nodeAliases, id.nodeId);
	return fieldMap.get(id.field) ?? fail(0xb25  );
}
function fieldMapFromNodeId(
	rootFieldMap: FieldChangeMap,
	nodes: ChangeAtomIdBTree<NodeChangeset>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
	nodeId: NodeId | undefined,
): FieldChangeMap {
	if (nodeId === undefined) {
		return rootFieldMap;
	}
	const node = nodeChangeFromId(nodes, nodeId, nodeAliases);
	assert(node.fieldChanges !== undefined, 0x9c9  );
	return node.fieldChanges;
}
function rebasedFieldIdFromBaseId(table: RebaseTable, baseId: FieldId): FieldId {
	if (baseId.nodeId === undefined) {
		return baseId;
	}
	return { ...baseId, nodeId: rebasedNodeIdFromBaseNodeId(table, baseId.nodeId) };
}
function rebasedNodeIdFromBaseNodeId(table: RebaseTable, baseId: NodeId): NodeId {
	return getFromChangeAtomIdMap(table.baseToRebasedNodeId, baseId) ?? baseId;
}
function fieldIdFromFieldIdKey([revision, localId, field]: FieldIdKey): FieldId {
	const nodeId = localId === undefined ? undefined : { revision, localId };
	return { nodeId, field };
}
function cloneNodeChangeset(nodeChangeset: NodeChangeset): NodeChangeset {
	if (nodeChangeset.fieldChanges !== undefined) {
		return { ...nodeChangeset, fieldChanges: new Map(nodeChangeset.fieldChanges) };
	}
	return { ...nodeChangeset };
}
function replaceFieldIdRevision(fieldId: FieldId, replacer: RevisionReplacer): FieldId {
	if (fieldId.nodeId === undefined) {
		return fieldId;
	}
	return {
		...fieldId,
		nodeId: replacer.getUpdatedAtomId(fieldId.nodeId),
	};
}
function noNewChangesRebaseChild(
	child: NodeId | undefined,
	_baseChild: NodeId | undefined,
	_stateChange: NodeAttachState | undefined,
): NodeId | undefined {
	assert(child === undefined, 0x9c3  );
	return undefined;
}
interface ModularChangesetContent {
	fieldChanges: FieldChangeMap;
	nodeChanges: ChangeAtomIdBTree<NodeChangeset>;
	nodeToParent: ChangeAtomIdBTree<FieldId>;
	nodeAliases: ChangeAtomIdBTree<NodeId>;
	crossFieldKeys: CrossFieldKeyTable;
}
function newFieldIdKeyBTree<V>(): TupleBTree<FieldIdKey, V> {
	return newTupleBTree(compareFieldIdKeys);
}
const compareFieldIdKeys = createTupleComparator([
	comparePartialRevisions,
	comparePartialChangesetLocalIds,
	compareStrings<FieldKey>,
]);
function composeNodeAliases(
	aliases1: ChangeAtomIdBTree<NodeId>,
	aliases2: ChangeAtomIdBTree<NodeId>,
	nodeId2ToId1: ChangeAtomIdBTree<NodeId>,
): ChangeAtomIdBTree<NodeId> {
	const composedNodeAliases: ChangeAtomIdBTree<NodeId> = brand(
		mergeTupleBTrees(aliases1, aliases2),
	);
	for (const [id2Key, id1] of nodeId2ToId1.entries()) {
		const id2 = makeChangeAtomId(id2Key[1], id2Key[0]);
		if (!areEqualChangeAtomIds(id2, id1)) {
			setInChangeAtomIdMap(composedNodeAliases, id2, id1);
			composedNodeAliases.delete([id1.revision, id1.localId]);
		}
	}
	return composedNodeAliases;
}
```

### Decision procedure: `feature-libraries/modular-schema/modularChangeTypes.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeTypes.ts:1-143`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface ModularChangeset extends Readonly<HasFieldChanges> {
	readonly maxId?: ChangesetLocalId;
	readonly revisions?: readonly RevisionInfo[];
	readonly fieldChanges: FieldChangeMap;
	readonly nodeChanges: ChangeAtomIdBTree<NodeChangeset>;
	readonly nodeToParent: ChangeAtomIdBTree<FieldId>;
	readonly nodeAliases: ChangeAtomIdBTree<NodeId>;
	readonly crossFieldKeys: CrossFieldKeyTable;
	readonly constraintViolationCount?: number;
	readonly noChangeConstraint?: NoChangeConstraint;
	readonly noChangeConstraintOnRevert?: NoChangeConstraint;
	readonly builds?: ChangeAtomIdBTree<TreeChunk>;
	readonly destroys?: ChangeAtomIdBTree<number>;
	readonly refreshers?: ChangeAtomIdBTree<TreeChunk>;
}
export type CrossFieldKeyTable = RangeMap<CrossFieldKey, FieldId>;
export function newCrossFieldKeyTable(): CrossFieldKeyTable {
	return new RangeMap(offsetCrossFieldKey, subtractCrossFieldKeys);
}
function offsetCrossFieldKey(key: CrossFieldKey, offset: number): CrossFieldKey {
	return {
		...key,
		localId: brand(key.localId + offset),
	};
}
function subtractCrossFieldKeys(a: CrossFieldKey, b: CrossFieldKey): number {
	const cmpTarget = a.target - b.target;
	if (cmpTarget !== 0) {
		return cmpTarget * Number.POSITIVE_INFINITY;
	}
	return subtractChangeAtomIds(a, b);
}
export interface CrossFieldKey extends ChangeAtomId {
	readonly target: CrossFieldTarget;
}
export interface CrossFieldKeyRange {
	readonly key: CrossFieldKey;
	readonly count: number;
}
export interface FieldId {
	readonly nodeId: NodeId | undefined;
	readonly field: FieldKey;
}
export interface NodeExistsConstraint {
	violated: boolean;
}
export interface NoChangeConstraint {
	violated: boolean;
}
export interface NodeChangeset extends HasFieldChanges {
	nodeExistsConstraint?: NodeExistsConstraint;
	nodeExistsConstraintOnRevert?: NodeExistsConstraint;
}
export type NodeId = ChangeAtomId;
export interface HasFieldChanges {
	fieldChanges?: FieldChangeMap;
}
export type FieldChangeMap = Map<FieldKey, FieldChange>;
export interface FieldChange {
	readonly fieldKind: FieldKindIdentifier;
	change: FieldChangeset;
}
export type FieldChangeset = Brand<unknown, "FieldChangeset">;
```

### Decision procedure: `feature-libraries/modular-schema/modularChangeUtils.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeUtils.ts:1-837`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function hasConflicts(change: ModularChangeset): boolean {
	return (change.constraintViolationCount ?? 0) > 0;
}
export function makeModularChangeset(
	props: Partial<Omit<ModularChangeset, "maxId">> & { maxId?: number } = {},
): ModularChangeset {
	const p = props;
	const changeset: Mutable<ModularChangeset> = {
		fieldChanges: p.fieldChanges ?? new Map<FieldKey, FieldChange>(),
		nodeChanges: p.nodeChanges ?? newChangeAtomIdBTree(),
		nodeToParent: p.nodeToParent ?? newChangeAtomIdBTree(),
		nodeAliases: p.nodeAliases ?? newChangeAtomIdBTree(),
		crossFieldKeys: p.crossFieldKeys ?? newCrossFieldKeyTable(),
	};
	if (p.revisions !== undefined && p.revisions.length > 0) {
		changeset.revisions = p.revisions;
	}
	if (p.maxId !== undefined && p.maxId >= 0) {
		changeset.maxId = brand(p.maxId);
	}
	if (p.constraintViolationCount !== undefined && p.constraintViolationCount > 0) {
		changeset.constraintViolationCount = p.constraintViolationCount;
	}
	if (p.noChangeConstraint !== undefined) {
		changeset.noChangeConstraint = p.noChangeConstraint;
	}
	if (p.noChangeConstraintOnRevert !== undefined) {
		changeset.noChangeConstraintOnRevert = p.noChangeConstraintOnRevert;
	}
	if (p.builds !== undefined && p.builds.size > 0) {
		changeset.builds = p.builds;
	}
	if (p.destroys !== undefined && p.destroys.size > 0) {
		changeset.destroys = p.destroys;
	}
	if (p.refreshers !== undefined && p.refreshers.size > 0) {
		changeset.refreshers = p.refreshers;
	}
	return changeset;
}
export interface CrossFieldTable<TFieldData> {
	srcTable: CrossFieldMap<unknown>;
	dstTable: CrossFieldMap<unknown>;
	srcDependents: CrossFieldMap<TFieldData>;
	dstDependents: CrossFieldMap<TFieldData>;
	invalidatedFields: Set<TFieldData>;
}
export abstract class CrossFieldManagerI<T> implements CrossFieldManager {
	public constructor(
		protected readonly crossFieldTable: CrossFieldTable<T>,
		private readonly currentFieldKey: T,
		protected readonly allowInval = true,
	) {}
	public set(
		target: CrossFieldTarget,
		revision: RevisionTag | undefined,
		id: ChangesetLocalId,
		count: number,
		newValue: unknown,
		invalidateDependents: boolean,
	): void {
		if (invalidateDependents && this.allowInval) {
			const lastChangedId = (id as number) + count - 1;
			let firstId = id;
			while (firstId <= lastChangedId) {
				const dependentEntry = getFirstFromCrossFieldMap(
					this.getDependents(target),
					revision,
					firstId,
					lastChangedId - firstId + 1,
				);
				if (dependentEntry.value !== undefined) {
					this.crossFieldTable.invalidatedFields.add(dependentEntry.value);
				}
				firstId = brand(firstId + dependentEntry.length);
			}
		}
		setInCrossFieldMap(this.getMap(target), revision, id, count, newValue);
	}
	public get(
		target: CrossFieldTarget,
		revision: RevisionTag | undefined,
		id: ChangesetLocalId,
		count: number,
		addDependency: boolean,
	): RangeQueryResult<unknown> {
		if (addDependency) {
			setInCrossFieldMap(
				this.getDependents(target),
				revision,
				id,
				count,
				this.currentFieldKey,
			);
		}
		return getFirstFromCrossFieldMap(this.getMap(target), revision, id, count);
	}
	public abstract onMoveIn(id: NodeId): void;
	public abstract moveKey(
		target: CrossFieldTarget,
		revision: RevisionTag | undefined,
		id: ChangesetLocalId,
		count: number,
	): void;
	private getMap(target: CrossFieldTarget): CrossFieldMap<unknown> {
		return target === CrossFieldTarget.Source
			? this.crossFieldTable.srcTable
			: this.crossFieldTable.dstTable;
	}
	private getDependents(target: CrossFieldTarget): CrossFieldMap<T> {
		return target === CrossFieldTarget.Source
			? this.crossFieldTable.srcDependents
			: this.crossFieldTable.dstDependents;
	}
}
export function newCrossFieldTable<T>(): CrossFieldTable<T> {
	return {
		srcTable: newChangeAtomIdRangeMap(),
		dstTable: newChangeAtomIdRangeMap(),
		srcDependents: newChangeAtomIdRangeMap(),
		dstDependents: newChangeAtomIdRangeMap(),
		invalidatedFields: new Set(),
	};
}
export function getRevInfoFromTaggedChanges(changes: TaggedChange<ModularChangeset>[]): {
	revInfos: RevisionInfo[];
	maxId: ChangesetLocalId;
} {
	let maxId = -1;
	const revInfos: RevisionInfo[] = [];
	const revisions = new Set<RevisionTag>();
	for (const taggedChange of changes) {
		const change = taggedChange.change;
		maxId = Math.max(change.maxId ?? -1, maxId);
		const infosToAdd = revisionInfoFromTaggedChange(taggedChange);
		for (const info of infosToAdd) {
			if (!revisions.has(info.revision)) {
				revisions.add(info.revision);
				revInfos.push(info);
			}
		}
	}
	const rolledBackRevisions: RevisionTag[] = [];
	for (const info of revInfos) {
		if (info.rollbackOf !== undefined) {
			rolledBackRevisions.push(info.rollbackOf);
		}
	}
	rolledBackRevisions.reverse();
	for (const revision of rolledBackRevisions) {
		if (!revisions.has(revision)) {
			revInfos.push({ revision });
		}
	}
	return { maxId: brand(maxId), revInfos };
}
export function revisionInfoFromTaggedChange(
	taggedChange: TaggedChange<ModularChangeset>,
): RevisionInfo[] {
	const revInfos: RevisionInfo[] = [];
	if (taggedChange.change.revisions !== undefined) {
		revInfos.push(...taggedChange.change.revisions);
	} else if (taggedChange.revision !== undefined) {
		const info: Mutable<RevisionInfo> = { revision: taggedChange.revision };
		if (taggedChange.rollbackOf !== undefined) {
			info.rollbackOf = taggedChange.rollbackOf;
		}
		revInfos.push(info);
	}
	return revInfos;
}
export function getChangeHandler(
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	kind: FieldKindIdentifier,
): FieldChangeHandler<unknown> {
	return getFieldKind(fieldKinds, kind).changeHandler;
}
function getFieldKind(
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	kind: FieldKindIdentifier,
): FlexFieldKind {
	if (kind === genericFieldKind.identifier) {
		return genericFieldKind;
	}
	const fieldKind = fieldKinds.get(kind);
	assert(fieldKind !== undefined, 0x3ad  );
	return fieldKind;
}
export interface ConstraintState {
	violationCount: number;
}
export function newConstraintState(violationCount: number): ConstraintState {
	return {
		violationCount,
	};
}
export function updateConstraintsForFields(
	fields: FieldChangeMap,
	parentInputAttachState: NodeAttachState,
	constraintState: ConstraintState,
	nodes: ChangeAtomIdBTree<NodeChangeset>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): void {
	for (const field of fields.values()) {
		const handler = getChangeHandler(fieldKinds, field.fieldKind);
		for (const { nodeId, inputRootId } of handler.getNestedChanges(field.change)) {
			const isInputDetached = inputRootId !== undefined;
			const inputAttachState =
				parentInputAttachState === NodeAttachState.Detached || isInputDetached
					? NodeAttachState.Detached
					: NodeAttachState.Attached;
			updateConstraintsForNode(
				nodeId,
				inputAttachState,
				nodes,
				nodeAliases,
				constraintState,
				fieldKinds,
			);
		}
	}
}
function updateConstraintsForNode(
	nodeId: NodeId,
	inputAttachState: NodeAttachState,
	nodes: ChangeAtomIdBTree<NodeChangeset>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
	constraintState: ConstraintState,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): void {
	const node = nodeChangeFromId(nodes, nodeId, nodeAliases);
	if (node.nodeExistsConstraint !== undefined) {
		const isNowViolated = inputAttachState === NodeAttachState.Detached;
		if (node.nodeExistsConstraint.violated !== isNowViolated) {
			node.nodeExistsConstraint = {
				...node.nodeExistsConstraint,
				violated: isNowViolated,
			};
			constraintState.violationCount += isNowViolated ? 1 : -1;
		}
	}
	if (node.fieldChanges !== undefined) {
		updateConstraintsForFields(
			node.fieldChanges,
			inputAttachState,
			constraintState,
			nodes,
			nodeAliases,
			fieldKinds,
		);
	}
}
export function nodeChangeFromId(
	nodes: ChangeAtomIdBTree<NodeChangeset>,
	id: NodeId,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
): NodeChangeset {
	const normalizedId = normalizeNodeId(id, nodeAliases);
	const node = getFromChangeAtomIdMap(nodes, normalizedId);
	assert(node !== undefined, 0x9ca  );
	return node;
}
export function normalizeNodeId(
	nodeId: NodeId,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
): NodeId {
	const visited = newChangeAtomIdBTree<true>();
	let currentId = nodeId;
	while (true) {
		visited.set([currentId.revision, currentId.localId], true);
		const dealiased = getFromChangeAtomIdMap(nodeAliases, currentId);
		if (dealiased === undefined) {
			return currentId;
		}
		assert(!visited.has([dealiased.revision, dealiased.localId]), 0xd42  );
		currentId = dealiased;
	}
}
export function makeChangesetInversions(
	fields: FieldChangeMap,
	nodes: ChangeAtomIdBTree<NodeChangeset>,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
): { crossFieldKeys: CrossFieldKeyTable; nodeToParent: ChangeAtomIdBTree<FieldId> } {
	const crossFieldKeys: CrossFieldKeyTable = newCrossFieldKeyTable();
	const nodeToParent: ChangeAtomIdBTree<FieldId> = newChangeAtomIdBTree();
	populateInversionsFromFieldMap(
		fields,
		undefined,
		fieldKinds,
		crossFieldKeys,
		nodeToParent,
		nodeAliases,
	);
	nodes.forEachPair(([revision, localId], node) => {
		if (node.fieldChanges !== undefined) {
			populateInversionsFromFieldMap(
				node.fieldChanges,
				{
					revision,
					localId,
				},
				fieldKinds,
				crossFieldKeys,
				nodeToParent,
				nodeAliases,
			);
		}
	});
	return { crossFieldKeys, nodeToParent };
}
function populateInversionsFromFieldMap(
	fields: FieldChangeMap,
	parent: NodeId | undefined,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	crossFieldKeys: CrossFieldKeyTable,
	nodeToParent: ChangeAtomIdBTree<FieldId>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
): void {
	for (const [fieldKey, fieldChange] of fields) {
		const handler = getChangeHandler(fieldKinds, fieldChange.fieldKind);
		for (const { key, count } of handler.getCrossFieldKeys(fieldChange.change)) {
			crossFieldKeys.set(key, count, { nodeId: parent, field: fieldKey });
		}
		for (const { nodeId } of handler.getNestedChanges(fieldChange.change)) {
			const normalizedNodeId = normalizeNodeId(nodeId, nodeAliases);
			nodeToParent.set([normalizedNodeId.revision, normalizedNodeId.localId], {
				nodeId: parent,
				field: fieldKey,
			});
		}
	}
}
export function fieldKindsFromConfiguration(
	configuration: FieldKindConfiguration,
): ReadonlyMap<FieldKindIdentifier, FlexFieldKind> {
	return new Map(Array.from(configuration.values(), ({ kind }) => [kind.identifier, kind]));
}
export interface ValidationOptions {
	ignoreCrossFieldTable?: boolean;
}
export function validateChangeset(
	change: ModularChangeset,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	options: ValidationOptions = {},
): void {
	const result = isChangesetValid(change, fieldKinds, options);
	if (result !== true) {
		throw new Error(`Malformed changeset: ${result}`);
	}
}
export let debugOnlyChangesetValidator: (
	change: ModularChangeset,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	options?: ValidationOptions,
) => true | string = () => true;
skipInProduction(() => {
	debugOnlyChangesetValidator = isChangesetValid;
});
export function isChangesetValid(
	change: ModularChangeset,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	options: ValidationOptions = {},
): true | string {
	for (const [revision, localId] of change.nodeChanges.keys()) {
		if (change.nodeAliases.has([revision, localId])) {
			return `Node change table contains a non-normalized NodeId key: ${JSON.stringify({ revision, localId })}`;
		}
	}
	for (const [revision, localId] of change.nodeToParent.keys()) {
		if (change.nodeAliases.has([revision, localId])) {
			return `Node parentage table contains a non-normalized NodeId key: ${JSON.stringify({ revision, localId })}`;
		}
	}
	const unreachableNodes: ChangeAtomIdBTree<FieldId> = brand(change.nodeToParent.clone());
	const rootFieldResult = validateFieldChanges(
		change,
		change.fieldChanges,
		undefined,
		fieldKinds,
		unreachableNodes,
		options,
	);
	if (rootFieldResult !== true) {
		return rootFieldResult;
	}
	for (const [[revision, localId], node] of change.nodeChanges.entries()) {
		if (node.fieldChanges === undefined) {
			continue;
		}
		const nodeId: NodeId = { revision, localId };
		const fieldResult = validateFieldChanges(
			change,
			node.fieldChanges,
			nodeId,
			fieldKinds,
			unreachableNodes,
			options,
		);
		if (fieldResult !== true) {
			return fieldResult;
		}
	}
	if (unreachableNodes.size > 0) {
		return `${unreachableNodes.size} unreachable nodes found`;
	}
	for (const [revision, localId] of change.nodeChanges.keys()) {
		if (!change.nodeToParent.has([revision, localId])) {
			return `Node change table contains unparented NodeId ${JSON.stringify({ revision, localId })}`;
		}
	}
	for (const [revision, localId] of change.nodeToParent.keys()) {
		if (!change.nodeChanges.has([revision, localId])) {
			return `Node to parent table contains NodeId with no entry in the node change table: ${JSON.stringify({ revision, localId })}`;
		}
	}
	return true;
}
function validateFieldChanges(
	change: ModularChangeset,
	fieldChanges: FieldChangeMap,
	nodeParent: NodeId | undefined,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	unreachableNodes: ChangeAtomIdBTree<FieldId>,
	options: ValidationOptions = {},
): true | string {
	for (const [field, fieldChange] of fieldChanges.entries()) {
		const fieldId = normalizeFieldId({ nodeId: nodeParent, field }, change.nodeAliases);
		const handler = getChangeHandler(fieldKinds, fieldChange.fieldKind);
		for (const { nodeId } of handler.getNestedChanges(fieldChange.change)) {
			const normalizedNodeId = normalizeNodeId(nodeId, change.nodeAliases);
			const parentFieldId = getFromChangeAtomIdMap(change.nodeToParent, normalizedNodeId);
			if (parentFieldId === undefined) {
				return `NodeId ${JSON.stringify(normalizedNodeId)} is missing from the nodeToParent table`;
			}
			const normalizedParentFieldId = normalizeFieldId(parentFieldId, change.nodeAliases);
			if (!areEqualFieldIds(normalizedParentFieldId, fieldId)) {
				return "Inconsistent node location";
			}
			if (!unreachableNodes.has([normalizedNodeId.revision, normalizedNodeId.localId])) {
				return `Node ${JSON.stringify(normalizedNodeId)} is either missing from the nodeToParent table or is reachable in multiple locations`;
			}
			unreachableNodes.delete([normalizedNodeId.revision, normalizedNodeId.localId]);
		}
		if (!(options.ignoreCrossFieldTable ?? false)) {
			const keysInChange = handler.getCrossFieldKeys(fieldChange.change);
			for (const keyRange of keysInChange) {
				const fields = getFieldsForCrossFieldKey(change, keyRange.key, keyRange.count);
				if (!hasSome(fields)) {
					return `Cross-field key ${JSON.stringify(keyRange.key)} is missing in the cross-field key table`;
				}
				if (fields.some((f) => !areEqualFieldIds(f, fieldId))) {
					return `Cross-field key table is pointing to the wrong field for key ${JSON.stringify(keyRange.key)}`;
				}
			}
			skipInProduction(() => {
				if (RebaseValidation.currentLevel === RebaseValidation.Level.Strict) {
					const countInChange = keysInChange.reduce((acc, { count }) => acc + count, 0);
					const keysInTable = change.crossFieldKeys
						.entries()
						.filter(({ value }) =>
							areEqualFieldIds(normalizeFieldId(value, change.nodeAliases), fieldId),
						);
					const countInTable = keysInTable.reduce((acc, { length }) => acc + length, 0);
					if (countInChange !== countInTable) {
						return `Mismatch between cross-field key table and changeset for field ${JSON.stringify(fieldId)}`;
					}
				}
			});
		}
	}
	return true;
}
export function getParentFieldId(changeset: ModularChangeset, nodeId: NodeId): FieldId {
	const normalizedNodeId = normalizeNodeId(nodeId, changeset.nodeAliases);
	const parentId = getFromChangeAtomIdMap(changeset.nodeToParent, normalizedNodeId);
	assert(parentId !== undefined, 0x9cb  );
	return normalizeFieldId(parentId, changeset.nodeAliases);
}
export function normalizeFieldId(
	fieldId: FieldId,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
): FieldId {
	return fieldId.nodeId === undefined
		? fieldId
		: { ...fieldId, nodeId: normalizeNodeId(fieldId.nodeId, nodeAliases) };
}
export function getFieldsForCrossFieldKey(
	changeset: ModularChangeset,
	key: CrossFieldKey,
	count: number,
): FieldId[] {
	const fieldIds: FieldId[] = [];
	for (const { value: fieldId } of changeset.crossFieldKeys.getAll(key, count)) {
		if (fieldId !== undefined) {
			fieldIds.push(normalizeFieldId(fieldId, changeset.nodeAliases));
		}
	}
	return fieldIds;
}
function areEqualFieldIds(a: FieldId, b: FieldId): boolean {
	return areEqualChangeAtomIdOpts(a.nodeId, b.nodeId) && a.field === b.field;
}
const throws = (): never => {
	throw new Error("Unexpected call inside dummy chunk");
};
function makeDummyChunk(chunk: TreeChunk): TreeChunk {
	return {
		topLevelLength: chunk.topLevelLength,
		cursor: throws,
		referenceAdded: throws,
		referenceRemoved: throws,
		isShared: throws,
	};
}
export function normalizeChangeset(
	change: ModularChangeset,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	dropRevertConstraint: boolean,
	dropRevisionInfo: boolean,
	chunkNormalizer: (chunk: TreeChunk) => TreeChunk,
): ModularChangeset {
	const idAllocator = idAllocatorFromMaxId();
	const idRemappings: ChangeAtomIdMap<NodeId> = new Map();
	const nodeChanges: ChangeAtomIdBTree<NodeChangeset> = newChangeAtomIdBTree();
	const nodeToParent: ChangeAtomIdBTree<FieldId> = newChangeAtomIdBTree();
	const crossFieldKeyTable: CrossFieldKeyTable = newCrossFieldKeyTable();
	const remapNodeId = (nodeId: NodeId): NodeId => {
		const normalizedId = normalizeNodeId(nodeId, change.nodeAliases);
		const newId = tryGetFromNestedMap(
			idRemappings,
			normalizedId.revision,
			normalizedId.localId,
		);
		assert(newId !== undefined, 0xd98  );
		return newId;
	};
	const remapFieldId = (fieldId: FieldId): FieldId => {
		return fieldId.nodeId === undefined
			? fieldId
			: { ...fieldId, nodeId: remapNodeId(fieldId.nodeId) };
	};
	const normalizeNodeChanges = (nodeId: NodeId): NodeId => {
		const normalizedId = normalizeNodeId(nodeId, change.nodeAliases);
		const nodeChangeset = change.nodeChanges.get([
			normalizedId.revision,
			normalizedId.localId,
		]);
		assert(nodeChangeset !== undefined, 0xd99  );
		const newId: NodeId = { localId: brand(idAllocator.allocate()) };
		setInNestedMap(idRemappings, normalizedId.revision, normalizedId.localId, newId);
		const normalizedNodeChangeset: NodeChangeset = { ...nodeChangeset };
		if (normalizedNodeChangeset.fieldChanges !== undefined) {
			normalizedNodeChangeset.fieldChanges = normalizeFieldChanges(
				normalizedNodeChangeset.fieldChanges,
			);
		}
		if (dropRevertConstraint) {
			delete normalizedNodeChangeset.nodeExistsConstraintOnRevert;
		}
		nodeChanges.set([newId.revision, newId.localId], normalizedNodeChangeset);
		const parent = change.nodeToParent.get([normalizedId.revision, normalizedId.localId]);
		assert(parent !== undefined, 0xd9a  );
		const normalizedParent = normalizeFieldId(parent, change.nodeAliases);
		const newParent = remapFieldId(normalizedParent);
		nodeToParent.set([newId.revision, newId.localId], newParent);
		return newId;
	};
	function normalizeFieldChanges(fields: FieldChangeMap): FieldChangeMap {
		const normalizedFieldChanges: FieldChangeMap = new Map();
		for (const [field, fieldChange] of fields) {
			const changeHandler = getChangeHandler(fieldKinds, fieldChange.fieldKind);
			normalizedFieldChanges.set(field, {
				...fieldChange,
				change: brand(changeHandler.rebaser.prune(fieldChange.change, normalizeNodeChanges)),
			});
			const crossFieldKeys = changeHandler.getCrossFieldKeys(fieldChange.change);
			for (const { key, count } of crossFieldKeys) {
				const prevId = change.crossFieldKeys.getFirst(key, count)?.value;
				assert(prevId !== undefined, 0xd9b  );
				crossFieldKeyTable.set(key, count, remapFieldId(prevId));
			}
		}
		return normalizedFieldChanges;
	}
	const fieldChanges = normalizeFieldChanges(change.fieldChanges);
	const normal: Mutable<ModularChangeset> = {
		...change,
		nodeChanges,
		fieldChanges,
		nodeToParent,
		crossFieldKeys: crossFieldKeyTable,
		nodeAliases: newChangeAtomIdBTree(),
	};
	if (change.builds !== undefined) {
		normal.builds = brand(change.builds.mapValues(chunkNormalizer));
	}
	if (change.refreshers !== undefined) {
		normal.refreshers = brand(change.refreshers.mapValues(chunkNormalizer));
	}
	if (dropRevertConstraint) {
		delete normal.noChangeConstraintOnRevert;
	}
	if (dropRevisionInfo) {
		delete normal.revisions;
	}
	return makeModularChangeset(normal);
}
export function areEquivalent(
	change1: ModularChangeset,
	change2: ModularChangeset,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
	ignoreRevertConstraint: boolean = true,
	ignoreRevisionInfo: boolean = true,
	chunkNormalizer: (chunk: TreeChunk) => TreeChunk = makeDummyChunk,
): boolean {
	const normalized1 = normalizeChangeset(
		change1,
		fieldKinds,
		ignoreRevertConstraint,
		ignoreRevisionInfo,
		chunkNormalizer,
	);
	const normalized2 = normalizeChangeset(
		change2,
		fieldKinds,
		ignoreRevertConstraint,
		ignoreRevisionInfo,
		chunkNormalizer,
	);
	const diff = merge(normalized1, normalized2, (item: object) =>
		item instanceof BTree ? item.toArray() : item,
	);
	if (hasConflict(diff)) {
		return false;
	}
	return true;
}
```

### Decision procedure: `feature-libraries/modular-schema/prune.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/prune.ts:1-128`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function pruneChangeset(
	changeset: ModularChangeset,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): ModularChangeset {
	strictRebaseValidation("Malformed prune input", () =>
		isChangesetValid(changeset, fieldKinds),
	);
	const prunedChangeset: Mutable<ModularChangeset> = {
		...changeset,
		nodeChanges: changeset.nodeChanges.clone(),
		nodeToParent: changeset.nodeToParent.clone(),
		nodeAliases: changeset.nodeAliases.clone(),
	};
	prunedChangeset.fieldChanges =
		pruneFieldMap(
			prunedChangeset.fieldChanges,
			prunedChangeset.nodeChanges,
			prunedChangeset.nodeToParent,
			prunedChangeset.nodeAliases,
			fieldKinds,
		) ?? new Map();
	strictRebaseValidation("Malformed prune output", () =>
		isChangesetValid(prunedChangeset, fieldKinds),
	);
	return prunedChangeset;
}
function pruneFieldMap(
	changeset: FieldChangeMap | undefined,
	nodes: ChangeAtomIdBTree<NodeChangeset>,
	nodeToParent: ChangeAtomIdBTree<FieldId>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): FieldChangeMap | undefined {
	if (changeset === undefined) {
		return undefined;
	}
	const prunedChangeset: FieldChangeMap = new Map();
	for (const [field, fieldChange] of changeset) {
		const handler = getChangeHandler(fieldKinds, fieldChange.fieldKind);
		const prunedFieldChangeset = handler.rebaser.prune(fieldChange.change, (nodeId) =>
			pruneNodeChange(nodeId, nodes, nodeToParent, nodeAliases, fieldKinds),
		);
		if (!handler.isEmpty(prunedFieldChangeset)) {
			prunedChangeset.set(field, { ...fieldChange, change: brand(prunedFieldChangeset) });
		}
	}
	return prunedChangeset.size > 0 ? prunedChangeset : undefined;
}
function pruneNodeChange(
	nodeId: NodeId,
	nodeMap: ChangeAtomIdBTree<NodeChangeset>,
	nodeToParent: ChangeAtomIdBTree<FieldId>,
	nodeAliases: ChangeAtomIdBTree<NodeId>,
	fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind>,
): NodeId | undefined {
	const changeset = nodeChangeFromId(nodeMap, nodeId, nodeAliases);
	const prunedFields =
		changeset.fieldChanges === undefined
			? undefined
			: pruneFieldMap(changeset.fieldChanges, nodeMap, nodeToParent, nodeAliases, fieldKinds);
	const prunedChange = { ...changeset, fieldChanges: prunedFields };
	if (prunedChange.fieldChanges === undefined) {
		delete prunedChange.fieldChanges;
	}
	const normalizedNodeId = normalizeNodeId(nodeId, nodeAliases);
	if (isEmptyNodeChangeset(prunedChange)) {
		const nodeIdKey: [RevisionTag | undefined, ChangesetLocalId] = [
			normalizedNodeId.revision,
			normalizedNodeId.localId,
		];
		nodeMap.delete(nodeIdKey);
		nodeToParent.delete(nodeIdKey);
		return undefined;
	} else {
		setInChangeAtomIdMap(nodeMap, normalizedNodeId, prunedChange);
		return nodeId;
	}
}
function isEmptyNodeChangeset(change: NodeChangeset): boolean {
	return (
		change.fieldChanges === undefined &&
		change.nodeExistsConstraint === undefined &&
		change.nodeExistsConstraintOnRevert === undefined
	);
}
```

### Decision procedure: `feature-libraries/changeAtomIdBTree.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/changeAtomIdBTree.ts:1-47`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type ChangeAtomIdBTree<V> = TupleBTree<
	readonly [RevisionTag | undefined, ChangesetLocalId],
	V
>;
export function newChangeAtomIdBTree<V>(
	entries?: [readonly [RevisionTag | undefined, ChangesetLocalId], V][],
): ChangeAtomIdBTree<V> {
	return newTupleBTree(compareKeys, entries);
}
const compareKeys = createTupleComparator([comparePartialRevisions, compareChangesetLocalIds]);
export function getFromChangeAtomIdMap<T>(
	map: ChangeAtomIdBTree<T>,
	id: ChangeAtomId,
): T | undefined {
	return map.get([id.revision, id.localId]);
}
export function setInChangeAtomIdMap<T>(
	map: ChangeAtomIdBTree<T>,
	id: ChangeAtomId,
	value: T,
): void {
	map.set([id.revision, id.localId], value);
}
```

## 5. Invariants and asserts

0x899 destroys cannot cross wire; 0x89a cannot invert destroys; 0x8cc every invalidated compose field must have original context; 0x851 same for invert. Debug isChangesetValid checks node/parent/alias and cross-field-key coherence; do not bypass these when testing Swift algebra. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeCodecV1.ts:490` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/invert.ts:67` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:366` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeUtils.ts:6`

## 6. JS-semantics hazards

B-trees use compound identity with optional revisions; manager dependency sets key FieldChange object identity, not structural equality. Do not flatten them into dictionaries keyed by textual field name: equal field keys under different nodes are different owners. Node IDs are internal references reconstructed by decoder, not persisted indexes. Omitted revision list is inferred from context; empty list is different. Balanced reduction and allocator order affect serialized IDs. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeFamily.ts:232` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/modularChangeCodecV1.ts:442` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/modular-schema/crossFieldQueries.ts:6`

## 7. Test assets to reuse

Reuse modular-schema change-family/rebase tests, cross-field move integration and generic-field snapshots; run same cases through every default-schema field codec mapping. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/feature-libraries/modular-schema/modularChangeFamily.spec.ts:1`

## 8. Open questions

None about the format split. Source-extract procedures below intentionally retain original collection operations; their implementation semantics are specified in core/util and must not become unordered Swift Dictionary traversal.

