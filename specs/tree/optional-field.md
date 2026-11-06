# Optional Field — Fluid Framework 3.11.0

## 1. Role

Optional-field is a register-move CRDT for zero-or-one child, also reused by required fields. The live register is `self`; detached registers are atom IDs. This is not a last-writer-wins scalar register. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalField.ts:160` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/requiredField.ts:18`

## 2. Surface used by other packages

Optional change handler/rebaser/editor, optional and required FlexFieldKinds, register maps; `OptionalChangeset {moves,childChanges,valueReplace?}`, `Replace {isEmpty,src?,dst}`. `src` missing clears; `src=self` preserves intention without an effective move. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalFieldChangeTypes.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalField.ts:160`

## 3. Wire and persisted formats

Only codec version 2 is registered; formatV1 source is not a reader. JSON `{m?,r?,c?}` emitted in that order. `m` array `[srcAtom,dstAtom]`; `r` object emitted `{e:isEmpty,d:dstAtom,s?:srcRegister}`; `c` array `[register,inlineNodeChange]`. Empty m/c omitted; empty change `{}`. Register self encodes as JSON null, detached ID uses context-sensitive atom codec; omitted r.s means clear and differs from null (self). Child changes inline via modular node encoder. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalFieldCodecs.ts:20` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalFieldCodecV2.ts:27` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalFieldCodecV2.ts:68`


### Decision procedure: `feature-libraries/optional-field/optionalFieldChangeFormatV1.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalFieldChangeFormatV1.ts:1-59`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
export const EncodedRegisterId = Type.Union([EncodedChangeAtomId, Type.Null()]);
export type EncodedRegisterId = Static<typeof EncodedRegisterId>;
export const EncodedBuild = Type.Tuple([EncodedChangeAtomId]);
export type EncodedBuild = Static<typeof EncodedBuild>;
export const EncodedOptionalChangeset = <Schema extends TSchema>(tNodeChange: Schema) =>
	Type.Object(
		{
			b: Type.Optional(Type.Array(EncodedBuild)),
			m: EncodedMoves,
			c: EncodedChildChanges(tNodeChange),
			d: Type.Optional(EncodedRegisterId),
		},
		noAdditionalProps,
	);
export type EncodedOptionalChangeset<Schema extends TSchema> = Static<
	ReturnType<typeof EncodedOptionalChangeset<Schema>>
>;
const EncodedChildChanges = <Schema extends TSchema>(tNodeChange: Schema) =>
	Type.Optional(Type.Array(Type.Tuple([EncodedRegisterId, tNodeChange])));
const EncodedMoves = Type.Optional(
	Type.Array(
		Type.Tuple([EncodedRegisterId, EncodedRegisterId, Type.Optional(Type.Boolean())]),
	),
);
```

### Decision procedure: `feature-libraries/optional-field/optionalFieldChangeFormatV2.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalFieldChangeFormatV2.ts:1-65`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
const noAdditionalProps: ObjectOptions = { additionalProperties: false };
export const EncodedRegisterId = Type.Union([EncodedChangeAtomId, Type.Null()]);
export type EncodedRegisterId = Static<typeof EncodedRegisterId>;
export const EncodedOptionalChangeset = <Schema extends TSchema>(tNodeChange: Schema) =>
	Type.Object(
		{
			m: Type.Optional(Type.Array(EncodedMove)),
			c: Type.Optional(EncodedChildChanges(tNodeChange)),
			r: Type.Optional(EncodedReplace),
		},
		noAdditionalProps,
	);
export type EncodedOptionalChangeset<Schema extends TSchema> = Static<
	ReturnType<typeof EncodedOptionalChangeset<Schema>>
>;
const EncodedChildChanges = <Schema extends TSchema>(tNodeChange: Schema) =>
	Type.Array(Type.Tuple([EncodedRegisterId, tNodeChange]));
const EncodedMove = Type.Tuple([EncodedChangeAtomId, EncodedChangeAtomId]);
const EncodedReplace = Type.Object(
	{
		e: Type.Boolean(),
		s: Type.Optional(EncodedRegisterId),
		d: EncodedChangeAtomId,
	},
	noAdditionalProps,
);
export type EncodedReplace = Static<typeof EncodedReplace>;
```

### Decision procedure: `feature-libraries/optional-field/optionalFieldCodecV2.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalFieldCodecV2.ts:1-132`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
function makeRegisterIdCodec(
	changeAtomIdCodec: JsonCodecPart<
		ChangeAtomId,
		typeof EncodedChangeAtomId,
		ChangeEncodingContext
	>,
): JsonCodecPart<RegisterId, typeof EncodedRegisterId, ChangeEncodingContext> {
	return {
		encode: (registerId: RegisterId, context: ChangeEncodingContext) => {
			if (registerId === "self") {
				return null;
			}
			return changeAtomIdCodec.encode(registerId, context);
		},
		decode: (registerId: EncodedRegisterId, context: ChangeEncodingContext) => {
			if (registerId === null) {
				return "self";
			}
			return changeAtomIdCodec.decode(registerId, context);
		},
		encodedSchema: EncodedRegisterId,
	};
}
export function makeOptionalFieldCodec(
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
): IJsonCodec<
	OptionalChangeset,
	EncodedOptionalChangeset<TAnySchema>,
	EncodedOptionalChangeset<TAnySchema>,
	FieldChangeEncodingContext,
	FieldChangeDecodingContext
