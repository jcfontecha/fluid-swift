# Sequence Field — Fluid Framework 3.11.0

## 1. Role

Sequence-field is the ordered-field change algebra, including insert/revive, removal, movement across fields, persistent empty cells, cell renaming and nested node edits. It is invoked through modular-schema, not directly by the runtime. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldChangeHandler.ts:6`

## 2. Surface used by other packages

`sequence` FlexFieldKind; handler editor, rebaser, delta conversion, pruning, removed-root collection, nested-change and cross-field-key extraction. Changeset is an ordered Mark array. Mark has count, optional cellId and node-change ID, plus one effect: noop (type undefined), Insert, Remove, MoveIn, MoveOut, AttachAndDetach, Rename. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/types.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldChangeHandler.ts:6`

## 3. Wire and persisted formats

Reader/writer codecs registered: 2 and 3 ONLY. formatV1 remains source but is not registered. Default modular format 3 uses sequence 2; modular 4/5 use sequence 3. No per-field version property exists on the wire. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldCodecs.ts:24` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/defaultFieldKinds.ts:107`

Both formats encode an array of objects, property emission order `count`, `effect?`, `cellId?`, `changes?`. Effect is a singleton-key union `{insert:...}`, `{remove:...}`, `{moveIn:...}`, `{moveOut:...}`, `{attachAndDetach:{attach,detach}}`; v3 additionally `{rename:{idOverride}}`. Noop omits effect. Insert payload `{id,revision?}`; Remove adds `idOverride?`; move payload adds `finalEndpoint?` and MoveOut additionally `idOverride?`. All atoms use context-sensitive compact encoding; changes contains INLINE node change, not NodeId. count positive integer. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/formatV2.ts:15` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/formatV3.ts:21` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldCodecV3.ts:99`

V2 encoding converts Rename to AttachAndDetach with MoveIn id -1 and MoveOut id -1 plus idOverride; v2 decode normalizes this representation back into modern marks. Preserve those normalization paths rather than just serializing the in-memory union. Exact codec branches are included below. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldCodecV2.ts:40`


### Decision procedure: `feature-libraries/sequence-field/formatV1.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/formatV1.ts:1-190`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export enum DetachIdOverrideType {
	Unattach = 0,
	Redetach = 1,
}
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
const CellCount = Type.Integer({ minimum: 1 });
const MoveId = ChangesetLocalIdSchema;
const HasMoveId = Type.Object({ id: MoveId });
const LineageEvent = Type.Tuple([
	RevisionTagSchema,
	ChangesetLocalIdSchema,
	CellCount,
	Type.Integer({ minimum: 0 }),
]);
const HasLineage = Type.Object({ lineage: Type.Optional(Type.Array(LineageEvent)) });
const IdRange = Type.Tuple([ChangesetLocalIdSchema, CellCount]);
const CellId = Type.Composite(
	[
		HasLineage,
		Type.Object({
			atom: EncodedChangeAtomId,
			adjacentCells: Type.Optional(Type.Array(IdRange)),
		}),
	],
	noAdditionalProps,
);
const HasRevisionTag = Type.Object({ revision: Type.Optional(RevisionTagSchema) });
const Insert = Type.Composite([HasMoveId, HasRevisionTag], noAdditionalProps);
const HasMoveFields = Type.Composite([
	HasMoveId,
	HasRevisionTag,
	Type.Object({ finalEndpoint: Type.Optional(EncodedChangeAtomId) }),
]);
const MoveIn = Type.Composite([HasMoveFields], noAdditionalProps);
const DetachIdOverride = Type.Object(
	{
		type: Type.Enum(DetachIdOverrideType),
		id: CellId,
	},
	noAdditionalProps,
);
const DetachFields = Type.Object({
	idOverride: Type.Optional(DetachIdOverride),
});
const Remove = Type.Composite(
	[
		Type.Object({
			id: ChangesetLocalIdSchema,
		}),
		HasRevisionTag,
		DetachFields,
	],
	noAdditionalProps,
);
const MoveOut = Type.Composite([HasMoveFields, DetachFields], noAdditionalProps);
const Attach = Type.Object(
	{
		insert: Type.Optional(Insert),
		moveIn: Type.Optional(MoveIn),
	},
	unionOptions,
);
const Detach = Type.Object(
	{
		delete: Type.Optional(Remove),
		moveOut: Type.Optional(MoveOut),
	},
	unionOptions,
);
const AttachAndDetach = Type.Object({
	attach: Attach,
	detach: Detach,
});
const MarkEffect = Type.Object(
	{
		insert: Type.Optional(Insert),
		moveIn: Type.Optional(MoveIn),
		delete: Type.Optional(Remove),
		moveOut: Type.Optional(MoveOut),
		attachAndDetach: Type.Optional(AttachAndDetach),
	},
	unionOptions,
);
const CellMark = <TMark extends TSchema, TNodeChange extends TSchema>(
	tMark: TMark,
	tNodeChange: TNodeChange,
) =>
	Type.Object(
		{
			effect: Type.Optional(tMark),
			cellId: Type.Optional(CellId),
			changes: Type.Optional(tNodeChange),
			count: CellCount,
		},
		noAdditionalProps,
	);
const Mark = <Schema extends TSchema>(tNodeChange: Schema) =>
	CellMark(MarkEffect, tNodeChange);
export const Changeset = <Schema extends TSchema>(tNodeChange: Schema) =>
	Type.Array(Mark(tNodeChange));
export namespace Encoded {
	export type CellCount = Static<typeof CellCount>;
	export type MoveId = Static<typeof MoveId>;
	export type LineageEvent = Static<typeof LineageEvent>;
	export type IdRange = Static<typeof IdRange>;
	export type CellId = Static<typeof CellId>;
	export type Insert = Static<typeof Insert>;
	export type MoveIn = Static<typeof MoveIn>;
	export type Remove = Static<typeof Remove>;
	export type MoveOut = Static<typeof MoveOut>;
	export type Attach = Static<typeof Attach>;
	export type Detach = Static<typeof Detach>;
	export type AttachAndDetach = Static<typeof AttachAndDetach>;
	export type MarkEffect = Static<typeof MarkEffect>;
	export type CellMark<Schema extends TSchema, TNodeChange extends TSchema> = Static<
		ReturnType<typeof CellMark<Schema, TNodeChange>>
	>;
	export type Mark<Schema extends TSchema> = Static<ReturnType<typeof Mark<Schema>>>;
	export type Changeset<Schema extends TSchema> = Static<ReturnType<typeof Changeset<Schema>>>;
}
```

### Decision procedure: `feature-libraries/sequence-field/formatV2.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/formatV2.ts:1-139`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
const CellCount = Type.Integer({ minimum: 1 });
const MoveId = ChangesetLocalIdSchema;
const HasMoveId = Type.Object({ id: MoveId });
const IdRange = Type.Tuple([ChangesetLocalIdSchema, CellCount]);
export const CellId = EncodedChangeAtomId;
const HasRevisionTag = Type.Object({ revision: Type.Optional(RevisionTagSchema) });
const Insert = Type.Composite([HasMoveId, HasRevisionTag], noAdditionalProps);
const HasMoveFields = Type.Composite([
	HasMoveId,
	HasRevisionTag,
	Type.Object({ finalEndpoint: Type.Optional(EncodedChangeAtomId) }),
]);
const MoveIn = Type.Composite([HasMoveFields], noAdditionalProps);
const DetachFields = Type.Object({
	idOverride: Type.Optional(CellId),
});
const Remove = Type.Composite(
	[
		Type.Object({
			id: ChangesetLocalIdSchema,
		}),
		HasRevisionTag,
		DetachFields,
	],
	noAdditionalProps,
);
const MoveOut = Type.Composite([HasMoveFields, DetachFields], noAdditionalProps);
const Attach = Type.Object(
	{
		insert: Type.Optional(Insert),
		moveIn: Type.Optional(MoveIn),
	},
	unionOptions,
);
const Detach = Type.Object(
	{
		remove: Type.Optional(Remove),
		moveOut: Type.Optional(MoveOut),
	},
	unionOptions,
);
const AttachAndDetach = Type.Object({
	attach: Attach,
	detach: Detach,
});
export const MarkEffect = Type.Object(
	{
		insert: Type.Optional(Insert),
		moveIn: Type.Optional(MoveIn),
		remove: Type.Optional(Remove),
		moveOut: Type.Optional(MoveOut),
		attachAndDetach: Type.Optional(AttachAndDetach),
	},
	unionOptions,
);
export const CellMark = <TMark extends TSchema, TNodeChange extends TSchema>(
	tMark: TMark,
	tNodeChange: TNodeChange,
) =>
	Type.Object(
		{
			effect: Type.Optional(tMark),
			cellId: Type.Optional(CellId),
			changes: Type.Optional(tNodeChange),
			count: CellCount,
		},
		noAdditionalProps,
	);
const Mark = <Schema extends TSchema>(tNodeChange: Schema) =>
	CellMark(MarkEffect, tNodeChange);
export const Changeset = <Schema extends TSchema>(tNodeChange: Schema) =>
	Type.Array(Mark(tNodeChange));
export namespace Encoded {
	export type CellCount = Static<typeof CellCount>;
	export type MoveId = Static<typeof MoveId>;
	export type IdRange = Static<typeof IdRange>;
	export type CellId = Static<typeof CellId>;
	export type Insert = Static<typeof Insert>;
	export type MoveIn = Static<typeof MoveIn>;
	export type Remove = Static<typeof Remove>;
	export type MoveOut = Static<typeof MoveOut>;
	export type Attach = Static<typeof Attach>;
	export type Detach = Static<typeof Detach>;
	export type AttachAndDetach = Static<typeof AttachAndDetach>;
	export type MarkEffect = Static<typeof MarkEffect>;
	export type CellMark<Schema extends TSchema, TNodeChange extends TSchema> = Static<
		ReturnType<typeof CellMark<Schema, TNodeChange>>
	>;
	export type Mark<Schema extends TSchema> = Static<ReturnType<typeof Mark<Schema>>>;
	export type Changeset<Schema extends TSchema> = Static<ReturnType<typeof Changeset<Schema>>>;
}
```

### Decision procedure: `feature-libraries/sequence-field/formatV3.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/formatV3.ts:1-67`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
const Rename = Type.Object(
	{
		idOverride: CellId,
	},
	noAdditionalProps,
);
const MarkEffect = Type.Composite(
	[MarkEffectV2, Type.Object({ rename: Type.Optional(Rename) })],
	unionOptions,
);
const Mark = <Schema extends TSchema>(tNodeChange: Schema) =>
	CellMark(MarkEffect, tNodeChange);
export const Changeset = <Schema extends TSchema>(tNodeChange: Schema) =>
	Type.Array(Mark(tNodeChange));
export namespace Encoded {
	export type CellCount = EncodedV2.CellCount;
	export type MoveId = EncodedV2.MoveId;
	export type IdRange = EncodedV2.IdRange;
	export type CellId = EncodedV2.CellId;
	export type Insert = EncodedV2.Insert;
	export type MoveIn = EncodedV2.MoveIn;
	export type Remove = EncodedV2.Remove;
	export type MoveOut = EncodedV2.MoveOut;
	export type Attach = EncodedV2.Attach;
	export type Detach = EncodedV2.Detach;
	export type AttachAndDetach = EncodedV2.AttachAndDetach;
	export type CellMark<
		Schema extends TSchema,
		TNodeChange extends TSchema,
	> = EncodedV2.CellMark<Schema, TNodeChange>;
	export type Rename = Static<typeof Rename>;
	export type MarkEffect = Static<typeof MarkEffect>;
	export type Mark<Schema extends TSchema> = Static<ReturnType<typeof Mark<Schema>>>;
	export type Changeset<Schema extends TSchema> = Static<ReturnType<typeof Changeset<Schema>>>;
}
```

### Decision procedure: `feature-libraries/sequence-field/sequenceFieldCodecV2.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldCodecV2.ts:1-352`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function makeV2CodecHelpers(
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
): SequenceCodecHelpers<MarkEffect, Encoded.MarkEffect> {
	const changeAtomIdCodec = makeChangeAtomIdCodec(revisionTagCodec);
	const markEffectCodec: IJsonCodec<
		MarkEffect,
		Encoded.MarkEffect,
		Encoded.MarkEffect,
		ChangeEncodingContext
	> = {
		encode(effect: MarkEffect, context: ChangeEncodingContext): Encoded.MarkEffect {
			function encodeRevision(
				revision: RevisionTag | undefined,
			): EncodedRevisionTag | undefined {
				if (revision === undefined || revision === context.revision) {
					return undefined;
				}
				return revisionTagCodec.encode(revision, context);
			}
			const type = effect.type;
			switch (type) {
				case "MoveIn": {
					return {
						moveIn: {
							revision: encodeRevision(effect.revision),
							finalEndpoint:
								effect.finalEndpoint === undefined
									? undefined
									: changeAtomIdCodec.encode(effect.finalEndpoint, context),
							id: effect.id,
						},
					};
				}
				case "Insert": {
					return {
						insert: {
							revision: encodeRevision(effect.revision),
							id: effect.id,
						},
					};
				}
				case "Remove": {
					return {
						remove: {
							revision: encodeRevision(effect.revision),
							idOverride:
								effect.idOverride === undefined
									? undefined
									: changeAtomIdCodec.encode(effect.idOverride, context),
							id: effect.id,
						},
					};
				}
				case "MoveOut": {
					return {
						moveOut: {
							revision: encodeRevision(effect.revision),
							finalEndpoint:
								effect.finalEndpoint === undefined
									? undefined
									: changeAtomIdCodec.encode(effect.finalEndpoint, context),
							idOverride:
								effect.idOverride === undefined
									? undefined
									: changeAtomIdCodec.encode(effect.idOverride, context),
							id: effect.id,
						},
					};
				}
				case "AttachAndDetach": {
					return {
						attachAndDetach: {
							attach: markEffectCodec.encode(effect.attach, context) as Encoded.Attach,
							detach: markEffectCodec.encode(effect.detach, context) as Encoded.Detach,
						},
					};
				}
				case "Rename": {
					return markEffectCodec.encode(
						{
							type: "AttachAndDetach",
							attach: { type: "MoveIn", id: renameLocalId },
							detach: { type: "MoveOut", id: renameLocalId, idOverride: effect.idOverride },
						},
						context,
					);
				}
				case NoopMarkType: {
					fail(0xb2c  );
				}
				default: {
					unreachableCase(type);
				}
			}
		},
		decode(encoded: Encoded.MarkEffect, context: ChangeEncodingContext): MarkEffect {
			return decoderDispatcher.dispatch(encoded, context);
		},
	};
	function decodeRevision(
		encodedRevision: EncodedRevisionTag | undefined,
		context: ChangeEncodingContext,
	): RevisionTag {
		if (encodedRevision === undefined) {
			assert(context.revision !== undefined, 0x996  );
			return context.revision;
		}
		return revisionTagCodec.decode(encodedRevision, context);
	}
	const decoderLibrary: DiscriminatedUnionLibrary<
		Encoded.MarkEffect,
		  [context: ChangeEncodingContext],
		MarkEffect
	> = {
		moveIn(encoded: Encoded.MoveIn, context: ChangeEncodingContext): MoveIn {
			const { id, finalEndpoint, revision } = encoded;
			const mark: MoveIn = {
				type: "MoveIn",
				id,
			};
			mark.revision = decodeRevision(revision, context);
			if (finalEndpoint !== undefined) {
				mark.finalEndpoint = changeAtomIdCodec.decode(finalEndpoint, context);
			}
			return mark;
		},
		insert(encoded: Encoded.Insert, context: ChangeEncodingContext): Insert {
			const { id, revision } = encoded;
			const mark: Insert = {
				type: "Insert",
				id,
			};
			mark.revision = decodeRevision(revision, context);
			return mark;
		},
		remove(encoded: Encoded.Remove, context: ChangeEncodingContext): Remove {
			const { id, revision, idOverride } = encoded;
			const mark: Mutable<Remove> = {
				type: "Remove",
				id,
			};
			mark.revision = decodeRevision(revision, context);
			if (idOverride !== undefined) {
				mark.idOverride = changeAtomIdCodec.decode(idOverride, context);
			}
			return mark;
		},
		moveOut(encoded: Encoded.MoveOut, context: ChangeEncodingContext): MoveOut {
			const { id, finalEndpoint, idOverride, revision } = encoded;
			const mark: Mutable<MoveOut> = {
				type: "MoveOut",
				id,
			};
			mark.revision = decodeRevision(revision, context);
			if (finalEndpoint !== undefined) {
				mark.finalEndpoint = changeAtomIdCodec.decode(finalEndpoint, context);
			}
			if (idOverride !== undefined) {
				mark.idOverride = changeAtomIdCodec.decode(idOverride, context);
			}
			return mark;
		},
		attachAndDetach(
			encoded: Encoded.AttachAndDetach,
			context: ChangeEncodingContext,
		): AttachAndDetach | Rename {
			const attach = decoderDispatcher.dispatch(encoded.attach, context) as Attach;
			const detach = decoderDispatcher.dispatch(encoded.detach, context) as Detach;
			if (attach.id === renameLocalId) {
				assert(detach.idOverride !== undefined, 0x9f8  );
				return {
					type: "Rename",
					idOverride: detach.idOverride,
				};
			}
			return {
				type: "AttachAndDetach",
				attach,
				detach,
			};
		},
	};
	const decoderDispatcher = new DiscriminatedUnionDispatcher<
		Encoded.MarkEffect,
		  [context: ChangeEncodingContext],
		MarkEffect
	>(decoderLibrary);
	return {
		changeAtomIdCodec,
		markEffectCodec,
		decoderLibrary,
		decodeRevision,
	};
}
export function makeV2Codec(
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
): IJsonCodec<
	Changeset,
	JsonCompatibleReadOnly,
	JsonCompatibleReadOnly,
	FieldChangeEncodingContext,
	FieldChangeDecodingContext
> {
	const { markEffectCodec, changeAtomIdCodec } = makeV2CodecHelpers(revisionTagCodec);
	type NodeChangeSchema = TAnySchema;
	return {
		encode: (
			changeset: Changeset,
			context: FieldChangeEncodingContext,
		): JsonCompatibleReadOnly & Encoded.Changeset<NodeChangeSchema> => {
			const jsonMarks: Encoded.Changeset<NodeChangeSchema> = [];
			for (const mark of changeset) {
				const encodedMark: Encoded.Mark<NodeChangeSchema> = {
					count: mark.count,
				};
				if (!isNoopMark(mark)) {
					encodedMark.effect = markEffectCodec.encode(mark, context.baseContext);
				}
				if (mark.cellId !== undefined) {
					encodedMark.cellId = changeAtomIdCodec.encode(mark.cellId, context.baseContext);
				}
				if (mark.changes !== undefined) {
					encodedMark.changes = context.encodeNode(mark.changes);
				}
				jsonMarks.push(encodedMark);
			}
			return jsonMarks;
		},
		decode: (
			changeset: Encoded.Changeset<NodeChangeSchema>,
			context: FieldChangeDecodingContext,
		): Changeset => {
			const marks: Changeset = [];
			for (const mark of changeset) {
				const decodedMark: Mark = {
					count: mark.count,
				};
				if (mark.effect !== undefined) {
					Object.assign(decodedMark, markEffectCodec.decode(mark.effect, context.baseContext));
				}
				if (mark.cellId !== undefined) {
					decodedMark.cellId = changeAtomIdCodec.decode(mark.cellId, context.baseContext);
				}
				let decodedMark2 = decodedMark as Mark;
				if (decodedMark2.cellId !== undefined && decodedMark2.type === "AttachAndDetach") {
					decodedMark2 = normalizeCellRename(
						decodedMark2.cellId,
						decodedMark2.count,
						decodedMark2.attach,
						decodedMark2.detach,
					);
				}
				if (mark.changes !== undefined) {
					decodedMark2.changes = context.decodeNode(mark.changes);
				}
				marks.push(decodedMark2);
			}
			return marks;
		},
		encodedSchema: ChangesetSchema(EncodedNodeChangeset),
	};
}
const renameLocalId: ChangesetLocalId = brand(-1);
```