> {
	const changeAtomIdCodec = makeChangeAtomIdCodec(revisionTagCodec);
	const registerIdCodec = makeRegisterIdCodec(changeAtomIdCodec);
	return {
		encode: (change: OptionalChangeset, context: FieldChangeEncodingContext) => {
			const encoded: EncodedOptionalChangeset<TAnySchema> = {};
			if (change.moves.length > 0) {
				encoded.m = change.moves.map(([src, dst]) => [
					changeAtomIdCodec.encode(src, context.baseContext),
					changeAtomIdCodec.encode(dst, context.baseContext),
				]);
			}
			if (change.valueReplace !== undefined) {
				encoded.r = {
					e: change.valueReplace.isEmpty,
					d: changeAtomIdCodec.encode(change.valueReplace.dst, context.baseContext),
				};
				if (change.valueReplace.src !== undefined) {
					encoded.r.s = registerIdCodec.encode(change.valueReplace.src, context.baseContext);
				}
			}
			if (change.childChanges.length > 0) {
				encoded.c = [];
				for (const [id, childChange] of change.childChanges) {
					encoded.c.push([
						registerIdCodec.encode(id, context.baseContext),
						context.encodeNode(childChange),
					]);
				}
			}
			return encoded;
		},
		decode: (
			encoded: EncodedOptionalChangeset<TAnySchema>,
			context: FieldChangeDecodingContext,
		) => {
			const decoded: Mutable<OptionalChangeset> = {
				moves:
					encoded.m?.map(([encodedSrc, encodedDst]) => [
						changeAtomIdCodec.decode(encodedSrc, context.baseContext),
						changeAtomIdCodec.decode(encodedDst, context.baseContext),
					]) ?? [],
				childChanges:
					encoded.c?.map(([id, encodedChange]) => [
						registerIdCodec.decode(id, context.baseContext),
						context.decodeNode(encodedChange),
					]) ?? [],
			};
			if (encoded.r !== undefined) {
				const replace: Mutable<Replace> = {
					isEmpty: encoded.r.e,
					dst: changeAtomIdCodec.decode(encoded.r.d, context.baseContext),
				};
				if (encoded.r.s !== undefined) {
					replace.src = registerIdCodec.decode(encoded.r.s, context.baseContext);
				}
				decoded.valueReplace = replace;
			}
			return decoded;
		},
		encodedSchema: EncodedOptionalChangeset(EncodedNodeChangeset),
	};
}
```

### Decision procedure: `feature-libraries/optional-field/optionalFieldCodecs.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalFieldCodecs.ts:1-27`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const makeOptionalFieldCodecFamily = (
	revisionTagCodec: JsonCodecPart<
		RevisionTag,
		typeof RevisionTagSchema,
		ChangeEncodingContext
	>,
): ICodecFamily<OptionalChangeset, FieldChangeEncodingContext, FieldChangeDecodingContext> =>
	makeCodecFamily([[2, makeV2Codec(revisionTagCodec)]]);
```

### Literal emission examples

V2 only is registered. Empty change (empty moves/childChanges, no replace) emits `{}`. Clear an occupied field to detached atom 4: `{"r":{"e":false,"d":4}}`; fill an empty field from built atom 0: `{"r":{"e":true,"d":1,"s":0}}`; keep the existing live node but create an undo destination: `{"r":{"e":false,"d":1,"s":null}}`. Detached move and nested live-node edit together: `{"m":[[0,1]],"c":[[null,{}]]}`. All atoms here belong to context revision. Outer order is m→r→c; r order e→d→s. Absent r.s clears the live field; explicit null means self, not clear. Missing m/c decode to empty arrays, not absent in-memory properties. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalFieldCodecV2.ts:27-132` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalFieldCodecs.ts:20-27`

## 4. Behavior

### Compose A then B

Build bidirectional maps from A.moves. Effective A field destination exists only when replace exists, input nonempty, src not self. Resolve B field source backwards through A: self→A.src or self; A effective dst→self; otherwise A move inverse or unchanged. If B has no replacement, retain A source. Remap B child registers backwards the same way; compose A children first then unmatched B children, preserving iteration order. Chain B moves through A moves, consume the matched A edges, omit B move from A field dst; append unconsumed A edges unless their source becomes the composed live source. If A attached a detached source and B effectively replaces it, append move from A source to B dst unless equal. Result replacement input emptiness is first replacement's isEmpty. Destination: if B has no replacement, forward A.dst through B.moves; otherwise use B.dst if no A.dst, A.src=self, or B.src=A.dst; else forward A.dst through B.moves. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalField.ts:161` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalField.ts:502`