### Decision procedure: `feature-libraries/sequence-field/sequenceFieldCodecV3.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldCodecV3.ts:1-143`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function makeV3Codec(
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
): IJsonCodec<
	Changeset,
	JsonCompatibleReadOnly,
	JsonCompatibleReadOnly,
	FieldChangeEncodingContext,
	FieldChangeDecodingContext
> {
	const {
		changeAtomIdCodec: atomIdCodec,
		markEffectCodec: markEffectV2Codec,
		decoderLibrary: decoderLibraryV2,
	} = makeV2CodecHelpers(revisionTagCodec);
	const markEffectCodec: IJsonCodec<
		MarkEffect,
		Encoded.MarkEffect,
		Encoded.MarkEffect,
		ChangeEncodingContext
	> = {
		encode(effect: MarkEffect, context: ChangeEncodingContext): Encoded.MarkEffect {
			const type = effect.type;
			switch (type) {
				case "Rename": {
					return {
						rename: {
							idOverride: atomIdCodec.encode(effect.idOverride, context),
						},
					};
				}
				default: {
					return markEffectV2Codec.encode(effect, context);
				}
			}
		},
		decode(encoded: Encoded.MarkEffect, context: ChangeEncodingContext): MarkEffect {
			return decoderLibrary.dispatch(encoded, context);
		},
	};
	const decoderLibrary = new DiscriminatedUnionDispatcher<
		Encoded.MarkEffect,
		  [context: ChangeEncodingContext],
		MarkEffect
	>({
		...decoderLibraryV2,
		rename(encoded: Encoded.Rename, context: ChangeEncodingContext): Rename {
			return {
				type: "Rename",
				idOverride: atomIdCodec.decode(encoded.idOverride, context),
			};
		},
	});
	type NodeChangeSchema = TAnySchema;
	return {
		encode: (
			changeset: Changeset,
			context: FieldChangeEncodingContext,
		): JsonCompatibleReadOnly & Encoded.Changeset<NodeChangeSchema> => {
			const jsonMarks: Encoded.Changeset<NodeChangeSchema> = [];
			for (const mark of changeset) {
				const encodedMark: Encoded.Mark<NodeChangeSchema> = {
					count: mark.count,
				};
				if (!isNoopMark(mark)) {
					encodedMark.effect = markEffectCodec.encode(mark, context.baseContext);
				}
				if (mark.cellId !== undefined) {
					encodedMark.cellId = atomIdCodec.encode(mark.cellId, context.baseContext);
				}
				if (mark.changes !== undefined) {
					encodedMark.changes = context.encodeNode(mark.changes);
				}
				jsonMarks.push(encodedMark);
			}
			return jsonMarks;
		},
		decode: (
			changeset: Encoded.Changeset<NodeChangeSchema>,
			context: FieldChangeDecodingContext,
		): Changeset => {
			const marks: Changeset = [];
			for (const mark of changeset) {
				const decodedMark: Mark = {
					count: mark.count,
				};
				if (mark.effect !== undefined) {
					Object.assign(decodedMark, markEffectCodec.decode(mark.effect, context.baseContext));
				}
				if (mark.cellId !== undefined) {
					decodedMark.cellId = atomIdCodec.decode(mark.cellId, context.baseContext);
				}
				if (mark.changes !== undefined) {
					decodedMark.changes = context.decodeNode(mark.changes);
				}
				marks.push(decodedMark);
			}
			return marks;
		},
		encodedSchema: ChangesetSchema(EncodedNodeChangeset),
	};
}
```

### Decision procedure: `feature-libraries/sequence-field/sequenceFieldCodecs.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldCodecs.ts:1-31`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const sequenceFieldChangeCodecFactory = (
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
): ICodecFamily<MarkList, FieldChangeEncodingContext, FieldChangeDecodingContext> =>
	makeCodecFamily<Changeset, FieldChangeEncodingContext, FieldChangeDecodingContext>([
		[2, makeV2Codec(revisionTagCodec)],
		[3, makeV3Codec(revisionTagCodec)],
	]);
```

### Literal emission examples

These payloads have no own version property; the modular field-kind configuration selects the reader. An empty change is `[]` in both v2 and v3; retained occupied cells are `[{"count":2}]`; nested-only edit is `[{"count":1,"changes":{}}]` (the child encoder emits an empty NodeChangeset). A newly built insertion with context-local atom 0 is `[{"count":1,"effect":{"insert":{"id":0}},"cellId":0}]`. An occupied removal is `[{"count":1,"effect":{"remove":{"id":1}}}]`. The mark encoder writes `count`, then `effect` if non-noop, then `cellId` if present, then inline `changes` if present. Effect payload members and optional revision/endpoint order are fixed by the included v2 helper, which v3 reuses. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldCodecV3.ts:99-130` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldCodecV2.ts:40-179`

For input empty cell 0 renamed to atom 2: v3 is `[{"count":1,"effect":{"rename":{"idOverride":2}},"cellId":0}]`; v2 lowers the same intention to `[{"count":1,"effect":{"attachAndDetach":{"attach":{"moveIn":{"id":-1}},"detach":{"moveOut":{"idOverride":2,"id":-1}}}},"cellId":0}]`. V2 decode uses normalization, not a literal modern Rename discriminator. No sequence-v1 reader is registered, even though formatV1 declarations remain in the source. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldCodecV2.ts:40-105` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldCodecs.ts:23-31`

## 4. Behavior

### Coordinates and ordering

A missing cellId means occupied INPUT cells; a present cellId means empty INPUT cells. The same effect can therefore be active, muted, a revive, or a rename. Skip marks on empty cells are tombstones and consume no visible nodes. Count is the number of cells; each range increments ID offsets on splits. A nested change must have count=1. MarkQueue splits at range boundaries and cross-field effect boundaries; MarkListFactory merges compatible adjacent marks and delays trailing skips. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/utils.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/markQueue.ts:20` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/markListFactory.ts:12`

Tie order compares cell IDs, NOT visible indexes and NOT UUID order: equal atom→same cell. If both changes know the other's cell-creation revision, assert same revision (transaction case), choose new before old. If only new knows old, new before old; only old knows new, old before new. Otherwise merge-left: anonymous new before old; require defined old revision; if both metadata indexes exist, higher index first; if neither exists fail 0x8a2; if one exists, indexed/newer one first. Knowledge sets come from tombstone/mark cell sources. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/utils.ts:183`

### Compose (aligned A output / B input)

Queue orders empty cells using the above comparator, synthesizes noops for unmatched ranges, and splits to equal counts. Settle marks before pair composition: composed results are not intended for further rebase. Compose nested node changes; if A MoveIn provides B's node, send B child edit to the original move source via cross-field modifyAfter rather than leaving it at destination. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/compose.ts:105` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/compose.ts:469`

| A then B effect | Result at aligned cell |
| --- | --- |
| noop / anything | B (but composed child) |
| anything / noop | A |
| Rename / Rename | original input cell, B override |
| Rename / attach or attach-detach | B with original input cell |
| detach or attach-detach / Rename | A with B override on final detach |
| detach / impactful attach-detach | B detach (middle attach cancels) |
| impactful attach-detach / impactful attach-detach | A attach + B detach; normalize to noop if final output identity equals original input |
| impactful attach-detach / fill | A attach |
| neither changes cell occupancy | noop retaining original input identity |
| only one changes occupancy | that effect |
| attach / detach | normalized cell rename, or noop if original empty ID restored |
| detach / attach | occupied noop; child effects still compose |

Move pivot A→B→C updates BOTH source/destination endpoint ranges, propagates truncated inner endpoints, removes unused finalEndpoint on the pivot. Treating the table as independent per-cell edits loses cross-field moves. Full decision procedure and endpoint helpers follow. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/compose.ts:179` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/compose.ts:396`

### Invert

Non-impactful mark becomes child-only noop at input identity. Rename rollback swaps input/override; ordinary inverse is noop at renamed identity. Remove occupied→Insert at detach output ID with alias ID; Remove empty→Remove at output ID, restoring old input ID only on rollback. Insert→Remove, rollback sets idOverride=input cell. MoveOut→MoveIn at detach output identity; if original input empty wrap inverse in AttachAndDetach with Remove; send child edit to inverse source via destination effect table. MoveIn→MoveOut; rollback restores input cell via idOverride; fetch transported node changes and split at cross-field boundaries. AttachAndDetach inverts the halves and recombines inverse(detach) attach then inverse(attach) detach, normalizing identities; preserve alias allocation shared by both endpoints. Nested payload inversion occurs in modular-schema, not by simply negating NodeId. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/invert.ts:96`

### Rebase A over B (aligned INPUT cells)

Rebase child first with B's output attached/detached state; consume moved child changes before rewriting cell effects. B detach converts A target to B output empty ID. B MoveOut separates effects: Remove/MoveOut follow node; their idOverride remains as Rename at source; AttachAndDetach keeps attach at source and sends detach; MoveIn/Rename stay; noop does neither; Insert becomes MoveIn at source + MoveOut following node. Send children to destination. B fill clears A.cellId, or removes attach half of A AttachAndDetach. B AttachAndDetach recursively rebases over attach then detach; B Rename updates A.cellId. Other B leaves cell effect. Destination-side moved effect collisions have explicit branches (MoveIn+MoveOut→Insert, Rename+MoveOut→MoveOut with override, matching attach-detach→detach, tombstone→effect), else fail 0x818. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/rebase.ts:245` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/rebase.ts:287`

Delta conversion drops tombstones from visible marks, carries renames to detached-root renames and detached child edits to globals. Move IDs couple attach/detach; structural changes and node changes are separate channels. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldToDelta.ts:22`

### Exact decision procedures

The source extracts below are executable TypeScript notation for the rules above (comments/imports removed only). Names retain their source meaning; `undefined` denotes missing, object spread is right-biased, `delete` removes property, manager operations are the modular-schema range effect protocol. They include queue splitting, endpoint routing, normalization and delta lowering so the porter need not infer omitted cases.

### Algorithm notation and completeness

The following decision procedures are part of this specification, not external reading assignments. They preserve exact predicates, allocation order, collection traversal, return shapes and synchronous event calls. `undefined` means absent; `null` is a value; object spread is right-biased; `delete` removes a property; `Map`/`Set` iterate in insertion order. TypeBox `Optional(T)` permits absence, not null; tuples are fixed-order JSON arrays; singleton discriminated unions have exactly one case property. Assertions stop execution at the displayed short code. Helpers in another area use that area's same-named procedure; generic collection utilities retain JavaScript order. These are reference algorithms to translate into Swift, not a proposal to embed TypeScript in the client.