### Invert

Reverse every detached move; build register forward map for child relocation (src→dst, self→effective dst, replacement src→self). Child payload IDs are preserved here because modular layer inverts node changes separately. For effective replace, inverse.isEmpty = original.src absent; inverse.dst = original.src only for rollback with present src, otherwise allocate fresh; inverse.src = original.dst only when original input nonempty. Non-effectful replace disappears for rollback; ordinary undo of src=self emits `{isEmpty:false,src:self,dst:fresh}`. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalField.ts:277`

### Rebase A over B; tie-break

Build B forward register map. For each A detached move `[src,dst]`, replace **dst** with B.moves[src] if defined; source stays src (do not simplify this unusual rule). Pair child changes by original register; rebase A child against B child, forwarding output register through B; attach-state is attached exactly at self. Also invoke child rebase for unmatched B children with absent A child; it may produce output. For A replacement keep dst; set isEmpty to B.src absent when B replaces, otherwise retain A.isEmpty; forward A.src through B. This means A's later-sequenced replacement takes the live field while competing B content remains tracked in a detached register. No UUID lexical comparator. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalField.ts:337`

Delta generation moves old live content to replacement dst, attaches replacement src when detached, and routes detached child modifications globally. Required fields use the same rules but editor never clears a live value. Exact algorithm below preserves edge cases and output order. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalField.ts:580` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/requiredField.ts:18`

### Algorithm notation and completeness

The following decision procedures are part of this specification, not external reading assignments. They preserve exact predicates, allocation order, collection traversal, return shapes and synchronous event calls. `undefined` means absent; `null` is a value; object spread is right-biased; `delete` removes a property; `Map`/`Set` iterate in insertion order. TypeBox `Optional(T)` permits absence, not null; tuples are fixed-order JSON arrays; singleton discriminated unions have exactly one case property. Assertions stop execution at the displayed short code. Helpers in another area use that area's same-named procedure; generic collection utilities retain JavaScript order. These are reference algorithms to translate into Swift, not a proposal to embed TypeScript in the client.

### Decision procedure: `feature-libraries/optional-field/optionalField.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalField.ts:1-844`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface IRegisterMap<T> {
	set(id: RegisterId, childChange: T): void;
	get(id: RegisterId): T | undefined;
	delete(id: RegisterId): boolean;
	keys(): Iterable<RegisterId>;
	values(): Iterable<T>;
	entries(): Iterable<[RegisterId, T]>;
	readonly size: number;
}
export class RegisterMap<T> implements IRegisterMap<T> {
	private readonly nestedMapData = new SizedNestedMap<
		ChangesetLocalId | "self",
		RevisionTag | undefined,
		T
	>();
	public clone(): RegisterMap<T> {
		const clone = new RegisterMap<T>();
		for (const [id, t] of this.entries()) {
			clone.set(id, t);
		}
		return clone;
	}
	public set(id: RegisterId, childChange: T): void {
		if (id === "self") {
			this.nestedMapData.set("self", undefined, childChange);
		} else {
			this.nestedMapData.set(id.localId, id.revision, childChange);
		}
	}
	public get(id: RegisterId): T | undefined {
		return id === "self"
			? this.nestedMapData.tryGet(id, undefined)
			: this.nestedMapData.tryGet(id.localId, id.revision);
	}
	public has(id: RegisterId): boolean {
		return this.get(id) !== undefined;
	}
	public delete(id: RegisterId): boolean {
		return id === "self"
			? this.nestedMapData.delete("self", undefined)
			: this.nestedMapData.delete(id.localId, id.revision);
	}
	public keys(): Iterable<RegisterId> {
		const changeIds: RegisterId[] = [];
		for (const [localId, nestedMap] of this.nestedMapData) {
			if (localId === "self") {
				changeIds.push("self");
			} else {
				for (const [revisionTag, _] of nestedMap) {
					changeIds.push(
						revisionTag === undefined ? { localId } : { localId, revision: revisionTag },
					);
				}
			}
		}
		return changeIds;
	}
	public values(): Iterable<T> {
		return this.nestedMapData.values();
	}
	public entries(): Iterable<[RegisterId, T]> {
		const entries: [RegisterId, T][] = [];
		for (const changeId of this.keys()) {
			if (changeId === "self") {
				const entry = this.nestedMapData.tryGet("self", undefined);
				assert(
					entry !== undefined,
					0x770  ,
				);
				entries.push(["self", entry]);
			} else {
				const entry = this.nestedMapData.tryGet(changeId.localId, changeId.revision);
				assert(
					entry !== undefined,
					0x771  ,
				);
				entries.push([changeId, entry]);
			}
		}
		return entries;
	}
	public get size(): number {
		return this.nestedMapData.size;
	}
}
export const optionalChangeRebaser: FieldChangeRebaser<OptionalChangeset> = {
	compose: (
		change1: OptionalChangeset,
		change2: OptionalChangeset,
		composeChild: NodeChangeComposer,
	): OptionalChangeset => {
		const { srcToDst, dstToSrc } = getBidirectionalMaps(change1.moves);
		const change1FieldSrc = change1.valueReplace?.src;
		const change1FieldDst = getEffectfulDst(change1.valueReplace);
		const change2FieldSrc = change2.valueReplace?.src;
		let composedFieldSrc: RegisterId | undefined;
		if (change2FieldSrc !== undefined) {
			if (change2FieldSrc === "self") {
				composedFieldSrc = change1FieldSrc ?? change2FieldSrc;
			} else if (
				change1FieldDst !== undefined &&
				areEqualRegisterIds(change1FieldDst, change2FieldSrc)
			) {
				composedFieldSrc = "self";
			} else {
				composedFieldSrc =
					tryGetFromNestedMap(dstToSrc, change2FieldSrc.revision, change2FieldSrc.localId) ??
					change2FieldSrc;
			}
		} else if (change1FieldSrc !== undefined && change2.valueReplace === undefined) {
			composedFieldSrc = change1FieldSrc;
		}
		const childChanges2ByOriginalId = new RegisterMap<NodeId>();
		for (const [id, change] of change2.childChanges) {
			if (id === "self") {
				if (change1FieldSrc === undefined) {
					childChanges2ByOriginalId.set("self", change);
				} else {
					childChanges2ByOriginalId.set(change1FieldSrc, change);
				}
			} else {
				if (change1FieldDst !== undefined && areEqualChangeAtomIds(change1FieldDst, id)) {
					childChanges2ByOriginalId.set("self", change);
				} else {
					const originalId = tryGetFromNestedMap(dstToSrc, id.revision, id.localId);
					childChanges2ByOriginalId.set(originalId ?? id, change);
				}
			}
		}
		const composedMoves: Move[] = [];
		const composedChildChanges: ChildChange[] = [];
		const composed: Mutable<OptionalChangeset> = {
			moves: composedMoves,
			childChanges: composedChildChanges,
		};
		for (const [id, childChange1] of change1.childChanges) {
			const childChange2 = childChanges2ByOriginalId.get(id);
			composedChildChanges.push([id, composeChild(childChange1, childChange2)]);
			childChanges2ByOriginalId.delete(id);
		}
		for (const [id, childChange2] of childChanges2ByOriginalId.entries()) {
			composedChildChanges.push([id, composeChild(undefined, childChange2)]);
		}
		for (const [leg2Src, leg2Dst] of change2.moves) {
			const leg1Src = tryGetFromNestedMap(dstToSrc, leg2Src.revision, leg2Src.localId);
			if (leg1Src !== undefined) {
				composedMoves.push([leg1Src, leg2Dst]);
				deleteFromNestedMap(srcToDst, leg1Src.revision, leg1Src.localId);
				deleteFromNestedMap(dstToSrc, leg2Src.revision, leg2Src.localId);
			} else if (
				change1FieldDst === undefined ||
				!areEqualChangeAtomIds(change1FieldDst, leg2Src)
			) {
				composedMoves.push([leg2Src, leg2Dst]);
			}
		}
		for (const [revision, innerMap] of srcToDst.entries()) {
			for (const [localId, dst] of innerMap.entries()) {
				const src = makeChangeAtomId(localId, revision);
				if (composedFieldSrc === undefined || !areEqualRegisterIds(src, composedFieldSrc)) {
					composedMoves.push([src, dst]);
				}
			}
		}
		if (
			change1FieldSrc !== undefined &&
			change1FieldSrc !== "self" &&
			change2.valueReplace !== undefined
		) {
			const change2FieldDst = change2.valueReplace.dst;
			if (
				isReplaceEffectful(change2.valueReplace) &&
				!areEqualChangeAtomIds(change1FieldSrc, change2FieldDst)
			) {
				composedMoves.push([change1FieldSrc, change2FieldDst]);
			}
		}
		const firstChange = change1.valueReplace ?? change2.valueReplace;
		if (firstChange === undefined) {
			return composed;
		}
		const replace: Mutable<Replace> = {
			isEmpty: firstChange.isEmpty,
			dst: getComposedReplaceDst(change1.valueReplace, change2),
		};
		if (composedFieldSrc !== undefined) {
			replace.src = composedFieldSrc;
		}
		composed.valueReplace = replace;
		return composed;
	},
	invert: (
		change: OptionalChangeset,
		isRollback: boolean,
		genId: IdAllocator<ChangesetLocalId>,
		revision: RevisionTag | undefined,
	): OptionalChangeset => {
		const { moves, childChanges, valueReplace } = change;
		const invertIdMap = new RegisterMap<RegisterId>();
		const invertedMoves: Move[] = [];
		for (const [src, dst] of moves) {
			invertIdMap.set(src, dst);
			invertedMoves.push([dst, src]);
		}
		if (valueReplace !== undefined) {
			const effectfulDst = getEffectfulDst(valueReplace);
			if (effectfulDst !== undefined) {
				invertIdMap.set("self", valueReplace.dst);
			}
			if (valueReplace.src !== undefined) {
				invertIdMap.set(valueReplace.src, "self");
			}
		}
		const inverted: Mutable<OptionalChangeset> = {
			moves: invertedMoves,
			childChanges: childChanges.map(([id, childChange]) => {
				return [invertIdMap.get(id) ?? id, childChange];
			}),
		};
		if (valueReplace !== undefined) {
			if (isReplaceEffectful(valueReplace)) {
				const replace: Mutable<Replace> =
					valueReplace.src === undefined
						? {
								isEmpty: true,
								dst: makeChangeAtomId(genId.allocate(), revision),
							}
						: {
								isEmpty: false,
								dst: isRollback
									? valueReplace.src
									: makeChangeAtomId(genId.allocate(), revision),
							};
				if (valueReplace.isEmpty === false) {
					replace.src = valueReplace.dst;
				}
				inverted.valueReplace = replace;
			} else if (!isRollback && valueReplace.src === "self") {
				inverted.valueReplace = {
					isEmpty: false,
					src: "self",
					dst: makeChangeAtomId(genId.allocate(), revision),
				};
			}
		}
		return inverted;
	},
	rebase: (
		change: OptionalChangeset,
		overChange: OptionalChangeset,
		rebaseChild: NodeChangeRebaser,
	): OptionalChangeset => {
		const { moves, childChanges, valueReplace: field } = change;
		const { srcToDst: overSrcToDst } = getBidirectionalMaps(overChange.moves);
		const forwardMap = new RegisterMap<RegisterId>();
		for (const [src, dst] of overChange.moves) {
			forwardMap.set(src, dst);
		}
		if (overChange.valueReplace !== undefined) {
			const effectfulDst = getEffectfulDst(overChange.valueReplace);
			if (effectfulDst !== undefined) {
				forwardMap.set("self", overChange.valueReplace.dst);
			}
			if (overChange.valueReplace.src !== undefined) {
				forwardMap.set(overChange.valueReplace.src, "self");
			}
		}
		const rebasedMoves: Move[] = [];
		for (const [src, dst] of moves) {
			const newDst = tryGetFromNestedMap(overSrcToDst, src.revision, src.localId);
			rebasedMoves.push([src, newDst ?? dst]);
		}
		const overChildChangesBySrc = new RegisterMap<NodeId>();
		for (const [id, childChange] of overChange.childChanges) {
			overChildChangesBySrc.set(id, childChange);
		}
		const rebasedChildChanges: ChildChange[] = [];
		for (const [id, childChange] of childChanges) {
			const overChildChange = overChildChangesBySrc.get(id);
			if (overChildChange !== undefined) {
				overChildChangesBySrc.delete(id);
			}
			const rebasedId = forwardMap.get(id) ?? id;
			const rebasedChildChange = rebaseChild(
				childChange,
				overChildChange,
				rebasedId === "self" ? NodeAttachState.Attached : NodeAttachState.Detached,
			);
			if (rebasedChildChange !== undefined) {
				rebasedChildChanges.push([rebasedId, rebasedChildChange]);
			}
		}
		for (const [id, overChildChange] of overChildChangesBySrc.entries()) {
			const rebasedId = forwardMap.get(id) ?? id;
			const rebasedChildChange = rebaseChild(
				undefined,
				overChildChange,
				rebasedId === "self" ? NodeAttachState.Attached : NodeAttachState.Detached,
			);
			if (rebasedChildChange !== undefined) {
				rebasedChildChanges.push([rebasedId, rebasedChildChange]);
			}
		}
		const rebased: Mutable<OptionalChangeset> = {
			moves: rebasedMoves,
			childChanges: rebasedChildChanges,
		};
		if (field !== undefined) {
			const replace: Mutable<Replace> = {
				isEmpty:
					overChange.valueReplace === undefined
						? field.isEmpty
						: overChange.valueReplace.src === undefined,
				dst: field.dst,
			};
			if (field.src !== undefined) {
				replace.src = forwardMap.get(field.src) ?? field.src;
			}
			rebased.valueReplace = replace;
		}
		return rebased;
	},
	prune: (change: OptionalChangeset, pruneChild: NodeChangePruner): OptionalChangeset => {
		const childChanges: ChildChange[] = [];
		const prunedChange: Mutable<OptionalChangeset> = {
			moves: change.moves,
			childChanges,
		};
		if (change.valueReplace !== undefined) {
			prunedChange.valueReplace = change.valueReplace;
		}
		for (const [id, childChange] of change.childChanges) {
			const prunedChildChange = pruneChild(childChange);
			if (prunedChildChange !== undefined) {
				childChanges.push([id, prunedChildChange]);
			}
		}
		return prunedChange;
	},
	replaceRevisions: (
		change: OptionalChangeset,
		replacer: RevisionReplacer,
	): OptionalChangeset => {
		const valueReplace = replaceReplaceRevisions(change.valueReplace, replacer);
		const childChanges: ChildChange[] = [];
		for (const [id, childChange] of change.childChanges) {
			childChanges.push([
				replaceRegisterRevisions(id, replacer),
				replacer.getUpdatedAtomId(childChange),
			]);
		}
		const moves: Move[] = [];
		for (const [src, dst] of change.moves) {
			moves.push([replacer.getUpdatedAtomId(src), replacer.getUpdatedAtomId(dst)]);
		}
		const updated: Mutable<OptionalChangeset> = { childChanges, moves };
		if (valueReplace !== undefined) {
			updated.valueReplace = valueReplace;
		}
		return updated;
	},
	filterEdits,
};
function replaceReplaceRevisions(
	replace: Replace | undefined,
	replacer: RevisionReplacer,
): Replace | undefined {
	if (replace === undefined) {
		return undefined;
	}
	const updated: Mutable<Replace> = {
		...replace,
		dst: replacer.getUpdatedAtomId(replace.dst),
	};
	if (replace.src !== undefined) {
		updated.src = replaceRegisterRevisions(replace.src, replacer);
	}
	return updated;
}
function replaceRegisterRevisions(
	register: RegisterId,
	replacer: RevisionReplacer,
): RegisterId {
	return register === "self" ? register : replacer.getUpdatedAtomId(register);
}
function getComposedReplaceDst(
	change1: Replace | undefined,
	change2: OptionalChangeset,
): ChangeAtomId {
	const dst1 = change1?.dst;
	if (change2.valueReplace === undefined) {
		assert(dst1 !== undefined, 0x8ce  );
		return getIdAfterMoves(dst1, change2.moves);
	}
	if (
		dst1 === undefined ||
		change1?.src === "self" ||
		(change2.valueReplace.src !== undefined &&
			areEqualRegisterIds(change2.valueReplace.src, dst1))
	) {
		assert(
			change2.valueReplace !== undefined,
			0x8cf  ,
		);
		return change2.valueReplace.dst;
	} else {
		return getIdAfterMoves(dst1, change2.moves);
	}
}
function getIdAfterMoves(id: ChangeAtomId, moves: readonly Move[]): ChangeAtomId {
	for (const [src, dst] of moves) {
		if (areEqualChangeAtomIds(id, src)) {
			return dst;
		}
	}
	return id;
}
function areEqualRegisterIds(id1: RegisterId, id2: RegisterId): boolean {
	return id1 === "self" || id2 === "self" ? id1 === id2 : areEqualChangeAtomIds(id1, id2);
}
function getBidirectionalMaps(moves: OptionalChangeset["moves"]): {
	srcToDst: ChangeAtomIdMap<ChangeAtomId>;
	dstToSrc: ChangeAtomIdMap<ChangeAtomId>;
} {
	const srcToDst: ChangeAtomIdMap<ChangeAtomId> = new Map();
	const dstToSrc: ChangeAtomIdMap<ChangeAtomId> = new Map();
	for (const [src, dst] of moves) {
		setInNestedMap(srcToDst, src.revision, src.localId, dst);
		setInNestedMap(dstToSrc, dst.revision, dst.localId, src);
	}
	return { srcToDst, dstToSrc };
}
type EffectfulReplace =
	| {
			isEmpty: true;
			src?: ChangeAtomId;
			dst: ChangeAtomId;
	  }
	| {
			isEmpty: boolean;
			src: ChangeAtomId;
			dst: ChangeAtomId;
	  };