### Decision procedure: `feature-libraries/sequence-field/compose.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/compose.ts:1-828`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function compose(
	change1: Changeset,
	change2: Changeset,
	composeChild: NodeChangeComposer,
	_genId: IdAllocator,
	manager: CrossFieldManager,
	revisionMetadata: RevisionMetadataSource,
): Changeset {
	return composeMarkLists(
		change1,
		change2,
		composeChild,
		manager as MoveEffectTable,
		revisionMetadata,
	);
}
function composeMarkLists(
	baseMarkList: MarkList,
	newMarkList: MarkList,
	composeChild: NodeChangeComposer,
	moveEffects: MoveEffectTable,
	revisionMetadata: RevisionMetadataSource,
): MarkList {
	const factory = new MarkListFactory();
	const queue = new ComposeQueue(baseMarkList, newMarkList, moveEffects, revisionMetadata);
	while (!queue.isEmpty()) {
		const { baseMark, newMark } = queue.pop();
		if (newMark === undefined) {
			assert(
				baseMark !== undefined,
				0x4db  ,
			);
			factory.push(
				composeMark(baseMark, moveEffects, (node: NodeId) =>
					composeChildChanges(node, undefined, composeChild),
				),
			);
		} else {
			const settledNewMark = settleMark(newMark);
			if (baseMark === undefined) {
				factory.push(
					composeMark(settledNewMark, moveEffects, (node: NodeId) =>
						composeChildChanges(undefined, node, composeChild),
					),
				);
			} else {
				const settledBaseMark = settleMark(baseMark);
				const composedMark = composeMarks(
					settledBaseMark,
					settledNewMark,
					composeChild,
					moveEffects,
				);
				factory.push(composedMark);
			}
		}
	}
	return factory.list;
}
function composeMarks(
	baseMark: Mark,
	newMark: Mark,
	composeChild: NodeChangeComposer,
	moveEffects: MoveEffectTable,
): Mark {
	const nodeChange = handleNodeChanges(baseMark, newMark, composeChild, moveEffects);
	return withUpdatedEndpoint(
		withNodeChange(composeMarksIgnoreChild(baseMark, newMark, moveEffects), nodeChange),
		baseMark.count,
		moveEffects,
	);
}
function composeMarksIgnoreChild(
	baseMark: Mark,
	newMark: Mark,
	moveEffects: MoveEffectTable,
): Mark {
	if (isNoopMark(baseMark)) {
		return newMark;
	} else if (isNoopMark(newMark)) {
		return baseMark;
	}
	if (isRename(baseMark) && isRename(newMark)) {
		return { ...baseMark, idOverride: newMark.idOverride };
	} else if (isRename(baseMark)) {
		assert(
			isAttach(newMark) || isAttachAndDetachEffect(newMark),
			0x9f1  ,
		);
		return { ...newMark, cellId: baseMark.cellId };
	} else if (isRename(newMark)) {
		assert(
			isDetach(baseMark) || isAttachAndDetachEffect(baseMark),
			0x9f2  ,
		);
		return isDetach(baseMark)
			? { ...baseMark, idOverride: newMark.idOverride }
			: { ...baseMark, detach: { ...baseMark.detach, idOverride: newMark.idOverride } };
	}
	if (isImpactfulCellRename(newMark)) {
		const newAttachAndDetach = asAttachAndDetach(newMark);
		assert(
			newAttachAndDetach.cellId !== undefined,
			0x9f3  ,
		);
		const newDetachRevision = newAttachAndDetach.detach.revision;
		if (markEmptiesCells(baseMark)) {
			const newDetach: CellMark<Detach> = {
				...newAttachAndDetach.detach,
				count: baseMark.count,
			};
			if (isMoveIn(newAttachAndDetach.attach) && isMoveOut(newAttachAndDetach.detach)) {
				assert(isMoveOut(baseMark), 0x808  );
				const newDetachId = {
					revision: newDetachRevision,
					localId: newAttachAndDetach.detach.id,
				};
				setTruncatedEndpointForInner(
					moveEffects,
					CrossFieldTarget.Destination,
					getEndpoint(baseMark),
					baseMark.count,
					newDetachId,
				);
				const newEndpoint = getComposedEndpoint(
					moveEffects,
					CrossFieldTarget.Source,
					baseMark.revision,
					baseMark.id,
					baseMark.count,
				);
				if (newEndpoint !== undefined) {
					changeFinalEndpoint(newDetach as MoveMarkEffect, newEndpoint);
					setTruncatedEndpoint(
						moveEffects,
						CrossFieldTarget.Destination,
						newEndpoint,
						baseMark.count,
						newDetachId,
					);
				}
			}
			return newDetach;
		}
		if (isImpactfulCellRename(baseMark)) {
			assert(
				baseMark.cellId !== undefined,
				0x9f4  ,
			);
			const baseAttachAndDetach = asAttachAndDetach(baseMark);
			const newOutputId = getOutputCellId(newAttachAndDetach);
			const originalAttach = { ...baseAttachAndDetach.attach };
			const finalDetach = { ...newAttachAndDetach.detach };
			handleMovePivot(baseMark.count, originalAttach, finalDetach, moveEffects);
			if (areEqualCellIds(newOutputId, baseAttachAndDetach.cellId)) {
				return { count: baseAttachAndDetach.count, cellId: baseAttachAndDetach.cellId };
			}
			const detachRevision = finalDetach.revision;
			if (detachRevision !== undefined) {
				finalDetach.revision = detachRevision;
			}
			return normalizeCellRename(baseMark.cellId, baseMark.count, originalAttach, finalDetach);
		}
		return normalizeCellRename(
			newAttachAndDetach.cellId,
			newAttachAndDetach.count,
			newAttachAndDetach.attach,
			newAttachAndDetach.detach,
		);
	}
	if (isImpactfulCellRename(baseMark)) {
		const baseAttachAndDetach = asAttachAndDetach(baseMark);
		if (markFillsCells(newMark)) {
			const originalAttach = withRevision(
				{
					...baseAttachAndDetach.attach,
					cellId: baseAttachAndDetach.cellId,
					count: baseAttachAndDetach.count,
				},
				baseAttachAndDetach.attach.revision,
			);
			if (isMoveIn(baseAttachAndDetach.attach) && isMoveOut(baseAttachAndDetach.detach)) {
				assert(isMoveIn(newMark), 0x809  );
				const originalAttachId = {
					revision: baseAttachAndDetach.attach.revision,
					localId: baseAttachAndDetach.attach.id,
				};
				setTruncatedEndpointForInner(
					moveEffects,
					CrossFieldTarget.Source,
					getEndpoint(newMark),
					baseAttachAndDetach.count,
					originalAttachId,
				);
				const newEndpoint = getComposedEndpoint(
					moveEffects,
					CrossFieldTarget.Destination,
					newMark.revision,
					newMark.id,
					newMark.count,
				);
				if (newEndpoint !== undefined) {
					changeFinalEndpoint(originalAttach as MoveMarkEffect, newEndpoint);
					setTruncatedEndpoint(
						moveEffects,
						CrossFieldTarget.Source,
						newEndpoint,
						baseMark.count,
						originalAttachId,
					);
				}
			}
			return originalAttach;
		} else {
			assert(newMark.type === NoopMarkType, 0x80a  );
			return baseMark;
		}
	}
	if (!markHasCellEffect(baseMark) && !markHasCellEffect(newMark)) {
		return createNoopMark(newMark.count, undefined, getInputCellId(baseMark));
	} else if (!markHasCellEffect(baseMark)) {
		return newMark;
	} else if (!markHasCellEffect(newMark)) {
		return baseMark;
	} else if (areInputCellsEmpty(baseMark)) {
		assert(isDetach(newMark), 0x71c  );
		assert(isAttach(baseMark), 0x71d  );
		const attach = extractMarkEffect(baseMark);
		const detach = extractMarkEffect(newMark);
		handleMovePivot(baseMark.count, attach, detach, moveEffects);
		if (areEqualCellIds(getOutputCellId(newMark), baseMark.cellId)) {
			return { count: baseMark.count, cellId: baseMark.cellId };
		}
		return normalizeCellRename(baseMark.cellId, baseMark.count, attach, detach);
	} else {
		const length = baseMark.count;
		return createNoopMark(length, undefined);
	}
}
function handleMovePivot(
	count: number,
	baseAttach: Attach,
	newDetach: Detach,
	moveEffects: MoveEffectTable,
): void {
	if (isMoveIn(baseAttach) && isMoveOut(newDetach)) {
		const finalSource = getEndpoint(baseAttach);
		const finalDest = getEndpoint(newDetach);
		setEndpoint(moveEffects, CrossFieldTarget.Source, finalSource, count, finalDest);
		const truncatedEndpoint1 = getTruncatedEndpointForInner(
			moveEffects,
			CrossFieldTarget.Destination,
			baseAttach.revision,
			baseAttach.id,
			count,
		);
		if (truncatedEndpoint1 !== undefined) {
			setTruncatedEndpoint(
				moveEffects,
				CrossFieldTarget.Destination,
				finalDest,
				count,
				truncatedEndpoint1,
			);
		}
		setEndpoint(moveEffects, CrossFieldTarget.Destination, finalDest, count, finalSource);
		const truncatedEndpoint2 = getTruncatedEndpointForInner(
			moveEffects,
			CrossFieldTarget.Source,
			newDetach.revision,
			newDetach.id,
			count,
		);
		if (truncatedEndpoint2 !== undefined) {
			setTruncatedEndpoint(
				moveEffects,
				CrossFieldTarget.Source,
				finalSource,
				count,
				truncatedEndpoint2,
			);
		}
		delete baseAttach.finalEndpoint;
		delete newDetach.finalEndpoint;
	}
}
function createNoopMark(
	length: number,
	nodeChange: NodeId | undefined,
	cellId?: ChangeAtomId,
): Mark {
	const mark: CellMark<NoopMark> = { count: length };
	if (nodeChange !== undefined) {
		assert(length === 1, 0x692  );
		mark.changes = nodeChange;
	}
	if (cellId !== undefined) {
		mark.cellId = cellId;
	}
	return mark;
}
function handleNodeChanges(
	baseMark: Mark,
	newMark: Mark,
	composeChild: NodeChangeComposer,
	moveEffects: MoveEffectTable,
): NodeId | undefined {
	if (newMark.changes !== undefined) {
		moveEffects.onMoveIn(newMark.changes);
		const baseSource = getMoveIn(baseMark);
		if (baseSource !== undefined) {
			setModifyAfter(moveEffects, getEndpoint(baseSource), newMark.changes);
			return undefined;
		}
	}
	return composeChildChanges(baseMark.changes, newMark.changes, composeChild);
}
function composeChildChanges(
	baseChange: NodeId | undefined,
	newChange: NodeId | undefined,
	composeChild: NodeChangeComposer,
): NodeId | undefined {
	if (baseChange === undefined && newChange === undefined) {
		return undefined;
	}
	return composeChild(baseChange, newChange);
}
function composeMark<TMark extends Mark>(
	mark: TMark,
	moveEffects: MoveEffectTable,
	composeChild: (node: NodeId) => NodeId | undefined,
): TMark {
	const nodeChanges = mark.changes === undefined ? undefined : composeChild(mark.changes);
	const updatedMark = withUpdatedEndpoint(mark, mark.count, moveEffects);
	return withNodeChange(updatedMark, nodeChanges);
}
export class ComposeQueue {
	private readonly baseMarks: MarkQueue;
	private readonly newMarks: MarkQueue;
	private readonly baseMarksCellSources: ReadonlySet<RevisionTag | undefined>;
	private readonly newMarksCellSources: ReadonlySet<RevisionTag | undefined>;
	public constructor(
		baseMarks: Changeset,
		newMarks: Changeset,
		private readonly moveEffects: MoveEffectTable,
		private readonly revisionMetadata: RevisionMetadataSource,
	) {
		this.baseMarks = new MarkQueue(baseMarks, moveEffects);
		this.newMarks = new MarkQueue(newMarks, moveEffects);
		this.baseMarksCellSources = cellSourcesFromMarks(baseMarks, getOutputCellId);
		this.newMarksCellSources = cellSourcesFromMarks(newMarks, getInputCellId);
	}
	public isEmpty(): boolean {
		return this.baseMarks.isEmpty() && this.newMarks.isEmpty();
	}
	public pop(): ComposeMarks {
		const baseMark = this.baseMarks.peek();
		const newMark = this.newMarks.peek();
		if (baseMark === undefined && newMark === undefined) {
			return {};
		} else if (baseMark === undefined) {
			return this.dequeueNew();
		} else if (newMark === undefined) {
			return this.dequeueBase();
		} else if (areOutputCellsEmpty(baseMark) && areInputCellsEmpty(newMark)) {
			const baseCellId: ChangeAtomId =
				getOutputCellId(baseMark) ?? fail(0xb29  );
			if (markEmptiesCells(baseMark) && baseCellId.revision === undefined) {
				assert(
					isNewAttach(newMark),
					0x695  ,
				);
				return this.dequeueNew();
			}
			const newCellId = getInputCellId(newMark);
			assert(newCellId !== undefined, 0x89d  );
			const comparison = compareCellPositionsUsingTombstones(
				baseCellId,
				newCellId,
				this.baseMarksCellSources,
				this.newMarksCellSources,
				this.revisionMetadata,
			);
			switch (comparison) {
				case CellOrder.SameCell: {
					return this.dequeueBoth();
				}
				case CellOrder.OldThenNew: {
					return this.dequeueBase();
				}
				case CellOrder.NewThenOld: {
					return this.dequeueNew();
				}
				default: {
					unreachableCase(comparison);
				}
			}
		} else if (areOutputCellsEmpty(baseMark)) {
			return this.dequeueBase();
		} else if (areInputCellsEmpty(newMark)) {
			return this.dequeueNew();
		} else {
			return this.dequeueBoth();
		}
	}
	private dequeueBase(length: number = Number.POSITIVE_INFINITY): ComposeMarks {
		const baseMark = this.baseMarks.dequeueUpTo(length);
		const movedChanges = getMovedChangesFromMark(this.moveEffects, baseMark);
		const newMark = createNoopMark(baseMark.count, movedChanges, getOutputCellId(baseMark));
		return { baseMark, newMark };
	}
	private dequeueNew(length: number = Number.POSITIVE_INFINITY): ComposeMarks {
		const newMark = this.newMarks.dequeueUpTo(length);
		const baseMark = createNoopMark(newMark.count, undefined, getInputCellId(newMark));
		return {
			baseMark,
			newMark,
		};
	}
	private dequeueBoth(): ComposeMarks {
		const length = this.peekMinLength();
		const baseMark = this.baseMarks.dequeueUpTo(length);
		let newMark = this.newMarks.dequeueUpTo(length);
		const movedChanges = getMovedChangesFromMark(this.moveEffects, baseMark);
		if (movedChanges !== undefined) {
			assert(newMark.changes === undefined, 0x8da  );
			newMark = withNodeChange(newMark, movedChanges);
		}
		return {
			baseMark,
			newMark,
		};
	}
	private peekMinLength(): number {
		const baseMark = this.baseMarks.peek();
		const newMark = this.newMarks.peek();
		assert(
			baseMark !== undefined && newMark !== undefined,
			0x8db  ,
		);
		return Math.min(newMark.count, baseMark.count);
	}
}
interface ComposeMarks {
	baseMark?: Mark;
	newMark?: Mark;
}
function getMovedChangesFromMark(
	moveEffects: MoveEffectTable,
	markEffect: MarkEffect,
): NodeId | undefined {
	if (isAttachAndDetachEffect(markEffect)) {
		return getMovedChangesFromMark(moveEffects, markEffect.detach);
	}
	if (!isMoveOut(markEffect)) {
		return undefined;
	}
	return getModifyAfter(moveEffects, markEffect.revision, markEffect.id);
}
function getModifyAfter(
	moveEffects: MoveEffectTable,
	revision: RevisionTag | undefined,
	id: MoveId,
): NodeId | undefined {
	const target = CrossFieldTarget.Source;
	const effect = getMoveEffect(moveEffects, target, revision, id, 1);
	if (effect.value?.modifyAfter !== undefined) {
		return effect.value.modifyAfter;
	}
	return undefined;
}
function setModifyAfter(
	moveEffects: MoveEffectTable,
	{ revision, localId: id }: ChangeAtomId,
	modifyAfter: NodeId,
): void {
	const target = CrossFieldTarget.Source;
	const count = 1;
	const effect = getMoveEffect(moveEffects, target, revision, id, count, false);
	const newEffect: MoveEffect =
		effect.value === undefined ? { modifyAfter } : { ...effect.value, modifyAfter };
	setMoveEffect(moveEffects, target, revision, id, count, newEffect);
}
function setEndpoint(
	moveEffects: MoveEffectTable,
	target: CrossFieldTarget,
	id: ChangeAtomId,
	count: number,
	endpoint: ChangeAtomId,
): void {
	const effect = getMoveEffect(moveEffects, target, id.revision, id.localId, count, false);
	const newEffect = effect.value === undefined ? { endpoint } : { ...effect.value, endpoint };
	setMoveEffect(moveEffects, target, id.revision, id.localId, effect.length, newEffect);
	const remainingCount = count - effect.length;
	if (remainingCount > 0) {
		setEndpoint(
			moveEffects,
			target,
			offsetChangeAtomId(id, effect.length),
			remainingCount,
			offsetChangeAtomId(endpoint, effect.length),
		);
	}
}
function setTruncatedEndpoint(
	moveEffects: MoveEffectTable,
	target: CrossFieldTarget,
	id: ChangeAtomId,
	count: number,
	truncatedEndpoint: ChangeAtomId,
): void {
	const effect = getMoveEffect(moveEffects, target, id.revision, id.localId, count);
	const newEffect =
		effect.value === undefined
			? { truncatedEndpoint }
			: { ...effect.value, truncatedEndpoint };
	setMoveEffect(moveEffects, target, id.revision, id.localId, effect.length, newEffect);
	const remainingCount = count - effect.length;
	if (remainingCount > 0) {
		setTruncatedEndpoint(
			moveEffects,
			target,
			offsetChangeAtomId(id, effect.length),
			remainingCount,
			offsetChangeAtomId(truncatedEndpoint, effect.length),
		);
	}
}
function setTruncatedEndpointForInner(
	moveEffects: MoveEffectTable,
	target: CrossFieldTarget,
	id: ChangeAtomId,
	count: number,
	truncatedEndpointForInner: ChangeAtomId,
): void {
	const effect = getMoveEffect(moveEffects, target, id.revision, id.localId, count);
	const newEffect =
		effect.value === undefined
			? { truncatedEndpointForInner }
			: { ...effect.value, truncatedEndpointForInner };
	setMoveEffect(moveEffects, target, id.revision, id.localId, effect.length, newEffect);
	const remainingCount = count - effect.length;
	if (remainingCount > 0) {
		setTruncatedEndpointForInner(
			moveEffects,
			target,
			offsetChangeAtomId(id, effect.length),
			remainingCount,
			offsetChangeAtomId(truncatedEndpointForInner, effect.length),
		);
	}
}
function withUpdatedEndpoint<TMark extends MarkEffect>(
	mark: TMark,
	count: number,
	effects: MoveEffectTable,
): TMark {
	if (isAttachAndDetachEffect(mark)) {
		return {
			...mark,
			attach: withUpdatedEndpoint(mark.attach, count, effects),
			detach: withUpdatedEndpoint(mark.detach, count, effects),
		};
	}
	if (!isMoveMark(mark)) {
		return mark;
	}
	const finalDest = getComposedEndpoint(
		effects,
		getCrossFieldTargetFromMove(mark),
		mark.revision,
		mark.id,
		count,
	);
	if (finalDest === undefined) {
		return mark;
	}
	const output = { ...mark };
	changeFinalEndpoint(output, finalDest);
	return output;
}
function changeFinalEndpoint(mark: MoveMarkEffect, endpoint: ChangeAtomId): void {
	if (areEqualCellIds(endpoint, { revision: mark.revision, localId: mark.id })) {
		delete mark.finalEndpoint;
	} else {
		mark.finalEndpoint = endpoint;
	}
}
function getComposedEndpoint(
	moveEffects: MoveEffectTable,
	target: CrossFieldTarget,
	revision: RevisionTag | undefined,
	id: MoveId,
	count: number,
): ChangeAtomId | undefined {
	const effect = getMoveEffect(moveEffects, target, revision, id, count);
	assert(effect.length === count, 0x815  );
	return effect.value?.truncatedEndpoint ?? effect.value?.endpoint;
}
function getTruncatedEndpointForInner(
	moveEffects: MoveEffectTable,
	target: CrossFieldTarget,
	revision: RevisionTag | undefined,
	id: MoveId,
	count: number,
): ChangeAtomId | undefined {
	const effect = getMoveEffect(moveEffects, target, revision, id, count);
	assert(effect.length === count, 0x934  );
	return effect.value?.truncatedEndpointForInner;
}
```

### Decision procedure: `feature-libraries/sequence-field/filterEdits.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/filterEdits.ts:1-179`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function filterEdits(
	change: Changeset,
	options: {
		filterDetach: FilterDetachFunc;
		filterAttach: FilterAttachFunc;
		preserveOtherEdits: boolean;
	},
): Changeset {
	const factory = new MarkListFactory();
	const queue = new MarkQueueBase(change);
	for (let mark = queue.peek(); mark !== undefined; mark = queue.peek()) {
		const filtered = filterMark(
			mark,
			options.filterDetach,
			options.filterAttach,
			options.preserveOtherEdits,
		);
		factory.push(filtered);
		queue.dequeueUpTo(filtered.count);
	}
	return factory.list;
}
function filterMark(
	mark: Mark,
	filterDetach: FilterDetachFunc,
	filterAttach: FilterAttachFunc,
	preserveOtherEdits: boolean,
): Mark {
	const type = mark.type;
	switch (type) {
		case "Insert":
		case "MoveIn": {
			if (mark.cellId === undefined) {
				return preserveOtherEdits ? mark : omitMarkEffect(mark);
			}
			const attachId =
				mark.type === "MoveIn" ? { revision: mark.revision, localId: mark.id } : mark.cellId;
			const endpoint = mark.type === "MoveIn" ? mark.finalEndpoint : undefined;
			const result = filterAttach(attachId, mark.count, undefined, endpoint);
			let filtered: Mark;
			switch (result.value.action) {
				case EditFilterStatus.Preserve: {
					filtered = mark;
					break;
				}
				case EditFilterStatus.PreserveWithoutMove: {
					const newCellId = result.value.newAttachId ??
						endpoint ?? {
							revision: mark.revision,
							localId: mark.id,
						};
					filtered = {
						type: "Insert",
						count: result.length,
						cellId: newCellId,
						revision: mark.revision,
						id: mark.id,
					};
					if (result.value.nodeId !== undefined) {
						filtered.changes = result.value.nodeId;
					}
					break;
				}
				case EditFilterStatus.Remove: {
					filtered = omitMarkEffect(mark);
					break;
				}
				default: {
					unreachableCase(result.value.action);
				}
			}
			return { ...filtered, count: result.length };
		}
		case "Remove":
		case "MoveOut": {
			const detachId = getDetachedNodeId(mark);
			const endpoint = mark.type === "MoveOut" ? mark.finalEndpoint : undefined;
			const result = filterDetach(detachId, mark.count, mark.cellId, endpoint);
			let filtered: Mark;
			switch (result.value.action) {
				case EditFilterStatus.Preserve: {
					filtered = mark;
					break;
				}
				case EditFilterStatus.PreserveWithoutMove: {
					const outputCellId = getDetachOutputCellId(mark);
					filtered = {
						type: "Remove",
						count: mark.count,
						revision: outputCellId.revision,
						id: outputCellId.localId,
					};
					if (mark.changes !== undefined) {
						filtered.changes = mark.changes;
					}
					break;
				}
				case EditFilterStatus.Remove: {
					filtered = omitMarkEffect(mark);
					if (result.value.shouldRemoveChild === true) {
						delete filtered.changes;
					}
					break;
				}
				default: {
					unreachableCase(result.value.action);
				}
			}
			return { ...filtered, count: result.length };
		}
		case "AttachAndDetach": {
			assert(
				mark.attach.type === "MoveIn",
				0xd3c  ,
			);
			if (mark.cellId === undefined) {
				return preserveOtherEdits ? mark : omitMarkEffect(mark);
			}
			const result = filterAttach(
				{ revision: mark.attach.revision, localId: mark.attach.id },
				mark.count,
				getOutputCellId(mark),
				mark.attach.finalEndpoint,
			);
			const filtered =
				result.value.action === EditFilterStatus.Preserve ? mark : omitMarkEffect(mark);
			return { ...filtered, count: result.length };
		}
		case NoopMarkType:
		case "Rename": {
			return preserveOtherEdits ? mark : omitMarkEffect(mark);
		}
		default: {
			unreachableCase(type);
		}
	}
}
```

### Decision procedure: `feature-libraries/sequence-field/helperTypes.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/helperTypes.ts:1-60`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type EmptyInputCellMark = Mark & DetachedCellMark;
export interface DetachedCellMark extends HasMarkFields {
	cellId: CellId;
}
export type EmptyOutputCellMark = CellMark<Detach | AttachAndDetach>;
export type MoveMarkEffect = MoveOut | MoveIn;
export type DetachOfRemovedNodes = Detach & { cellId: CellId };
export type CellRename = AttachAndDetach | DetachOfRemovedNodes;
export interface SequenceCodecHelpers<TDecodedMarkEffect, TEncodedMarkEffect extends object> {
	readonly changeAtomIdCodec: IJsonCodec<
		ChangeAtomId,
		EncodedChangeAtomId,
		EncodedChangeAtomId,
		ChangeEncodingContext
	>;
	readonly markEffectCodec: IJsonCodec<
		TDecodedMarkEffect,
		TEncodedMarkEffect,
		TEncodedMarkEffect,
		ChangeEncodingContext
	>;
	readonly decoderLibrary: DiscriminatedUnionLibrary<
		TEncodedMarkEffect,
		  [context: ChangeEncodingContext],
		TDecodedMarkEffect
	>;
	readonly decodeRevision: (
		encodedRevision: EncodedRevisionTag | undefined,
		context: ChangeEncodingContext,
	) => RevisionTag;
}
```

### Decision procedure: `feature-libraries/sequence-field/invert.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/invert.ts:1-398`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function invert(
	change: Changeset,
	isRollback: boolean,
	genId: AtomIdAliasAllocator,
	revision: RevisionTag | undefined,
	crossFieldManager: CrossFieldManager,
): Changeset {
	return invertMarkList(
		change,
		isRollback,
		crossFieldManager as CrossFieldManager<NodeId>,
		genId,
		revision,
	);
}
function invertMarkList(
	markList: MarkList,
	isRollback: boolean,
	crossFieldManager: CrossFieldManager<NodeId>,
	genId: AtomIdAliasAllocator,
	revision: RevisionTag | undefined,
): MarkList {
	const inverseMarkList = new MarkListFactory();
	for (const mark of markList) {
		const inverseMarks = invertMark(mark, isRollback, crossFieldManager, genId, revision);
		inverseMarkList.push(...inverseMarks);
	}
	return inverseMarkList.list;
}
function invertMark(
	mark: Mark,
	isRollback: boolean,
	crossFieldManager: CrossFieldManager<NodeId>,
	genId: AtomIdAliasAllocator,
	revision: RevisionTag | undefined,
): Mark[] {
	if (!isImpactful(mark)) {
		const inputId = getInputCellId(mark);
		return [invertNodeChangeOrSkip(mark.count, mark.changes, inputId)];
	}
	const type = mark.type;
	switch (type) {
		case NoopMarkType: {
			return [mark];
		}
		case "Rename": {
			if (isRollback) {
				const inputId = getInputCellId(mark);
				assert(inputId !== undefined, 0x9f5  );
				const inverse: Mutable<CellMark<Rename>> = {
					type: "Rename",
					count: mark.count,
					cellId: mark.idOverride,
					idOverride: inputId,
				};
				return [withNodeChange(inverse, mark.changes)];
			} else {
				return [withNodeChange({ count: mark.count, cellId: mark.idOverride }, mark.changes)];
			}
		}
		case "Remove": {
			assert(mark.revision !== undefined, 0x5a1  );
			const outputId = getOutputCellId(mark);
			const inputId = getInputCellId(mark);
			let inverse: Mutable<Mark>;
			if (inputId === undefined) {
				inverse = {
					type: "Insert",
					id: genId.getAlias(mark.revision, mark.id),
					cellId: outputId,
					count: mark.count,
					revision,
				};
			} else {
				inverse = {
					type: "Remove",
					id: genId.getAlias(mark.revision, mark.id),
					cellId: outputId,
					count: mark.count,
					revision,
				};
				if (isRollback) {
					inverse.idOverride = inputId;
				}
			}
			return [withNodeChange(inverse, mark.changes)];
		}
		case "Insert": {
			const inputId = getInputCellId(mark);
			assert(inputId !== undefined, 0x80c  );
			const removeMark: Mutable<CellMark<Remove>> = {
				type: "Remove",
				count: mark.count,
				id: genId.getAlias(mark.revision, mark.id),
				revision,
			};
			if (isRollback) {
				removeMark.idOverride = inputId;
			}
			const inverse = withNodeChange(removeMark, mark.changes);
			return [inverse];
		}
		case "MoveOut": {
			if (mark.changes !== undefined) {
				assert(mark.count === 1, 0x6ed  );
				const endpoint = getEndpoint(mark);
				crossFieldManager.set(
					CrossFieldTarget.Destination,
					endpoint.revision,
					endpoint.localId,
					mark.count,
					mark.changes,
					true,
				);
			}
			const cellId = getDetachOutputCellId(mark) ?? {
				revision: mark.revision ?? fail(0xb2a  ),
				localId: mark.id,
			};
			const moveIn: MoveIn = {
				type: "MoveIn",
				id: genId.getAlias(mark.revision, mark.id),
				revision,
			};
			if (mark.finalEndpoint !== undefined) {
				moveIn.finalEndpoint = {
					localId: genId.getAlias(mark.finalEndpoint.revision, mark.finalEndpoint.localId),
					revision,
				};
			}
			let effect: MarkEffect = moveIn;
			const inputId = getInputCellId(mark);
			if (inputId !== undefined) {
				const detach: Mutable<Detach> = {
					type: "Remove",
					id: genId.getAlias(mark.revision, mark.id),
					revision,
				};
				if (isRollback) {
					detach.idOverride = inputId;
				}
				effect = {
					type: "AttachAndDetach",
					attach: moveIn,
					detach,
				};
			}
			return [{ ...effect, count: mark.count, cellId }];
		}
		case "MoveIn": {
			const inputId = getInputCellId(mark);
			assert(inputId !== undefined, 0x89e  );
			const invertedMark: Mutable<CellMark<MoveOut>> = {
				type: "MoveOut",
				id: genId.getAlias(mark.revision, mark.id),
				count: mark.count,
				revision,
			};
			if (isRollback) {
				invertedMark.idOverride = inputId;
			}
			if (mark.finalEndpoint) {
				invertedMark.finalEndpoint = {
					localId: genId.getAlias(mark.finalEndpoint.revision, mark.finalEndpoint.localId),
					revision,
				};
			}
			return applyMovedChanges(invertedMark, mark.revision, mark.id, crossFieldManager);
		}
		case "AttachAndDetach": {
			const attach: Mark = {
				count: mark.count,
				cellId: mark.cellId,
				...mark.attach,
			};
			const idAfterAttach = getOutputCellId(attach);
			const detach: Mark = {
				count: mark.count,
				cellId: idAfterAttach,
				changes: mark.changes,
				...mark.detach,
			};
			const attachInverses = invertMark(
				attach,
				isRollback,
				crossFieldManager,
				genId,
				revision,
			);
			const detachInverses = invertMark(
				detach,
				isRollback,
				crossFieldManager,
				genId,
				revision,
			);
			if (detachInverses.length === 0) {
				return attachInverses;
			}
			assert(
				hasSingle(detachInverses),
				0x80d  ,
			);
			let detachInverse = detachInverses[0];
			assert(isAttach(detachInverse), 0x80e  );
			const inverses: Mark[] = [];
			for (const attachInverse of attachInverses) {
				let detachInverseCurr: Mark = detachInverse;
				if (attachInverse.count !== detachInverse.count) {
					[detachInverseCurr, detachInverse] = splitMark(detachInverse, attachInverse.count);
				}
				if (attachInverse.type === NoopMarkType) {
					if (attachInverse.changes !== undefined) {
						assert(
							detachInverseCurr.changes === undefined,
							0x80f  ,
						);
						detachInverseCurr.changes = attachInverse.changes;
					}
					inverses.push(detachInverseCurr);
					continue;
				}
				assert(isDetach(attachInverse), 0x810  );
				assert(detachInverseCurr.cellId !== undefined, 0x9f6  );
				const inverted = normalizeCellRename(
					detachInverseCurr.cellId,
					attachInverse.count,
					extractMarkEffect(detachInverseCurr),
					extractMarkEffect(attachInverse),
				);
				if (detachInverse.changes !== undefined) {
					inverted.changes = detachInverse.changes;
				}
				if (attachInverse.changes !== undefined) {
					assert(inverted.changes === undefined, 0x811  );
					inverted.changes = attachInverse.changes;
				}
				inverses.push(inverted);
			}
			return inverses;
		}
		default: {
			unreachableCase(type);
		}
	}
}
function applyMovedChanges(
	invertedMark: CellMark<MoveOut>,
	originalRevision: RevisionTag | undefined,
	originalId: ChangesetLocalId,
	manager: CrossFieldManager<NodeId>,
): Mark[] {
	const entry = manager.get(
		CrossFieldTarget.Destination,
		originalRevision,
		originalId,
		invertedMark.count,
		true,
	);
	if (entry.length < invertedMark.count) {
		const [mark1, mark2] = splitMark(invertedMark, entry.length);
		const mark1WithChanges =
			entry.value === undefined
				? mark1
				: withNodeChange<CellMark<MoveOut>, MoveOut>(mark1, entry.value);
		return [
			mark1WithChanges,
			...applyMovedChanges(
				mark2,
				originalRevision,
				offsetChangesetLocalId(originalId, mark1.count),
				manager,
			),
		];
	}
	if (entry.value !== undefined) {
		manager.onMoveIn(entry.value);
		return [withNodeChange<CellMark<MoveOut>, MoveOut>(invertedMark, entry.value)];
	}
	return [invertedMark];
}
function invertNodeChangeOrSkip(
	count: number,
	changes: NodeId | undefined,
	cellId?: CellId,
): Mark {
	if (changes !== undefined) {
		assert(count === 1, 0x66c  );
		const noop: CellMark<NoopMark> = {
			count,
			changes,
		};
		if (cellId !== undefined) {
			noop.cellId = cellId;
		}
		return noop;
	}
	if (cellId !== undefined) {
		return { count, cellId };
	}
	return { count };
}
```