function isReplaceEffectful(replace: Replace): replace is EffectfulReplace {
	if (replace.src === "self") {
		return false;
	}
	return !replace.isEmpty || replace.src !== undefined;
}
function getEffectfulDst(replace: Replace | undefined): ChangeAtomId | undefined {
	return replace === undefined || replace.isEmpty || replace.src === "self"
		? undefined
		: replace.dst;
}
export function taggedRegister(id: RegisterId, revision: RevisionTag | undefined): RegisterId {
	if (id === "self") {
		return id;
	}
	return taggedAtomId(id, revision);
}
export interface OptionalFieldEditor extends FieldEditor<OptionalChangeset> {
	set(
		wasEmpty: boolean,
		ids: {
			fill: ChangeAtomId;
			detach: ChangeAtomId;
		},
	): OptionalChangeset;
	clear(wasEmpty: boolean, detachId: ChangeAtomId): OptionalChangeset;
}
export const optionalFieldEditor: OptionalFieldEditor = {
	set: (
		wasEmpty: boolean,
		ids: {
			fill: ChangeAtomId;
			detach: ChangeAtomId;
		},
	): OptionalChangeset => ({
		moves: [],
		childChanges: [],
		valueReplace: {
			isEmpty: wasEmpty,
			src: ids.fill,
			dst: ids.detach,
		},
	}),
	clear: (wasEmpty: boolean, detachId: ChangeAtomId): OptionalChangeset => ({
		moves: [],
		childChanges: [],
		valueReplace: {
			isEmpty: wasEmpty,
			dst: detachId,
		},
	}),
	buildChildChanges: (changes: Iterable<[number, NodeId]>): OptionalChangeset => {
		const childChanges: ChildChange[] = Array.from(changes, ([index, childChange]) => {
			assert(index === 0, 0x404  );
			return ["self", childChange];
		});
		assert(
			childChanges.length <= 1,
			0xabd  ,
		);
		return {
			moves: [],
			childChanges,
		};
	},
};
export function optionalFieldIntoDelta(
	change: OptionalChangeset,
	deltaFromChild: ToDelta,
): FieldChangeDelta {
	const delta: Mutable<FieldChangeDelta> = {};
	let markIsANoop = true;
	const mark: Mutable<DeltaMark> = { count: 1 };
	if (change.valueReplace !== undefined && isReplaceEffectful(change.valueReplace)) {
		if (!change.valueReplace.isEmpty) {
			mark.detach = nodeIdFromChangeAtom(change.valueReplace.dst);
		}
		if (change.valueReplace.src !== undefined) {
			mark.attach = nodeIdFromChangeAtom(change.valueReplace.src);
		}
		markIsANoop = false;
	}
	if (change.moves.length > 0) {
		delta.rename = change.moves.map(([src, dst]) => ({
			count: 1,
			oldId: nodeIdFromChangeAtom(src),
			newId: nodeIdFromChangeAtom(dst),
		}));
	}
	if (change.childChanges.length > 0) {
		const globals: DeltaDetachedNodeChanges[] = [];
		for (const [id, childChange] of change.childChanges) {
			const childDelta = deltaFromChild(childChange);
			if (id === "self") {
				mark.fields = childDelta;
				markIsANoop = false;
			} else {
				const fields = childDelta;
				globals.push({
					id: { major: id.revision, minor: id.localId },
					fields,
				});
			}
		}
		if (globals.length > 0) {
			delta.global = globals;
		}
	}
	if (!markIsANoop) {
		delta.local = { marks: [mark] };
	}
	return delta;
}
export const optionalChangeHandler: FieldChangeHandler<
	OptionalChangeset,
	OptionalFieldEditor