### Decision procedure: `feature-libraries/sequence-field/markListFactory.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/markListFactory.ts:1-51`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class MarkListFactory {
	private offset = 0;
	public readonly list: MarkList = [];
	public constructor() {}
	public push(...marks: Mark[]): void {
		for (const item of marks) {
			this.pushContent(item);
		}
	}
	public pushOffset(offset: number): void {
		this.offset += offset;
	}
	public pushContent(mark: Mark): void {
		if (isNoopMark(mark) && mark.changes === undefined && !isTombstone(mark)) {
			this.pushOffset(mark.count);
			return;
		}
		if (this.offset > 0) {
			this.list.push({ count: this.offset });
			this.offset = 0;
		}
		const prev = this.list[this.list.length - 1];
		if (prev !== undefined && prev.type === mark.type) {
			const merged = tryMergeMarks(prev, mark);
			if (merged !== undefined) {
				this.list.splice(-1, 1, merged);
				return;
			}
		}
		this.list.push(mark);
	}
}
```

### Decision procedure: `feature-libraries/sequence-field/markQueue.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/markQueue.ts:1-86`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class MarkQueueBase {
	private readonly stack: Mark[] = [];
	private index = 0;
	public constructor(private readonly list: readonly Mark[]) {
		this.list = list;
	}
	public isEmpty(): boolean {
		return this.peek() === undefined;
	}
	public dequeue(): Mark {
		const output = this.tryDequeue();
		assert(output !== undefined, 0x4e2  );
		return output;
	}
	public tryDequeue(): Mark | undefined {
		const mark = this.stack.length > 0 ? this.stack.pop() : this.list[this.index++];
		if (mark === undefined) {
			return undefined;
		}
		const splitLength = this.getLengthForSplit(mark);
		if (splitLength < mark.count) {
			const [part1, part2] = splitMark(mark, splitLength);
			this.stack.push(part2);
			return part1;
		}
		return mark;
	}
	public dequeueUpTo(length: number): Mark {
		const mark = this.dequeue();
		if (mark.count <= length) {
			return mark;
		}
		const [mark1, mark2] = splitMark(mark, length);
		this.stack.push(mark2);
		return mark1;
	}
	public peek(): Mark | undefined {
		const mark = this.tryDequeue();
		if (mark !== undefined) {
			this.stack.push(mark);
		}
		return mark;
	}
	protected getLengthForSplit(mark: Mark): number {
		return mark.count;
	}
}
export class MarkQueue extends MarkQueueBase {
	public constructor(
		list: readonly Mark[],
		private readonly moveEffects: MoveEffectTable,
	) {
		super(list);
	}
	protected override getLengthForSplit(mark: Mark): number {
		return getFirstMoveEffectLength(mark, mark.count, this.moveEffects);
	}
}
```

### Decision procedure: `feature-libraries/sequence-field/moveEffectTable.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/moveEffectTable.ts:1-214`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type MoveEffectTable = CrossFieldManager<MoveEffect>;
export interface MoveEffect {
	modifyAfter?: NodeId;
	movedEffect?: Detach;
	rebasedChanges?: NodeId;
	endpoint?: ChangeAtomId;
	truncatedEndpoint?: ChangeAtomId;
	truncatedEndpointForInner?: ChangeAtomId;
}
interface MoveEffectWithBasis extends MoveEffect {
	basis: MoveId;
}
export enum MoveEnd {
	Source,
	Dest,
}
export interface MovePartition {
	id: MoveId;
	count?: number;
	replaceWith?: Mark[];
	modifyAfter?: TaggedChange<NodeId>;
}
export function setMoveEffect(
	moveEffects: MoveEffectTable,
	target: CrossFieldTarget,
	revision: RevisionTag | undefined,
	id: MoveId,
	count: number,
	effect: MoveEffect,
	invalidate: boolean = true,
): void {
	(effect as MoveEffectWithBasis).basis = id;
	moveEffects.set(target, revision, id, count, effect, invalidate);
}
export function getMoveEffect(
	moveEffects: MoveEffectTable,
	target: CrossFieldTarget,
	revision: RevisionTag | undefined,
	id: MoveId,
	count: number,
	addDependency: boolean = true,
): RangeQueryResult<MoveEffect | undefined> {
	const result = moveEffects.get(target, revision, id, count, addDependency);
	return result.value === undefined
		? result
		: { ...result, value: adjustMoveEffectBasis(result.value as MoveEffectWithBasis, id) };
}
export type MoveMark = CellMark<MoveMarkEffect>;
export function isMoveMark(effect: MarkEffect): effect is MoveMarkEffect {
	return isMoveOut(effect) || isMoveIn(effect);
}
export function isMoveOut(effect: MarkEffect): effect is MoveOut {
	return effect.type === "MoveOut";
}
export function isMoveIn(effect: MarkEffect): effect is MoveIn {
	return effect.type === "MoveIn";
}
export function getMoveIn(effect: MarkEffect): MoveIn | undefined {
	switch (effect.type) {
		case "MoveIn": {
			return effect;
		}
		case "AttachAndDetach": {
			return getMoveIn(effect.attach);
		}
		default: {
			return undefined;
		}
	}
}
function adjustMoveEffectBasis(effect: MoveEffectWithBasis, newBasis: MoveId): MoveEffect {
	if (effect.basis === newBasis) {
		return effect;
	}
	const adjusted = { ...effect, basis: newBasis };
	const basisShift = newBasis - effect.basis;
	assert(basisShift > 0, 0x812  );
	if (effect.endpoint !== undefined) {
		adjusted.endpoint = adjustChangeAtomId(effect.endpoint, basisShift);
	}
	if (effect.truncatedEndpoint !== undefined) {
		adjusted.truncatedEndpoint = adjustChangeAtomId(effect.truncatedEndpoint, basisShift);
	}
	if (effect.truncatedEndpointForInner !== undefined) {
		adjusted.truncatedEndpointForInner = adjustChangeAtomId(
			effect.truncatedEndpointForInner,
			basisShift,
		);
	}
	if (effect.movedEffect !== undefined) {
		const [_mark1, mark2] = splitMarkEffect(effect.movedEffect, basisShift);
		adjusted.movedEffect = mark2;
	}
	return adjusted;
}
export function getFirstMoveEffectLength(
	markEffect: MarkEffect,
	count: number,
	effects: MoveEffectTable,
): number {
	if (isMoveMark(markEffect)) {
		return getMoveEffect(
			effects,
			getCrossFieldTargetFromMove(markEffect),
			markEffect.revision,
			markEffect.id,
			count,
		).length;
	} else if (isAttachAndDetachEffect(markEffect)) {
		return Math.min(
			getFirstMoveEffectLength(markEffect.attach, count, effects),
			getFirstMoveEffectLength(markEffect.detach, count, effects),
		);
	}
	return count;
}
export function getCrossFieldTargetFromMove(mark: MoveMarkEffect): CrossFieldTarget {
	const type = mark.type;
	switch (type) {
		case "MoveIn": {
			return CrossFieldTarget.Destination;
		}
		case "MoveOut": {
			return CrossFieldTarget.Source;
		}
		default: {
			unreachableCase(type);
		}
	}
}
function adjustChangeAtomId(id: ChangeAtomId, shift: number): ChangeAtomId {
	return {
		...id,
		localId: brand(id.localId + shift),
	};
}
```

### Decision procedure: `feature-libraries/sequence-field/prune.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/prune.ts:1-21`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function prune(changeset: Changeset, pruneNode: NodeChangePruner): Changeset {
	const pruned = new MarkListFactory();
	for (let mark of changeset) {
		if (mark.changes !== undefined) {
			mark = withNodeChange(mark, pruneNode(mark.changes));
		}
		pruned.push(mark);
	}
	return pruned.list;
}
```

### Decision procedure: `feature-libraries/sequence-field/rebase.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/rebase.ts:1-577`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function rebase(
	change: Changeset,
	base: Changeset,
	rebaseChild: NodeChangeRebaser,
	genId: IdAllocator,
	manager: CrossFieldManager,
	revisionMetadata: RebaseRevisionMetadata,
): Changeset {
	return rebaseMarkList(
		change,
		base,
		revisionMetadata,
		rebaseChild,
		genId,
		manager as MoveEffectTable,
	);
}
function rebaseMarkList(
	currMarkList: MarkList,
	baseMarkList: MarkList,
	metadata: RebaseRevisionMetadata,
	rebaseChild: NodeChangeRebaser,
	genId: IdAllocator,
	moveEffects: CrossFieldManager<MoveEffect>,
): MarkList {
	const factory = new MarkListFactory();
	const queue = new RebaseQueue(baseMarkList, currMarkList, metadata, moveEffects);
	while (!queue.isEmpty()) {
		const { baseMark, newMark: currMark } = queue.pop();
		const rebasedMark = rebaseMark(currMark, baseMark, rebaseChild, moveEffects);
		factory.push(rebasedMark);
	}
	return factory.list;
}
function generateNoOpWithCellId(mark: Mark): CellMark<NoopMark> {
	const length = mark.count;
	const cellId = getInputCellId(mark);
	return cellId === undefined ? { count: length } : { count: length, cellId };
}
class RebaseQueue {
	private readonly baseMarks: MarkQueue;
	private readonly newMarks: MarkQueue;
	private readonly baseMarksCellSources: ReadonlySet<RevisionTag | undefined>;
	private readonly newMarksCellSources: ReadonlySet<RevisionTag | undefined>;
	public constructor(
		baseMarks: Changeset,
		newMarks: Changeset,
		private readonly metadata: RevisionMetadataSource,
		private readonly moveEffects: MoveEffectTable,
	) {
		this.baseMarks = new MarkQueue(baseMarks, moveEffects);
		this.newMarks = new MarkQueue(newMarks, moveEffects);
		this.baseMarksCellSources = cellSourcesFromMarks(baseMarks, getInputCellId);
		this.newMarksCellSources = cellSourcesFromMarks(newMarks, getInputCellId);
	}
	public isEmpty(): boolean {
		return this.baseMarks.isEmpty() && this.newMarks.isEmpty();
	}
	public pop(): RebaseMarks {
		const baseMark = this.baseMarks.peek();
		const newMark = this.newMarks.peek();
		assert(
			!(baseMark === undefined && newMark === undefined),
			0x722  ,
		);
		if (baseMark === undefined) {
			const dequeuedNewMark = this.newMarks.dequeue();
			return {
				baseMark: generateNoOpWithCellId(dequeuedNewMark),
				newMark: dequeuedNewMark,
			};
		} else if (newMark === undefined) {
			return this.dequeueBase();
		} else if (areInputCellsEmpty(baseMark) && areInputCellsEmpty(newMark)) {
			const baseId = getInputCellId(baseMark);
			const newId = getInputCellId(newMark);
			assert(
				baseId !== undefined && newId !== undefined,
				0x89f  ,
			);
			const comparison = compareCellPositionsUsingTombstones(
				baseId,
				newId,
				this.baseMarksCellSources,
				this.newMarksCellSources,
				this.metadata,
			);
			switch (comparison) {
				case CellOrder.SameCell: {
					return this.dequeueBoth();
				}
				case CellOrder.OldThenNew: {
					return this.dequeueBase();
				}
				case CellOrder.NewThenOld: {
					return this.dequeueNew();
				}
				default: {
					unreachableCase(comparison);
				}
			}
		} else if (areInputCellsEmpty(newMark)) {
			return this.dequeueNew();
		} else if (areInputCellsEmpty(baseMark)) {
			return this.dequeueBase();
		} else {
			return this.dequeueBoth();
		}
	}
	private dequeueBase(length?: number): RebaseMarks {
		const baseMark =
			length === undefined ? this.baseMarks.dequeue() : this.baseMarks.dequeueUpTo(length);
		let newMark: Mark = generateNoOpWithCellId(baseMark);
		const movedEffect = getMovedEffectFromBaseMark(this.moveEffects, baseMark);
		if (movedEffect !== undefined) {
			newMark = addMovedMarkEffect(newMark, movedEffect);
		}
		return {
			baseMark,
			newMark,
		};
	}
	private dequeueNew(): RebaseMarks {
		const newMark = this.newMarks.dequeue();
		return { newMark, baseMark: generateNoOpWithCellId(newMark) };
	}
	private dequeueBoth(): RebaseMarks {
		const baseMark = this.baseMarks.peek();
		const newMark = this.newMarks.peek();
		assert(
			baseMark !== undefined && newMark !== undefined,
			0x69c  ,
		);
		const length = Math.min(newMark.count, baseMark.count);
		const sizedBaseMark = this.baseMarks.dequeueUpTo(length);
		const sizedNewMark = this.newMarks.dequeueUpTo(length);
		const movedMark = getMovedEffectFromBaseMark(this.moveEffects, sizedBaseMark);
		return {
			baseMark: sizedBaseMark,
			newMark:
				movedMark === undefined ? sizedNewMark : addMovedMarkEffect(sizedNewMark, movedMark),
		};
	}
}
function addMovedMarkEffect(mark: Mark, effect: Detach): Mark {
	if (isMoveIn(mark) && isMoveOut(effect)) {
		return { ...mark, type: "Insert" };
	} else if (isRename(mark) && isMoveOut(effect)) {
		return { ...effect, count: mark.count, idOverride: mark.idOverride };
	} else if (isAttachAndDetachEffect(mark) && isMoveIn(mark.attach) && isMoveOut(effect)) {
		return { ...mark.detach, count: mark.count };
	} else if (isTombstone(mark)) {
		return { ...mark, ...effect };
	}
	fail(0x818  );
}
interface RebaseMarks {
	baseMark: Mark;
	newMark: Mark;
}
function rebaseMark(
	currMark: Mark,
	baseMark: Mark,
	rebaseChild: NodeChangeRebaser,
	moveEffects: MoveEffectTable,
): Mark {
	const rebasedMark = rebaseNodeChange(cloneMark(currMark), baseMark, rebaseChild);
	const movedNodeChanges = getMovedChangesFromBaseMark(moveEffects, baseMark);
	if (movedNodeChanges !== undefined) {
		assert(
			rebasedMark.changes === undefined,
			0x8dc  ,
		);
		rebasedMark.changes = movedNodeChanges;
		moveEffects.onMoveIn(movedNodeChanges);
	}
	return rebaseMarkIgnoreChild(rebasedMark, baseMark, moveEffects);
}
function rebaseMarkIgnoreChild(
	currMark: Mark,
	baseMark: Mark,
	moveEffects: MoveEffectTable,
): Mark {
	let rebasedMark: Mark;
	if (isDetach(baseMark)) {
		if (baseMark.cellId !== undefined) {
			delete currMark.cellId;
		}
		assert(
			!isNewAttach(currMark),
			0x69d  ,
		);
		const baseCellId = getDetachOutputCellId(baseMark);
		if (isMoveOut(baseMark)) {
			assert(isMoveMark(baseMark), 0x6f0  );
			assert(
				!isNewAttach(currMark),
				0x819  ,
			);
			const { remains, follows } = separateEffectsForMove(extractMarkEffect(currMark));
			if (follows !== undefined) {
				sendEffectToDest(follows, moveEffects, getEndpoint(baseMark), baseMark.count);
			}
			if (currMark.changes !== undefined) {
				moveRebasedChanges(currMark.changes, moveEffects, getEndpoint(baseMark));
			}
			rebasedMark = { ...remains, count: baseMark.count };
		} else {
			rebasedMark = currMark;
		}
		rebasedMark = makeDetachedMark(rebasedMark, cloneCellId(baseCellId));
	} else if (markFillsCells(baseMark)) {
		rebasedMark = isAttachAndDetachEffect(currMark)
			? withNodeChange({ ...currMark.detach, count: currMark.count }, currMark.changes)
			: withCellId(currMark, undefined);
	} else if (isAttachAndDetachEffect(baseMark)) {
		assert(
			baseMark.cellId !== undefined,
			0x81a  ,
		);
		const halfRebasedMark = rebaseMarkIgnoreChild(
			currMark,
			{ ...baseMark.attach, cellId: cloneCellId(baseMark.cellId), count: baseMark.count },
			moveEffects,
		);
		rebasedMark = rebaseMarkIgnoreChild(
			halfRebasedMark,
			{ ...baseMark.detach, count: baseMark.count },
			moveEffects,
		);
	} else if (isRename(baseMark)) {
		return withCellId(currMark, getDetachOutputCellId(baseMark));
	} else {
		rebasedMark = currMark;
	}
	return rebasedMark;
}
function separateEffectsForMove(mark: MarkEffect): {
	remains?: MarkEffect;
	follows?: Detach;
} {
	const type = mark.type;
	switch (type) {
		case "Remove":
		case "MoveOut": {
			if (mark.idOverride !== undefined) {
				const remains: MarkEffect = { type: "Rename", idOverride: mark.idOverride };
				const follows: Mutable<MarkEffect> = { ...mark };
				delete follows.idOverride;
				return { remains, follows };
			}
			return { follows: mark };
		}
		case "AttachAndDetach": {
			return { follows: mark.detach, remains: mark.attach };
		}
		case "MoveIn":
		case "Rename": {
			return { remains: mark };
		}
		case NoopMarkType: {
			return {};
		}
		case "Insert": {
			const follows: MoveOut = {
				type: "MoveOut",
				id: mark.id,
			};
			const remains: MoveIn = {
				type: "MoveIn",
				id: mark.id,
			};
			if (mark.revision !== undefined) {
				follows.revision = mark.revision;
				remains.revision = mark.revision;
			}
			return { remains, follows };
		}
		default: {
			unreachableCase(type);
		}
	}
}
function sendEffectToDest(
	markEffect: Detach,
	moveEffects: MoveEffectTable,
	{ revision, localId: id }: ChangeAtomId,
	count: number,
): void {
	const effect = getMoveEffect(
		moveEffects,
		CrossFieldTarget.Destination,
		revision,
		id,
		count,
		false,
	);
	if (effect.length < count) {
		const [markEffect1, markEffect2] = splitMarkEffect(markEffect, effect.length);
		const newEffect =
			effect.value === undefined
				? { movedMark: markEffect1 }
				: { ...effect.value, movedMark: markEffect1 };
		setMoveEffect(
			moveEffects,
			CrossFieldTarget.Destination,
			revision,
			id,
			effect.length,
			newEffect,
		);
		sendEffectToDest(
			markEffect2,
			moveEffects,
			{ revision, localId: brand(id + effect.length) },
			count - effect.length,
		);
	} else {
		const newEffect: MoveEffect =
			effect.value === undefined
				? { movedEffect: markEffect }
				: { ...effect.value, movedEffect: markEffect };
		setMoveEffect(moveEffects, CrossFieldTarget.Destination, revision, id, count, newEffect);
	}
}
function moveRebasedChanges(
	nodeChange: NodeId,
	moveEffects: MoveEffectTable,
	{ revision, localId: id }: ChangeAtomId,
): void {
	const effect = getMoveEffect(
		moveEffects,
		CrossFieldTarget.Destination,
		revision,
		id,
		1,
		false,
	).value;
	const newEffect =
		effect === undefined
			? { rebasedChanges: nodeChange }
			: { ...effect, rebasedChanges: nodeChange };
	setMoveEffect(moveEffects, CrossFieldTarget.Destination, revision, id, 1, newEffect);
}
function rebaseNodeChange(
	currMark: Mark,
	baseMark: Mark,
	nodeRebaser: NodeChangeRebaser,
): Mark {
	const baseChange = baseMark.changes;
	const currChange = currMark.changes;
	if (baseChange === undefined && currChange === undefined) {
		return currMark;
	}
	const nodeState = nodeStateAfterMark(baseMark);
	return withNodeChange(currMark, nodeRebaser(currChange, baseChange, nodeState));
}
function nodeStateAfterMark(mark: Mark): NodeAttachState {
	if (markEmptiesCells(mark)) {
		return NodeAttachState.Detached;
	} else if (markFillsCells(mark)) {
		return NodeAttachState.Attached;
	} else {
		return mark.cellId === undefined ? NodeAttachState.Attached : NodeAttachState.Detached;
	}
}
function makeDetachedMark(mark: Mark, cellId: ChangeAtomId): Mark {
	assert(mark.cellId === undefined, 0x69f  );
	return { ...mark, cellId };
}
function withCellId<TMark extends Mark>(mark: TMark, cellId: CellId | undefined): TMark {
	const newMark = { ...mark, cellId };
	if (cellId === undefined) {
		delete newMark.cellId;
	}
	return newMark;
}
function getMovedEffectFromBaseMark(
	moveEffects: MoveEffectTable,
	baseMark: Mark,
): Detach | undefined {
	if (isMoveIn(baseMark)) {
		return getMovedEffect(moveEffects, baseMark.revision, baseMark.id, baseMark.count);
	} else if (isAttachAndDetachEffect(baseMark) && isMoveIn(baseMark.attach)) {
		return getMovedEffect(
			moveEffects,
			baseMark.attach.revision,
			baseMark.attach.id,
			baseMark.count,
		);
	} else {
		return undefined;
	}
}
function getMovedEffect(
	moveEffects: MoveEffectTable,
	revision: RevisionTag | undefined,
	id: MoveId,
	count: number,
): Detach | undefined {
	const effect = getMoveEffect(moveEffects, CrossFieldTarget.Destination, revision, id, count);
	assert(effect.length === count, 0x6f3  );
	const movedEffect = effect.value?.movedEffect;
	if (movedEffect === undefined) {
		return undefined;
	}
	if (isMoveOut(movedEffect)) {
		moveEffects.moveKey(CrossFieldTarget.Source, movedEffect.revision, movedEffect.id, count);
	}
	return movedEffect;
}
function getMovedChangesFromBaseMark(
	moveEffects: MoveEffectTable,
	baseMark: Mark,
): NodeId | undefined {
	if (isMoveIn(baseMark)) {
		return getMovedNodeChanges(moveEffects, baseMark.revision, baseMark.id, baseMark.count);
	} else if (isAttachAndDetachEffect(baseMark) && isMoveIn(baseMark.attach)) {
		return getMovedNodeChanges(
			moveEffects,
			baseMark.attach.revision,
			baseMark.attach.id,
			baseMark.count,
		);
	} else {
		return undefined;
	}
}
function getMovedNodeChanges(
	moveEffects: MoveEffectTable,
	revision: RevisionTag | undefined,
	id: MoveId,
	count: number,
): NodeId | undefined {
	return getMoveEffect(moveEffects, CrossFieldTarget.Destination, revision, id, count).value
		?.rebasedChanges;
}
```

### Decision procedure: `feature-libraries/sequence-field/relevantRemovedRoots.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/relevantRemovedRoots.ts:1-57`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function* relevantRemovedRoots(
	change: Changeset,
	relevantRemovedRootsFromChild: RelevantRemovedRootsFromChild,
): Iterable<DeltaDetachedNodeId> {
	for (const mark of change) {
		if (refersToRelevantRemovedRoots(mark)) {
			assert(
				mark.cellId !== undefined,
				0x81d  ,
			);
			const nodeId = nodeIdFromChangeAtom(mark.cellId);
			for (let i = 0; i < mark.count; i += 1) {
				yield offsetDetachId(nodeId, i);
			}
		}
		if (mark.changes !== undefined) {
			yield* relevantRemovedRootsFromChild(mark.changes);
		}
	}
}
function refersToRelevantRemovedRoots(mark: Mark): boolean {
	if (mark.cellId !== undefined) {
		const effect = isAttachAndDetachEffect(mark) ? mark.attach : mark;
		if (isInsert(effect)) {
			return true;
		} else if (isDetachOfRemovedNodes(mark)) {
			return true;
		}
		if (mark.changes !== undefined) {
			return true;
		}
	}
	return false;
}
```

### Decision procedure: `feature-libraries/sequence-field/replaceRevisions.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/replaceRevisions.ts:1-146`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function replaceRevisions(changeset: Changeset, replacer: RevisionReplacer): Changeset {
	const updatedMarks = new MarkListFactory();
	for (const mark of changeset) {
		const updatedMark = updateMark(mark, replacer);
		updatedMarks.push(updatedMark);
	}
	return updatedMarks.list;
}
function updateMark(mark: Mark, replacer: RevisionReplacer): Mark {
	const updatedMark = { ...updateEffect(mark, mark.count, replacer) };
	if (mark.cellId !== undefined) {
		updatedMark.cellId = replacer.getUpdatedAtomId(mark.cellId, mark.count);
	}
	if (mark.changes !== undefined) {
		updatedMark.changes = replacer.getUpdatedAtomId(mark.changes);
	}
	return updatedMark;
}
function updateEffect<TMark extends MarkEffect>(
	input: TMark,
	count: number,
	replacer: RevisionReplacer,
): TMark {
	const mark =
		isDetach(input) || isRename(input) ? updateIdOverride(input, count, replacer) : input;
	const type = mark.type;
	switch (type) {
		case "Rename":
		case NoopMarkType: {
			return mark;
		}
		case "AttachAndDetach": {
			return {
				...mark,
				attach: updateEffect(mark.attach, count, replacer),
				detach: updateEffect(mark.detach, count, replacer),
			};
		}
		case "MoveIn":
		case "MoveOut": {
			return updateMoveEffect<TMark & MoveMarkEffect>(
				mark as MoveMarkEffect,
				count,
				replacer,
			);
		}
		case "Insert":
		case "Remove": {
			return updateRevisionAndId(mark as (TMark & Insert) | (TMark & Remove), count, replacer);
		}
		default: {
			unreachableCase(type);
		}
	}
}
function updateIdOverride<TEffect extends Detach | Rename>(
	effect: TEffect,
	count: number,
	replacer: RevisionReplacer,
): TEffect {
	if (effect.idOverride === undefined) {
		return effect;
	}
	const idOverride = replacer.getUpdatedAtomId(effect.idOverride, count);
	return { ...effect, idOverride };
}
function updateMoveEffect<TEffect extends HasMoveFields>(
	effect: TEffect,
	count: number,
	replacer: RevisionReplacer,
): TEffect {
	return effect.finalEndpoint === undefined
		? updateRevisionAndId(effect, count, replacer)
		: updateRevisionAndId(
				{
					...effect,
					finalEndpoint: replacer.getUpdatedAtomId(effect.finalEndpoint, count),
				},
				count,
				replacer,
			);
}
function updateRevisionAndId<T extends HasRevisionTag & HasMoveId>(
	input: T,
	count: number,
	replacer: RevisionReplacer,
): T {
	if (!replacer.isObsolete(input.revision)) {
		return input;
	}
	const newAtom = replacer.getUpdatedAtomId(makeChangeAtomId(input.id, input.revision), count);
	return withRevisionAndId(input, newAtom.revision, newAtom.localId);
}
function withRevisionAndId<T extends HasRevisionTag>(
	input: T,
	revision: RevisionTag | undefined,
	id: ChangesetLocalId,
): T {
	const updated = { ...input, revision, id };
	if (revision === undefined) {
		delete updated.revision;
	}
	return updated;
}
```

### Decision procedure: `feature-libraries/sequence-field/sequenceFieldChangeHandler.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldChangeHandler.ts:1-28`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type SequenceFieldChangeHandler = FieldChangeHandler<Changeset, SequenceFieldEditor>;
export const sequenceFieldChangeHandler: SequenceFieldChangeHandler = {
	rebaser: sequenceFieldChangeRebaser,
	codecsFactory: sequenceFieldChangeCodecFactory,
	editor: sequenceFieldEditor,
	intoDelta: sequenceFieldToDelta,
	relevantRemovedRoots,
	isEmpty,
	getNestedChanges,
	createEmpty,
	getCrossFieldKeys,
};
```

### Decision procedure: `feature-libraries/sequence-field/sequenceFieldChangeRebaser.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldChangeRebaser.ts:1-25`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type SequenceChangeRebaser = FieldChangeRebaser<Changeset>;
export const sequenceFieldChangeRebaser = {
	compose,
	invert,
	rebase,
	prune,
	replaceRevisions,
	filterEdits,
} as const;
```

### Decision procedure: `feature-libraries/sequence-field/sequenceFieldEditor.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldEditor.ts:1-251`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface SequenceFieldEditor extends FieldEditor<Changeset> {
	insert(index: number, count: number, firstId: CellId, revision: RevisionTag): Changeset;
	remove(index: number, count: number, id: ChangesetLocalId, revision: RevisionTag): Changeset;
	revive(
		index: number,
		count: number,
		detachEvent: CellId,
		revision: RevisionTag,
		isIntention?: true,
	): Changeset;
	move(
		sourceIndex: number,
		count: number,
		destIndex: number,
		detachCellId: ChangesetLocalId,
		attachCellId: CellId,
		revision: RevisionTag,
	): Changeset;
	moveOut(
		sourceIndex: number,
		count: number,
		id: ChangesetLocalId,
		revision: RevisionTag,
	): Changeset;
	moveIn(
		destIndex: number,
		count: number,
		moveId: ChangesetLocalId,
		attachCellId: CellId,
		revision: RevisionTag,
	): Changeset;
	return(
		sourceIndex: number,
		count: number,
		destIndex: number,
		detachCellId: CellId,
		attachCellId: CellId,
		revision: RevisionTag,
	): Changeset;
}
export const sequenceFieldEditor = {
	buildChildChanges: (changes: Iterable<[number, NodeId]>): Changeset => {
		const changeset: Changeset = [];
		let currentIndex = 0;
		for (const [index, change] of changes) {
			assert(index >= currentIndex, 0xabe  );
			if (index > currentIndex) {
				changeset.push({ count: index - currentIndex });
			}
			changeset.push({ count: 1, changes: change });
			currentIndex = index + 1;
		}
		return changeset;
	},
	insert: (
		index: number,
		count: number,
		firstId: CellId,
		revision: RevisionTag | undefined,
	): Changeset => {
		const mark: CellMark<Insert> = {
			type: "Insert",
			id: firstId.localId,
			count,
			cellId: firstId,
			revision,
		};
		return markAtIndex(index, mark);
	},
	remove: (
		index: number,
		count: number,
		id: ChangesetLocalId,
		revision: RevisionTag | undefined,
	): Changeset =>
		count === 0 ? [] : markAtIndex(index, { type: "Remove", count, id, revision }),
	revive: (
		index: number,
		count: number,
		detachEvent: CellId,
		revision: RevisionTag | undefined,
	): Changeset => {
		assert(detachEvent.revision !== undefined, 0x724  );
		const mark: CellMark<Insert> = {
			type: "Insert",
			id: detachEvent.localId,
			count,
			cellId: detachEvent,
			revision,
		};
		return count === 0 ? [] : markAtIndex(index, mark);
	},
	move(
		sourceIndex: number,
		count: number,
		destIndex: number,
		detachCellId: ChangesetLocalId,
		attachCellId: CellId,
		revision: RevisionTag | undefined,
	): Changeset {
		const moveIn: Mark = {
			type: "MoveIn",
			id: detachCellId,
			count,
			cellId: attachCellId,
			revision,
		};
		const moveOut: Mark = {
			type: "MoveOut",
			id: detachCellId,
			count,
			revision,
		};
		return moveMarksToMarkList(sourceIndex, count, destIndex, moveOut, moveIn);
	},
	moveOut(
		sourceIndex: number,
		count: number,
		detachCellId: ChangesetLocalId,
		revision: RevisionTag,
	): Changeset {
		const moveOut: Mark = {
			type: "MoveOut",
			id: detachCellId,
			count,
			revision,
		};
		return markAtIndex(sourceIndex, moveOut);
	},
	moveIn(
		destIndex: number,
		count: number,
		moveId: ChangesetLocalId,
		attachCellId: CellId,
		revision: RevisionTag,
	): Changeset {
		const moveIn: Mark = {
			type: "MoveIn",
			id: moveId,
			count,
			cellId: attachCellId,
			revision,
		};
		return markAtIndex(destIndex, moveIn);
	},
	return(
		sourceIndex: number,
		count: number,
		destIndex: number,
		detachCellId: CellId,
		attachCellId: CellId,
		revision: RevisionTag | undefined,
	): Changeset {
		const moveOut: CellMark<MoveOut> = {
			type: "MoveOut",
			id: attachCellId.localId,
			idOverride: detachCellId,
			count,
			revision,
		};
		const returnTo: CellMark<MoveIn> = {
			type: "MoveIn",
			id: attachCellId.localId,
			count,
			cellId: attachCellId,
			revision,
		};
		return moveMarksToMarkList(sourceIndex, count, destIndex, moveOut, returnTo);
	},
} satisfies SequenceFieldEditor;
function moveMarksToMarkList(
	sourceIndex: number,
	count: number,
	destIndex: number,
	detach: CellMark<MoveOut>,
	attach: CellMark<MoveIn>,
): MarkList {
	if (count === 0) {
		return [];
	}
	const firstIndexBeyondMoveOut = sourceIndex + count;
	const marks = new MarkListFactory();
	marks.pushOffset(Math.min(sourceIndex, destIndex));
	if (destIndex <= sourceIndex) {
		marks.pushContent(attach);
		marks.pushOffset(sourceIndex - destIndex);
		marks.pushContent(detach);
	} else if (firstIndexBeyondMoveOut <= destIndex) {
		marks.pushContent(detach);
		marks.pushOffset(destIndex - firstIndexBeyondMoveOut);
		marks.pushContent(attach);
	} else {
		const firstSectionLength = destIndex - sourceIndex;
		const [detach1, detach2] = splitMark(detach, firstSectionLength);
		marks.pushContent(detach1);
		marks.pushContent(attach);
		marks.pushContent(detach2);
	}
	return marks.list;
}
function markAtIndex(index: number, mark: Mark): Changeset {
	return index === 0 ? [mark] : [{ count: index }, mark];
}
```