> = {
	rebaser: optionalChangeRebaser,
	codecsFactory: makeOptionalFieldCodecFamily,
	editor: optionalFieldEditor,
	intoDelta: optionalFieldIntoDelta,
	relevantRemovedRoots,
	isEmpty: (change: OptionalChangeset) =>
		change.childChanges.length === 0 &&
		change.moves.length === 0 &&
		change.valueReplace === undefined,
	getNestedChanges,
	createEmpty: () => ({ moves: [], childChanges: [] }),
	getCrossFieldKeys: (_change) => [],
};
function getNestedChanges(change: OptionalChangeset): ChildChangeInfo[] {
	const detachId = change.valueReplace?.dst;
	return change.childChanges.map(([register, nodeId]) => {
		const inputDetachId = register === "self" ? undefined : register;
		return {
			nodeId,
			inputRootId: inputDetachId,
			detachId: register === "self" ? detachId : undefined,
		};
	});
}
function* relevantRemovedRoots(
	change: OptionalChangeset,
	relevantRemovedRootsFromChild: RelevantRemovedRootsFromChild,
): Iterable<DeltaDetachedNodeId> {
	const alreadyYielded = new RegisterMap<boolean>();
	for (const [src] of change.moves) {
		if (!alreadyYielded.has(src)) {
			alreadyYielded.set(src, true);
			yield nodeIdFromChangeAtom(src);
		}
	}
	for (const [id, childChange] of change.childChanges) {
		if (id !== "self" && !alreadyYielded.has(id)) {
			alreadyYielded.set(id, true);
			yield nodeIdFromChangeAtom(id);
		}
		yield* relevantRemovedRootsFromChild(childChange);
	}
	const selfSrc = change.valueReplace?.src;
	if (selfSrc !== undefined && selfSrc !== "self" && !alreadyYielded.has(selfSrc)) {
		yield nodeIdFromChangeAtom(selfSrc);
	}
}
interface Optional
	extends FlexFieldKind<
		OptionalFieldEditor,
		typeof optionalIdentifier,
		Multiplicity.Optional
	> {}