### Decision procedure: `feature-libraries/sequence-field/sequenceFieldToDelta.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldToDelta.ts:1-203`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function sequenceFieldToDelta(
	change: MarkList,
	deltaFromChild: ToDelta,
): FieldChangeDelta {
	const local: DeltaMark[] = [];
	const global: DeltaDetachedNodeChanges[] = [];
	const rename: DeltaDetachedNodeRename[] = [];
	for (const mark of change) {
		const deltaMark: Mutable<DeltaMark> = { count: mark.count };
		const inputCellId = getInputCellId(mark);
		const changes = mark.changes;
		if (changes !== undefined) {
			const nestedDelta = deltaFromChild(changes);
			if (nestedDelta.size > 0) {
				if (inputCellId === undefined) {
					deltaMark.fields = nestedDelta;
				} else {
					global.push({
						id: nodeIdFromChangeAtom(inputCellId),
						fields: nestedDelta,
					});
				}
			}
		}
		if (!areInputCellsEmpty(mark) && !areOutputCellsEmpty(mark)) {
			local.push(deltaMark);
		} else if (isAttachAndDetachEffect(mark)) {
			assert(
				inputCellId !== undefined,
				0x81e  ,
			);
			if (isMoveIn(mark.attach) && isMoveOut(mark.detach)) {
				assert(
					mark.changes === undefined,
					0x81f  ,
				);
				continue;
			}
			const outputId = getDetachedNodeId(mark.detach);
			assert(
				outputId !== undefined,
				0x820  ,
			);
			const oldId = nodeIdFromChangeAtom(
				isMoveIn(mark.attach) ? getEndpoint(mark.attach) : inputCellId,
			);
			if (!areEqualChangeAtomIds(inputCellId, outputId)) {
				rename.push({
					count: mark.count,
					oldId,
					newId: nodeIdFromChangeAtom(outputId),
				});
			}
			if (deltaMark.fields) {
				global.push({
					id: oldId,
					fields: deltaMark.fields,
				});
			}
		} else {
			const type = mark.type;
			switch (type) {
				case "MoveIn": {
					local.push({
						attach: nodeIdFromChangeAtom(getEndpoint(mark)),
						count: mark.count,
					});
					break;
				}
				case "Remove": {
					const newDetachId = getDetachedNodeId(mark);
					if (inputCellId === undefined) {
						deltaMark.detach = nodeIdFromChangeAtom(newDetachId);
						local.push(deltaMark);
					} else {
						const oldId = nodeIdFromChangeAtom(inputCellId);
						if (!areEqualChangeAtomIds(inputCellId, newDetachId)) {
							rename.push({
								count: mark.count,
								oldId,
								newId: nodeIdFromChangeAtom(newDetachId),
							});
						}
						if (deltaMark.fields) {
							global.push({
								id: oldId,
								fields: deltaMark.fields,
							});
						}
					}
					break;
				}
				case "MoveOut": {
					const detachId = nodeIdFromChangeAtom(getDetachedNodeId(mark));
					if (inputCellId === undefined) {
						deltaMark.detach = detachId;
						local.push(deltaMark);
					} else {
						rename.push({
							count: mark.count,
							oldId: nodeIdFromChangeAtom(inputCellId),
							newId: detachId,
						});
					}
					break;
				}
				case "Insert": {
					assert(
						inputCellId !== undefined,
						0x821  ,
					);
					const buildId = nodeIdFromChangeAtom(inputCellId);
					deltaMark.attach = buildId;
					if (deltaMark.fields) {
						global.push({ id: buildId, fields: deltaMark.fields });
						delete deltaMark.fields;
					}
					local.push(deltaMark);
					break;
				}
				case NoopMarkType: {
					if (inputCellId === undefined) {
						local.push(deltaMark);
					}
					break;
				}
				case "Rename": {
					assert(
						mark.cellId !== undefined,
						0x9f9  ,
					);
					break;
				}
				default: {
					unreachableCase(type);
				}
			}
		}
	}
	while (hasSome(local)) {
		const lastMark = getLast(local);
		if (
			lastMark.attach !== undefined ||
			lastMark.detach !== undefined ||
			lastMark.fields !== undefined
		) {
			break;
		}
		local.pop();
	}
	const delta: Mutable<FieldChangeDelta> = {};
	if (local.length > 0) {
		delta.local = { marks: local };
	}
	if (global.length > 0) {
		delta.global = global;
	}
	if (rename.length > 0) {
		delta.rename = rename;
	}
	return delta;
}
```

### Decision procedure: `feature-libraries/sequence-field/sequenceKind.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceKind.ts:1-40`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
interface Sequence
	extends FlexFieldKind<
		SequenceFieldEditor,
		typeof sequenceIdentifier,
		Multiplicity.Sequence
	> {}
export const sequence: Sequence = new FlexFieldKind(
	sequenceIdentifier,
	Multiplicity.Sequence,
	{
		changeHandler: sequenceFieldChangeHandler,
		allowMonotonicUpgradeFrom: new Set([
			requiredIdentifier,
			optionalIdentifier,
			identifierFieldIdentifier,
			forbiddenFieldKindIdentifier,
		]),
	},
);
```

### Decision procedure: `feature-libraries/sequence-field/types.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/types.ts:1-180`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type CellCount = number;
export type MoveId = ChangesetLocalId;
export interface HasMoveId {
	id: MoveId;
}
export interface CellId extends ChangeAtomId {}
export interface HasMarkFields {
	cellId?: CellId;
	changes?: NodeId;
	count: CellCount;
}
export const NoopMarkType = undefined;
export interface NoopMark {
	type?: typeof NoopMarkType;
}
export interface HasRevisionTag {
	revision?: RevisionTag;
}
export interface Insert extends HasMoveId, HasRevisionTag {
	type: "Insert";
}
export interface HasMoveFields extends HasMoveId, HasRevisionTag {
	finalEndpoint?: ChangeAtomId;
}
export interface MoveIn extends HasMoveFields {
	type: "MoveIn";
}
export interface DetachFields {
	readonly idOverride?: CellId;
}
export interface Remove extends HasRevisionTag, DetachFields {
	type: "Remove";
	id: ChangesetLocalId;
}
export interface MoveOut extends HasMoveFields, DetachFields {
	type: "MoveOut";
}
export type Attach = Insert | MoveIn;
export type Detach = Remove | MoveOut;
export interface AttachAndDetach {
	type: "AttachAndDetach";
	attach: Attach;
	detach: Detach;
}
export interface Rename {
	type: "Rename";
	readonly idOverride: CellId;
}
export type MarkEffect = NoopMark | Attach | Detach | AttachAndDetach | Rename;
export type CellMark<TMark> = TMark & HasMarkFields;
export type Mark = CellMark<MarkEffect>;
export type MarkList = Mark[];
export type Changeset = MarkList;
```

### Decision procedure: `feature-libraries/sequence-field/utils.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/utils.ts:1-1001`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function isEmpty(change: Changeset): boolean {
	for (const mark of change) {
		if (mark.changes !== undefined || mark.type !== undefined) {
			return false;
		}
	}
	return true;
}
export function createEmpty(): Changeset {
	return [];
}
export function getNestedChanges(change: Changeset): ChildChangeInfo[] {
	const output: ChildChangeInfo[] = [];
	for (const mark of change) {
		if (mark.changes !== undefined) {
			const detachId = isDetach(mark) ? getDetachedNodeId(mark) : undefined;
			output.push({ nodeId: mark.changes, inputRootId: mark.cellId, detachId });
		}
	}
	return output;
}
export function isNewAttach(mark: Mark, revision?: RevisionTag): boolean {
	return isNewAttachEffect(mark, mark.cellId, revision);
}
export function isNewAttachEffect(
	effect: MarkEffect,
	cellId: CellId | undefined,
	revision?: RevisionTag,
): boolean {
	return (
		(isAttach(effect) &&
			cellId !== undefined &&
			(effect.revision ?? revision) === (cellId.revision ?? revision)) ||
		(isAttachAndDetachEffect(effect) && isNewAttachEffect(effect.attach, cellId, revision))
	);
}
export function isRename(mark: MarkEffect): mark is Rename {
	return mark.type === "Rename";
}
export function isInsert(mark: MarkEffect): mark is Insert {
	return mark.type === "Insert";
}
export function isAttach(effect: MarkEffect): effect is Attach {
	return effect.type === "Insert" || effect.type === "MoveIn";
}
export function isReattach(mark: Mark): boolean {
	return isReattachEffect(mark, mark.cellId);
}
export function isReattachEffect(effect: MarkEffect, cellId: CellId | undefined): boolean {
	return isAttach(effect) && !isNewAttachEffect(effect, cellId);
}
export function isActiveReattach(
	mark: Mark,
): mark is CellMark<Insert> & { conflictsWith?: undefined } {
	return isAttach(mark) && isReattachEffect(mark, mark.cellId) && mark.cellId !== undefined;
}
export function areEqualCellIds(a: CellId | undefined, b: CellId | undefined): boolean {
	return areEqualChangeAtomIdOpts(a, b);
}
export function getInputCellId(mark: Mark): CellId | undefined {
	return mark.cellId;
}
export function getOutputCellId(mark: Mark): CellId | undefined {
	if (isDetach(mark) || isRename(mark)) {
		return getDetachOutputCellId(mark);
	} else if (markFillsCells(mark)) {
		return undefined;
	} else if (isAttachAndDetachEffect(mark)) {
		return getDetachOutputCellId(mark.detach);
	}
	return getInputCellId(mark);
}
export function cellSourcesFromMarks(
	marks: readonly Mark[],
	contextGetter: typeof getInputCellId | typeof getOutputCellId,
): Set<RevisionTag | undefined> {
	const set = new Set<RevisionTag | undefined>();
	for (const mark of marks) {
		const cell = contextGetter(mark);
		if (cell !== undefined) {
			set.add(cell.revision);
		}
	}
	return set;
}
export enum CellOrder {
	SameCell,
	OldThenNew,
	NewThenOld,
}
export function compareCellPositionsUsingTombstones(
	oldMarkCell: ChangeAtomId,
	newMarkCell: ChangeAtomId,
	oldChangeKnowledge: ReadonlySet<RevisionTag | undefined>,
	newChangeKnowledge: ReadonlySet<RevisionTag | undefined>,
	metadata: RevisionMetadataSource,
): CellOrder {
	if (areEqualChangeAtomIds(oldMarkCell, newMarkCell)) {
		return CellOrder.SameCell;
	}
	const oldChangeKnowsOfNewMarkCellRevision = oldChangeKnowledge.has(newMarkCell.revision);
	const newChangeKnowsOfOldMarkCellRevision = newChangeKnowledge.has(oldMarkCell.revision);
	if (oldChangeKnowsOfNewMarkCellRevision && newChangeKnowsOfOldMarkCellRevision) {
		assert(
			oldMarkCell.revision === newMarkCell.revision,
			0x8a0  ,
		);
		return CellOrder.NewThenOld;
	}
	if (newChangeKnowsOfOldMarkCellRevision) {
		return CellOrder.NewThenOld;
	} else if (oldChangeKnowsOfNewMarkCellRevision) {
		return CellOrder.OldThenNew;
	} else {
		if (newMarkCell.revision === undefined) {
			return CellOrder.NewThenOld;
		}
		assert(
			oldMarkCell.revision !== undefined,
			0x8a1  ,
		);
		const oldCellRevisionIndex = metadata.getIndex(oldMarkCell.revision);
		const newCellRevisionIndex = metadata.getIndex(newMarkCell.revision);
		if (newCellRevisionIndex !== undefined && oldCellRevisionIndex !== undefined) {
			return newCellRevisionIndex > oldCellRevisionIndex
				? CellOrder.NewThenOld
				: CellOrder.OldThenNew;
		}
		if (newCellRevisionIndex === undefined && oldCellRevisionIndex === undefined) {
			fail(0x8a2  );
		}
		return oldCellRevisionIndex === undefined ? CellOrder.NewThenOld : CellOrder.OldThenNew;
	}
}
export function getDetachOutputCellId(mark: Detach | Rename): ChangeAtomId {
	if (isRename(mark)) {
		return mark.idOverride;
	}
	if (mark.idOverride !== undefined) {
		return mark.idOverride;
	}
	return mark.revision === undefined
		? { localId: mark.id }
		: { revision: mark.revision, localId: mark.id };
}
export function getDetachedNodeId(mark: Detach | Rename): ChangeAtomId {
	switch (mark.type) {
		case "Rename":
		case "Remove": {
			return getDetachOutputCellId(mark);
		}
		case "MoveOut": {
			return makeChangeAtomId(mark.id, mark.revision);
		}
		default: {
			unreachableCase(mark);
		}
	}
}
export function normalizeCellRename(
	cellId: CellId,
	count: CellCount,
	attach: Attach,
	detach: Detach,
): CellMark<AttachAndDetach | DetachOfRemovedNodes | Rename | NoopMark> {
	if (attach.type === "MoveIn") {
		if (detach.type === "MoveOut") {
			const outputId = getDetachOutputCellId(detach);
			return {
				type: "Rename",
				count,
				cellId,
				idOverride: outputId,
			};
		}
	} else {
		return {
			...detach,
			count,
			cellId,
		};
	}
	return {
		type: "AttachAndDetach",
		attach,
		detach,
		count,
		cellId,
	};
}
export function asAttachAndDetach(mark: CellMark<CellRename>): CellMark<AttachAndDetach> {
	if (mark.type === "AttachAndDetach") {
		return mark;
	}
	const { cellId, count, changes, revision, ...effect } = mark;
	const attachAndDetach: CellMark<AttachAndDetach | Detach> = {
		type: "AttachAndDetach",
		count,
		cellId,
		attach: {
			type: "Insert",
			id: mark.id,
		},
		detach: effect,
	};
	if (changes !== undefined) {
		attachAndDetach.changes = changes;
	}
	if (revision !== undefined) {
		attachAndDetach.attach.revision = revision;
		attachAndDetach.detach.revision = revision;
	}
	return attachAndDetach;
}
export function cloneMark<TMark extends Mark>(mark: TMark): TMark {
	const clone: TMark = { ...cloneMarkEffect(mark), count: mark.count };
	if (mark.cellId !== undefined) {
		clone.cellId = cloneCellId(mark.cellId);
	}
	return clone;
}
export function cloneMarkEffect<TEffect extends MarkEffect>(effect: TEffect): TEffect {
	const clone = { ...effect };
	if (clone.type === "AttachAndDetach") {
		clone.attach = cloneMarkEffect(clone.attach);
		clone.detach = cloneMarkEffect(clone.detach);
	}
	return clone;
}
export function cloneCellId(id: CellId): CellId {
	const cloned = { ...id };
	return cloned;
}
export function getOutputLength(mark: Mark, ignorePairing: boolean = false): number {
	return areOutputCellsEmpty(mark) ? 0 : mark.count;
}
export function getInputLength(mark: Mark): number {
	return areInputCellsEmpty(mark) ? 0 : mark.count;
}
export function markEmptiesCells(mark: Mark): boolean {
	return !areInputCellsEmpty(mark) && areOutputCellsEmpty(mark);
}
export function markFillsCells(mark: Mark): boolean {
	return areInputCellsEmpty(mark) && !areOutputCellsEmpty(mark);
}
export function markHasCellEffect(mark: Mark): boolean {
	return areInputCellsEmpty(mark) !== areOutputCellsEmpty(mark);
}
export function isAttachAndDetachEffect(effect: MarkEffect): effect is AttachAndDetach {
	return effect.type === "AttachAndDetach";
}
export function isDetachOfRemovedNodes(mark: Mark): mark is CellMark<DetachOfRemovedNodes> {
	return isDetach(mark) && mark.cellId !== undefined;
}
export function isImpactfulCellRename(mark: Mark): mark is CellMark<CellRename> {
	return (isAttachAndDetachEffect(mark) || isDetachOfRemovedNodes(mark)) && isImpactful(mark);
}
export function areInputCellsEmpty(mark: Mark): mark is EmptyInputCellMark {
	return mark.cellId !== undefined;
}
export function areOutputCellsEmpty(mark: Mark): boolean {
	const type = mark.type;
	switch (type) {
		case NoopMarkType: {
			return mark.cellId !== undefined;
		}
		case "Remove":
		case "Rename":
		case "MoveOut":
		case "AttachAndDetach": {
			return true;
		}
		case "MoveIn":
		case "Insert": {
			return false;
		}
		default: {
			unreachableCase(type);
		}
	}
}
export function settleMark(mark: Mark): Mark {
	if (isImpactful(mark)) {
		return mark;
	}
	return omitMarkEffect(mark);
}
export function isImpactful(mark: Mark): boolean {
	const type = mark.type;
	switch (type) {
		case NoopMarkType: {
			return false;
		}
		case "Rename": {
			return true;
		}
		case "Remove": {
			const inputId = getInputCellId(mark);
			if (inputId === undefined) {
				return true;
			}
			const outputId = getOutputCellId(mark);
			assert(outputId !== undefined, 0x824  );
			return !areEqualChangeAtomIds(inputId, outputId);
		}
		case "AttachAndDetach":
		case "MoveOut": {
			return true;
		}
		case "MoveIn": {
			assert(mark.cellId !== undefined, 0x825  );
			return true;
		}
		case "Insert": {
			return mark.cellId !== undefined;
		}
		default: {
			unreachableCase(type);
		}
	}
}
export function isTombstone(mark: Mark): mark is CellMark<NoopMark> & { cellId: CellId } {
	return mark.type === NoopMarkType && mark.cellId !== undefined && mark.changes === undefined;
}
export function isNoopMark(mark: Mark): mark is CellMark<NoopMark> {
	return mark.type === NoopMarkType;
}
export function areOverlappingIdRanges(
	id1: ChangesetLocalId,
	count1: number,
	id2: ChangesetLocalId,
	count2: number,
): boolean {
	const lastId1 = (id1 as number) + count1 - 1;
	const lastId2 = (id2 as number) + count2 - 1;
	return (id2 <= id1 && id1 <= lastId2) || (id1 <= id2 && id2 <= lastId1);
}
export function compareCellsFromSameRevision(
	cell1: CellId,
	count1: number,
	cell2: CellId,
	count2: number,
): number | undefined {
	assert(
		cell1.revision === cell2.revision,
		0x85b  ,
	);
	if (areOverlappingIdRanges(cell1.localId, count1, cell2.localId, count2)) {
		return cell1.localId - cell2.localId;
	}
	return undefined;
}
export function isDetach(mark: MarkEffect | undefined): mark is Detach {
	const type = mark?.type;
	return type === "Remove" || type === "MoveOut";
}
export function isRemoveMark(mark: Mark | undefined): mark is CellMark<Remove> {
	return mark?.type === "Remove";
}
function areMergeableChangeAtoms(
	lhs: ChangeAtomId | undefined,
	lhsCount: number,
	rhs: ChangeAtomId | undefined,
): boolean {
	if (lhs === undefined || rhs === undefined) {
		return lhs === undefined && rhs === undefined;
	}
	return (
		lhs.revision === rhs.revision && areAdjacentIdRanges(lhs.localId, lhsCount, rhs.localId)
	);
}
function areAdjacentIdRanges(
	firstStart: ChangesetLocalId,
	firstLength: number,
	secondStart: ChangesetLocalId,
): boolean {
	return (firstStart as number) + firstLength === secondStart;
}
function haveMergeableIdOverrides(
	lhs: DetachFields,
	lhsCount: number,
	rhs: DetachFields,
): boolean {
	if (lhs.idOverride !== undefined && rhs.idOverride !== undefined) {
		return areMergeableCellIds(lhs.idOverride, lhsCount, rhs.idOverride);
	}
	return (lhs.idOverride === undefined) === (rhs.idOverride === undefined);
}
function areMergeableCellIds(
	lhs: CellId | undefined,
	lhsCount: number,
	rhs: CellId | undefined,
): boolean {
	return areMergeableChangeAtoms(lhs, lhsCount, rhs);
}
export function tryMergeMarks(lhs: Mark, rhs: Readonly<Mark>): Mark | undefined {
	if (rhs.type !== lhs.type) {
		return undefined;
	}
	if (!areMergeableCellIds(lhs.cellId, lhs.count, rhs.cellId)) {
		return undefined;
	}
	if (rhs.changes !== undefined || lhs.changes !== undefined) {
		return undefined;
	}
	const mergedEffect = tryMergeEffects(lhs, rhs, lhs.count);
	if (mergedEffect === undefined) {
		return undefined;
	}
	return { ...lhs, ...mergedEffect, count: lhs.count + rhs.count };
}
function tryMergeEffects(
	lhs: MarkEffect,
	rhs: MarkEffect,
	lhsCount: number,
): MarkEffect | undefined {
	if (lhs.type !== rhs.type) {
		return undefined;
	}
	if (rhs.type === NoopMarkType) {
		return lhs;
	}
	if (rhs.type === "AttachAndDetach") {
		const lhsAttachAndDetach = lhs as AttachAndDetach;
		const attach = tryMergeEffects(lhsAttachAndDetach.attach, rhs.attach, lhsCount);
		const detach = tryMergeEffects(lhsAttachAndDetach.detach, rhs.detach, lhsCount);
		if (attach === undefined || detach === undefined) {
			return undefined;
		}
		assert(
			isAttach(attach) && isDetach(detach),
			0x826  ,
		);
		return { ...lhsAttachAndDetach, attach, detach };
	}
	if (
		(lhs as Partial<HasRevisionTag>).revision !== (rhs as Partial<HasRevisionTag>).revision
	) {
		return undefined;
	}
	if (isDetach(lhs) && isDetach(rhs) && !haveMergeableIdOverrides(lhs, lhsCount, rhs)) {
		return undefined;
	}
	const type = rhs.type;
	switch (type) {
		case "MoveIn": {
			const lhsMoveIn = lhs as MoveIn;
			if (
				(lhsMoveIn.id as number) + lhsCount === rhs.id &&
				areMergeableChangeAtoms(lhsMoveIn.finalEndpoint, lhsCount, rhs.finalEndpoint)
			) {
				return lhsMoveIn;
			}
			break;
		}
		case "Remove": {
			const lhsDetach = lhs as Remove;
			if (
				(lhsDetach.id as number) + lhsCount === rhs.id &&
				haveMergeableIdOverrides(lhsDetach, lhsCount, rhs)
			) {
				return lhsDetach;
			}
			break;
		}
		case "Rename": {
			const lhsDetach = lhs as Rename;
			if (haveMergeableIdOverrides(lhsDetach, lhsCount, rhs)) {
				return lhsDetach;
			}
			break;
		}
		case "MoveOut": {
			const lhsMoveOut = lhs as MoveOut;
			if (
				(lhsMoveOut.id as number) + lhsCount === rhs.id &&
				haveMergeableIdOverrides(lhsMoveOut, lhsCount, rhs) &&
				areMergeableChangeAtoms(lhsMoveOut.finalEndpoint, lhsCount, rhs.finalEndpoint)
			) {
				return lhsMoveOut;
			}
			break;
		}
		case "Insert": {
			const lhsInsert = lhs as Insert;
			if ((lhsInsert.id as number) + lhsCount === rhs.id) {
				return lhsInsert;
			}
			break;
		}
		default: {
			unreachableCase(type);
		}
	}
	return undefined;
}
export function splitMark<TMark extends Mark>(mark: TMark, length: number): [TMark, TMark] {
	const markLength = mark.count;
	const remainder = markLength - length;
	if (length < 1 || remainder < 1) {
		fail(0xb2d  );
	}
	const [effect1, effect2] = splitMarkEffect(mark, length);
	const mark1 = { ...mark, ...effect1, count: length };
	const mark2 = { ...mark, ...effect2, count: remainder };
	if (mark2.cellId !== undefined) {
		mark2.cellId = splitDetachEvent(mark2.cellId, length);
	}
	return [mark1, mark2];
}
export function splitMarkEffect<TEffect extends MarkEffect>(
	effect: TEffect,
	length: number,
): [TEffect, TEffect] {
	const type = effect.type;
	switch (type) {
		case NoopMarkType: {
			return [effect, effect];
		}
		case "Insert": {
			const effect1: TEffect = {
				...effect,
			};
			const effect2: TEffect = {
				...effect,
				id: (effect.id as number) + length,
			};
			return [effect1, effect2];
		}
		case "MoveIn": {
			const effect2: TEffect = { ...effect, id: (effect.id as number) + length };
			const move2 = effect2 as MoveIn;
			if (move2.finalEndpoint !== undefined) {
				move2.finalEndpoint = splitDetachEvent(move2.finalEndpoint, length);
			}
			return [effect, effect2];
		}
		case "Remove": {
			const effect1 = { ...effect };
			const id2: ChangesetLocalId = brand((effect.id as number) + length);
			const effect2 = { ...effect, id: id2 };
			const effect2Remove = effect2 as Mutable<Remove>;
			if (effect2Remove.idOverride !== undefined) {
				effect2Remove.idOverride = splitDetachEvent(effect2Remove.idOverride, length);
			}
			return [effect1, effect2];
		}
		case "Rename": {
			const effect1 = { ...effect };
			const effect2 = { ...effect };
			const effect2Rename = effect2 as Mutable<Rename>;
			if (effect2Rename.idOverride !== undefined) {
				effect2Rename.idOverride = splitDetachEvent(effect2Rename.idOverride, length);
			}
			return [effect1, effect2];
		}
		case "MoveOut": {
			const effect2 = {
				...effect,
				id: (effect.id as number) + length,
			};
			const return2 = effect2 as Mutable<MoveOut>;
			if (return2.idOverride !== undefined) {
				return2.idOverride = splitDetachEvent(return2.idOverride, length);
			}
			if (return2.finalEndpoint !== undefined) {
				return2.finalEndpoint = splitDetachEvent(return2.finalEndpoint, length);
			}
			return [effect, effect2];
		}
		case "AttachAndDetach": {
			const [attach1, attach2] = splitMarkEffect(effect.attach, length);
			const [detach1, detach2] = splitMarkEffect(effect.detach, length);
			const effect1 = {
				...effect,
				attach: attach1,
				detach: detach1,
			};
			const effect2 = {
				...effect,
				attach: attach2,
				detach: detach2,
			};
			return [effect1, effect2];
		}
		default: {
			unreachableCase(type);
		}
	}
}
function splitDetachEvent(detachEvent: CellId, length: number): CellId {
	return { ...detachEvent, localId: brand((detachEvent.localId as number) + length) };
}
export function extractMarkEffect<TEffect extends MarkEffect>(
	mark: CellMark<TEffect>,
): TEffect {
	const { cellId: _cellId, count: _count, changes: _changes, ...effect } = mark;
	return effect as unknown as TEffect;
}
export function omitMarkEffect(mark: CellMark<unknown>): CellMark<NoopMark> {
	const { cellId, count, changes } = mark;
	const noopMark: CellMark<NoopMark> = { count };
	if (cellId !== undefined) {
		noopMark.cellId = cellId;
	}
	if (changes !== undefined) {
		noopMark.changes = changes;
	}
	return noopMark;
}
export function withNodeChange<TMark extends CellMark<TKind>, TKind extends MarkEffect>(
	mark: TMark,
	changes: NodeId | undefined,
): TMark {
	const newMark = { ...mark };
	if (changes === undefined) {
		delete newMark.changes;
	} else {
		newMark.changes = changes;
	}
	return newMark;
}
export function withRevision<TMark extends Mark>(
	mark: TMark,
	revision: RevisionTag | undefined,
): TMark {
	if (revision === undefined) {
		return mark;
	}
	const cloned = cloneMark(mark);
	addRevision(cloned, revision);
	if (
		cloned.cellId !== undefined &&
		cloned.cellId.revision === undefined &&
		revision !== undefined
	) {
		(cloned.cellId as Mutable<CellId>).revision = revision;
	}
	return cloned;
}
function addRevision(effect: MarkEffect, revision: RevisionTag): void {
	if (effect.type === NoopMarkType || isRename(effect)) {
		return;
	}
	if (effect.type === "AttachAndDetach") {
		addRevision(effect.attach, revision);
		addRevision(effect.detach, revision);
		return;
	}
	assert(
		effect.revision === undefined || effect.revision === revision,
		0x829  ,
	);
	effect.revision = revision;
}
export function getEndpoint(effect: MoveMarkEffect): ChangeAtomId {
	return effect.finalEndpoint ?? { revision: effect.revision, localId: effect.id };
}
export function getCrossFieldKeys(change: Changeset): CrossFieldKeyRange[] {
	const keys: CrossFieldKeyRange[] = [];
	for (const mark of change) {
		keys.push(...getCrossFieldKeysForMarkEffect(mark, mark.count));
	}
	return keys;
}
function getCrossFieldKeysForMarkEffect(
	effect: MarkEffect,
	count: number,
): CrossFieldKeyRange[] {
	switch (effect.type) {
		case "Insert": {
			return [
				{
					key: {
						target: CrossFieldTarget.Source,
						revision: effect.revision,
						localId: effect.id,
					},
					count,
				},
				{
					key: {
						target: CrossFieldTarget.Destination,
						revision: effect.revision,
						localId: effect.id,
					},
					count,
				},
			];
		}
		case "MoveOut": {
			return [
				{
					key: {
						target: CrossFieldTarget.Source,
						revision: effect.revision,
						localId: effect.id,
					},
					count,
				},
			];
		}
		case "MoveIn": {
			return [
				{
					key: {
						target: CrossFieldTarget.Destination,
						revision: effect.revision,
						localId: effect.id,
					},
					count,
				},
			];
		}
		case "AttachAndDetach": {
			return [
				...getCrossFieldKeysForMarkEffect(effect.attach, count),
				...getCrossFieldKeysForMarkEffect(effect.detach, count),
			];
		}
		default: {
			return [];
		}
	}
}
```

## 5. Invariants and asserts

0x692/count=1 for child edit; 0x8a0 inconsistent cell ordering; 0x8a1 undefined old revision; 0x8a2 unordered cells outside metadata; 0x69d new attach cannot rebase over its cell being emptied; 0x8dc moved child collision; 0x6f3 cross-field effect must cover full range. V2/V3 codec constraints are not a substitute for in-memory invariants. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/compose.ts:453` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/utils.ts:183` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/rebase.ts:267` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/rebase.ts:533`

## 6. JS-semantics hazards

Noop discriminant is undefined, not a string. `cellId` missing differs from present even if effect ID matches. Offsets apply to ID ranges as well as counts; never merge marks with noncontiguous identities/endpoints. Cross-field tables are shared across all fields and may invalidate previously processed output. Object insertion order of encoded marks/effects matters to byte-exact snapshots. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/types.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/markListFactory.ts:12` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/moveEffectTable.ts:24`

## 7. Test assets to reuse

Reuse sequence-field compose/invert/rebase suites, exhaustive rebaser tests and sequence-field snapshots. Include concurrent inserts at same gap, overlapping moves, move chains, revive after remove, remove over move, rollback vs undo, children moving across fields, and normalized tombstones. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/feature-libraries/sequence-field/compose.test.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/test/feature-libraries/sequence-field/rebase.test.ts:1` `reference/fluidframework-3.11.0/packages/dds/tree/src/test/feature-libraries/sequence-field/invert.test.ts:1`

## 8. Open questions

None for registered codecs. Source comments claiming moves unsupported in compose are stale relative to executable branches; the algorithms above follow code, not those comments. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/compose.ts:223`