export const optional: Optional = new FlexFieldKind(
	optionalIdentifier,
	Multiplicity.Optional,
	{
		changeHandler: optionalChangeHandler,
		allowMonotonicUpgradeFrom: new Set([
			identifierFieldIdentifier,
			requiredIdentifier,
			forbiddenFieldKindIdentifier,
		]),
	},
);
function filterEdits(
	change: OptionalChangeset,
	options: {
		filterDetach: FilterDetachFunc;
		filterAttach: FilterAttachFunc;
		preserveOtherEdits: boolean;
	},
): OptionalChangeset {
	const filtered: Mutable<OptionalChangeset> = { ...change };
	if (change.valueReplace !== undefined) {
		if (isReplaceEffectful(change.valueReplace)) {
			const detachId = getEffectfulDst(change.valueReplace);
			const detachResult =
				detachId === undefined
					? undefined
					: options.filterDetach(detachId, 1, undefined).value;
			const attachId = change.valueReplace.src;
			const attachResult =
				attachId === undefined
					? undefined
					: options.filterAttach(attachId, 1, undefined).value.action;
			if (detachResult?.action === EditFilterStatus.Remove) {
				assert(
					attachId === undefined || attachResult === EditFilterStatus.Remove,
					0xd0e  ,
				);
				delete filtered.valueReplace;
				if (detachResult.shouldRemoveChild === true) {
					filtered.childChanges = filtered.childChanges.filter(([id]) => id !== "self");
				}
			} else if (attachResult === EditFilterStatus.Remove) {
				filtered.valueReplace = { ...change.valueReplace };
				delete (filtered.valueReplace as Mutable<Replace>).src;
			}
		} else if (!options.preserveOtherEdits) {
			delete filtered.valueReplace;
		}
	}
	if (!options.preserveOtherEdits) {
		filtered.moves = [];
	}
	return filtered;
}
```

### Decision procedure: `feature-libraries/optional-field/optionalFieldChangeTypes.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalFieldChangeTypes.ts:1-69`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type RegisterId = ChangeAtomId | "self";
export type Move = readonly [src: ChangeAtomId, dst: ChangeAtomId];
export type ChildChange = readonly [register: RegisterId, childChange: NodeId];
export interface OptionalChangeset {
	readonly moves: readonly Move[];
	readonly childChanges: readonly ChildChange[];
	readonly valueReplace?: Replace;
}
export interface Replace {
	readonly isEmpty: boolean;
	readonly src?: RegisterId;
	readonly dst: ChangeAtomId;
}
```

### Decision procedure: `feature-libraries/optional-field/requiredField.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/requiredField.ts:1-60`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface RequiredFieldEditor extends FieldEditor<OptionalChangeset> {
	set(ids: { fill: ChangeAtomId; detach: ChangeAtomId }): OptionalChangeset;
}
export const requiredFieldEditor: RequiredFieldEditor = {
	...optionalFieldEditor,
	set: (ids: { fill: ChangeAtomId; detach: ChangeAtomId }): OptionalChangeset =>
		optionalFieldEditor.set(false, ids),
};
export const requiredFieldChangeHandler: FieldChangeHandler<
	OptionalChangeset,
	RequiredFieldEditor
> = {
	...optionalChangeHandler,
	editor: requiredFieldEditor,
};
interface Required
	extends FlexFieldKind<RequiredFieldEditor, typeof requiredIdentifier, Multiplicity.Single> {}
export const required: Required = new FlexFieldKind(requiredIdentifier, Multiplicity.Single, {
	changeHandler: requiredFieldChangeHandler,
	allowMonotonicUpgradeFrom: new Set([identifierFieldIdentifier]),
});
```

## 5. Invariants and asserts

Register-map iteration requires every key to resolve (0x770/0x771). Compose replacement destination must exist (0x8ce/0x8cf). Register equality is self identity or both atom components, never just localId. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalField.ts:133` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalField.ts:502`

## 6. JS-semantics hazards

Do not model register with a single Swift Optional: wire omitted vs null vs atom are three cases. RegisterMap nesting is localId then revision, whereas other atom maps often nest revision then localId; output iteration must match the actual structure. Child payload ID references are not in-place edits in this layer. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalField.ts:75` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/optionalFieldCodecV2.ts:35`

## 7. Test assets to reuse

Reuse optional-field rebaser/codec snapshots, required-field cases and modular child-change integration tests. Exact files are under `src/test/feature-libraries/optional-field`; snapshot output `src/test/snapshots/output/optional-field`. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/feature-libraries/optional-field/optionalField.spec.ts:1`

## 8. Open questions

None. The extracted decision procedure in section 4 is normative where a prose simplification would lose register routing.

