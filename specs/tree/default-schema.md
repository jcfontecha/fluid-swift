# Default Schema — Fluid Framework 3.11.0

## 1. Role

Default-schema installs the field-kind policy and edit builder used by SharedTree's modular family. It connects required/optional/sequence algorithms to stable field-kind identifiers and codec versions. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/defaultFieldKinds.ts:107`

## 2. Surface used by other packages

`FieldKinds`, `fieldKinds`, `fieldKindConfigurations`, `defaultSchemaPolicy`, default/mapped edit builders, noChangeHandler, codec tree helpers. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/index.ts:6`

## 3. Wire and persisted formats

No standalone wire envelope. Field kinds use exact identifiers defined in fieldKindIdentifiers (do not substitute Swift type names). Modular 3: required2, optional2, sequence2, forbidden1, identifier1. Modular 4/5: required2, optional2, sequence3, forbidden1, identifier1. No-change codec is literal zero. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/fieldKindIdentifiers.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/defaultFieldKinds.ts:107` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/noChangeCodecs.ts:6`


### Decision procedure: `feature-libraries/default-schema/noChangeCodecs.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/noChangeCodecs.ts:1-18`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const noChangeCodecFamily: ICodecFamily<
	0,
	FieldChangeEncodingContext,
	FieldChangeDecodingContext
> = makeCodecFamily<0, FieldChangeEncodingContext, FieldChangeDecodingContext>([
	[1, unitCodec],
]);
```

### Literal kind and identity payloads

The stored strings are required=`"Value"`, optional=`"Optional"`, sequence=`"Sequence"`, identifier=`"Identifier"`, forbidden=`"Forbidden"`; Generic's internal kind is `"ModularEditBuilder.Generic"`. Identifier and forbidden encode the JSON number `0`, not `{}`, null or an empty changes array. Generic v1 uses tuple arrays (specified in modular-schema), optional/required v2 use register objects, and sequence v2/v3 use mark arrays. There is no independent default-schema wire envelope or reader negotiation. The unit decoder returns 0 for any received JSON, even though the writer always emits 0; do not add a decoder-only rejection for nonzero payloads. `reference/fluidframework-3.11.0/packages/dds/tree/src/codec/codec.ts:453-462` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/fieldKindIdentifiers.ts:14-16` `reference/fluidframework-3.11.0/packages/dds/tree/src/core/schema-stored/schema.ts:172-184` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/noChangeCodecs.ts:6-18`

## 4. Behavior

Required and optional route to register algebra; sequence routes to sequence algebra. Identifier is Single and forbidden is Forbidden, both no-change: compose/invert/rebase/filter return 0; delta empty; removed-root/nested/cross-field lists empty; build child changes fails. Identifier permits no monotonic upgrades FROM other kinds, while required policy allows upgrading identifier into required; upgrade direction is intentionally asymmetric. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/defaultFieldKinds.ts:36` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/optional-field/requiredField.ts:18`

Edit builders allocate atom IDs and detached builds before submitting field changes, keep moves' source/destination IDs coupled, and group compound changes through the modular builder rather than emitting unrelated operations. Use the extracted builder procedures below for empty-range and move index handling. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/defaultEditBuilder.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/mappedEditBuilder.ts:6`

### Algorithm notation and completeness

The following decision procedures are part of this specification, not external reading assignments. They preserve exact predicates, allocation order, collection traversal, return shapes and synchronous event calls. `undefined` means absent; `null` is a value; object spread is right-biased; `delete` removes a property; `Map`/`Set` iterate in insertion order. TypeBox `Optional(T)` permits absence, not null; tuples are fixed-order JSON arrays; singleton discriminated unions have exactly one case property. Assertions stop execution at the displayed short code. Helpers in another area use that area's same-named procedure; generic collection utilities retain JavaScript order. These are reference algorithms to translate into Swift, not a proposal to embed TypeScript in the client.

### Decision procedure: `feature-libraries/default-schema/defaultEditBuilder.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/defaultEditBuilder.ts:1-547`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export type DefaultChangeset = ModularChangeset;
export type DefaultChangeProcessingContext = ModularChangeFamily;
export class DefaultChangeFamily
	implements ChangeFamily<DefaultEditBuilder, DefaultChangeset, DefaultChangeProcessingContext>
{
	private readonly modularFamily: ModularChangeFamily;
	public constructor(
		codecs: ICodecFamily<ModularChangeset, ChangeEncodingContext, ChangeDecodingContext>,
		codecOptions: CodecWriteOptions,
	) {
		this.modularFamily = new ModularChangeFamily(fieldKinds, codecs, codecOptions);
		this.validator = this.modularFamily.validator;
	}
	public readonly validator: (change: DefaultChangeset) => true | string;
	public get rebaser(): ChangeRebaser<DefaultChangeset> {
		return this.modularFamily.rebaser;
	}
	public get codecs(): ICodecFamily<
		DefaultChangeset,
		ChangeEncodingContext,
		ChangeDecodingContext
	> {
		return this.modularFamily.codecs;
	}
	public buildEditor(
		mintRevisionTag: () => RevisionTag,
		changeReceiver: (change: TaggedChange<DefaultChangeset>) => void,
	): DefaultEditBuilder {
		return new DefaultEditBuilder(
			this.modularFamily.rebaser,
			mintRevisionTag,
			changeReceiver,
			this.modularFamily.codecOptions,
		);
	}
	public hasSchemaChange(change: DefaultChangeset): boolean {
		return this.modularFamily.hasSchemaChange(change);
	}
	public buildProcessor(
		processFn: ProcessChangeFn<DefaultChangeset, DefaultChangeProcessingContext>,
	): (change: DefaultChangeset) => DefaultChangeset {
		return this.modularFamily.buildProcessor(processFn);
	}
}
export function intoDelta(taggedChange: TaggedChange<ModularChangeset>): DeltaRoot {
	return intoModularDelta(taggedChange, fieldKinds);
}
export function relevantRemovedRoots(change: ModularChangeset): Iterable<DeltaDetachedNodeId> {
	return relevantModularRemovedRoots(change, fieldKinds);
}
export interface IDefaultEditBuilder<TContent = TreeChunk> {
	valueField(field: NormalizedFieldUpPath): ValueFieldEditBuilder<TContent>;
	optionalField(field: NormalizedFieldUpPath): OptionalFieldEditBuilder<TContent>;
	sequenceField(field: NormalizedFieldUpPath): SequenceFieldEditBuilder<TContent>;
	move(
		sourceField: NormalizedFieldUpPath,
		sourceIndex: number,
		count: number,
		destinationField: NormalizedFieldUpPath,
		destinationIndex: number,
	): void;
	addNodeExistsConstraint(path: NormalizedUpPath): void;
	addNodeExistsConstraintOnRevert(path: NormalizedUpPath): void;
	addNoChangeConstraint(): void;
	addNoChangeConstraintOnRevert(): void;
}
export class DefaultEditBuilder implements ChangeFamilyEditor, IDefaultEditBuilder {
	private readonly modularBuilder: ModularEditBuilder;
	public constructor(
		rebaser: ChangeRebaser<DefaultChangeset>,
		private readonly mintRevisionTag: () => RevisionTag,
		changeReceiver: (change: TaggedChange<DefaultChangeset>) => void,
		codecOptions: CodecWriteOptions,
	) {
		this.modularBuilder = new ModularEditBuilder(
			rebaser,
			fieldKinds,
			changeReceiver,
			codecOptions,
		);
	}
	public enterTransaction(): void {
		this.modularBuilder.enterTransaction();
	}
	public exitTransaction(): void {
		this.modularBuilder.exitTransaction();
	}
	public addNodeExistsConstraint(path: UpPath): void {
		this.modularBuilder.addNodeExistsConstraint(path, this.mintRevisionTag());
	}
	public addNodeExistsConstraintOnRevert(path: UpPath): void {
		this.modularBuilder.addNodeExistsConstraintOnRevert(path, this.mintRevisionTag());
	}
	public addNoChangeConstraint(): void {
		this.modularBuilder.addNoChangeConstraint(this.mintRevisionTag());
	}
	public addNoChangeConstraintOnRevert(): void {
		this.modularBuilder.addNoChangeConstraintOnRevert(this.mintRevisionTag());
	}
	public valueField(field: FieldUpPath): ValueFieldEditBuilder<TreeChunk> {
		return {
			set: (newContent: TreeChunk): void => {
				assert(
					newContent.topLevelLength === 1,
					0xc12  ,
				);
				const revision = this.mintRevisionTag();
				const fill: ChangeAtomId = { localId: this.modularBuilder.generateId(), revision };
				const detach: ChangeAtomId = { localId: this.modularBuilder.generateId(), revision };
				const build = this.modularBuilder.buildTrees(fill.localId, newContent, revision);
				const change: FieldChangeset = brand(
					required.changeHandler.editor.set({
						fill,
						detach,
					}),
				);
				const edit: FieldEditDescription = {
					type: "field",
					field,
					fieldKind: required.identifier,
					change,
					revision,
				};
				this.modularBuilder.submitChanges([build, edit], revision);
			},
		};
	}
	public optionalField(field: FieldUpPath): OptionalFieldEditBuilder<TreeChunk> {
		return {
			set: (newContent: TreeChunk | undefined, wasEmpty: boolean): void => {
				assert(
					newContent === undefined || newContent.topLevelLength === 1,
					0xc13  ,
				);
				const edits: EditDescription[] = [];
				let optionalChange: OptionalChangeset;
				const revision = this.mintRevisionTag();
				const detach: ChangeAtomId = { localId: this.modularBuilder.generateId(), revision };
				if (newContent === undefined) {
					optionalChange = optional.changeHandler.editor.clear(wasEmpty, detach);
				} else {
					const fill: ChangeAtomId = { localId: this.modularBuilder.generateId(), revision };
					const build = this.modularBuilder.buildTrees(fill.localId, newContent, revision);
					edits.push(build);
					optionalChange = optional.changeHandler.editor.set(wasEmpty, {
						fill,
						detach,
					});
				}
				const change: FieldChangeset = brand(optionalChange);
				const edit: FieldEditDescription = {
					type: "field",
					field,
					fieldKind: optional.identifier,
					change,
					revision,
				};
				edits.push(edit);
				this.modularBuilder.submitChanges(edits, revision);
			},
		};
	}
	public move(
		sourceField: FieldUpPath,
		sourceIndex: number,
		count: number,
		destinationField: FieldUpPath,
		destIndex: number,
	): void {
		if (count === 0) {
			return;
		} else if (count < 0 || !Number.isSafeInteger(count)) {
			throw new UsageError(`Expected non-negative integer count, got ${count}.`);
		}
		const revision = this.mintRevisionTag();
		const detachCellId = this.modularBuilder.generateId(count);
		const attachCellId: CellId = { localId: this.modularBuilder.generateId(count), revision };
		if (compareFieldUpPaths(sourceField, destinationField)) {
			const change = sequence.changeHandler.editor.move(
				sourceIndex,
				count,
				destIndex,
				detachCellId,
				attachCellId,
				revision,
			);
			this.modularBuilder.submitChange(
				sourceField,
				sequence.identifier,
				brand(change),
				revision,
			);
		} else {
			const detachPath = topDownPath(sourceField.parent);
			const attachPath = topDownPath(destinationField.parent);
			const sharedDepth = getSharedPrefixLength(detachPath, attachPath);
			let adjustedAttachField = destinationField;
			if (sharedDepth === detachPath.length) {
				const fieldOnDetachPathUnderLCA = sourceField.field;
				const firstDifferentAttachAncestor = attachPath[sharedDepth];
				if (fieldOnDetachPathUnderLCA === firstDifferentAttachAncestor?.parentField) {
					if (firstDifferentAttachAncestor.parentIndex < sourceIndex) {
					} else if (sourceIndex + count <= firstDifferentAttachAncestor.parentIndex) {
						let parent = firstDifferentAttachAncestor.parent;
						parent = {
							parent,
							parentIndex: firstDifferentAttachAncestor.parentIndex - count,
							parentField: firstDifferentAttachAncestor.parentField,
						};
						for (let i = sharedDepth + 1; i < attachPath.length; i += 1) {
							parent = {
								...(attachPath[i] ?? oob()),
								parent,
							};
						}
						adjustedAttachField = { parent, field: destinationField.field };
					} else {
						throw new UsageError(
							"Invalid move operation: the destination is located under one of the moved elements. Consider using the Tree.contains API to detect this.",
						);
					}
				}
			}
			const moveOut = sequence.changeHandler.editor.moveOut(
				sourceIndex,
				count,
				detachCellId,
				revision,
			);
			const moveIn = sequence.changeHandler.editor.moveIn(
				destIndex,
				count,
				detachCellId,
				attachCellId,
				revision,
			);
			this.modularBuilder.submitChanges(
				[
					{
						type: "field",
						field: sourceField,
						fieldKind: sequence.identifier,
						change: brand(moveOut),
						revision,
					},
					{
						type: "field",
						field: adjustedAttachField,
						fieldKind: sequence.identifier,
						change: brand(moveIn),
						revision,
					},
				],
				revision,
			);
		}
	}
	public sequenceField(field: FieldUpPath): SequenceFieldEditBuilder<TreeChunk> {
		return {
			insert: (index: number, content: TreeChunk): void => {
				const length = content.topLevelLength;
				if (length === 0) {
					return;
				}
				const revision = this.mintRevisionTag();
				const firstId: CellId = { localId: this.modularBuilder.generateId(length), revision };
				const build = this.modularBuilder.buildTrees(firstId.localId, content, revision);
				const change: FieldChangeset = brand(
					sequence.changeHandler.editor.insert(index, length, firstId, revision),
				);
				const attach: FieldEditDescription = {
					type: "field",
					field,
					fieldKind: sequence.identifier,
					change,
					revision,
				};
				this.modularBuilder.submitChanges([build, attach], revision);
			},
			remove: (index: number, count: number): void => {
				if (count === 0) {
					return;
				}
				const revision = this.mintRevisionTag();
				const id = this.modularBuilder.generateId(count);
				const change: FieldChangeset = brand(
					sequence.changeHandler.editor.remove(index, count, id, revision),
				);
				this.modularBuilder.submitChange(field, sequence.identifier, change, revision);
			},
		};
	}
}
export interface ValueFieldEditBuilder<TContent> {
	set(newContent: TContent): void;
}
export interface OptionalFieldEditBuilder<TContent> {
	set(newContent: TContent | undefined, wasEmpty: boolean): void;
}
export interface SequenceFieldEditBuilder<TContent, TRemoved = void> {
	insert(index: number, newContent: TContent): void;
	remove(index: number, count: number): TRemoved;
}
function getSharedPrefixLength(pathA: readonly UpPath[], pathB: readonly UpPath[]): number {
	const minDepth = Math.min(pathA.length, pathB.length);
	let sharedDepth = 0;
	while (sharedDepth < minDepth) {
		const detachStep = pathA[sharedDepth] ?? oob();
		const attachStep = pathB[sharedDepth] ?? oob();
		if (
			detachStep !== attachStep &&
			(detachStep.parentField !== attachStep.parentField ||
				detachStep.parentIndex !== attachStep.parentIndex)
		) {
			break;
		}
		sharedDepth += 1;
	}
	return sharedDepth;
}
```

### Decision procedure: `feature-libraries/default-schema/defaultFieldKinds.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/defaultFieldKinds.ts:1-207`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const noChangeHandler: FieldChangeHandler<0> = {
	rebaser: referenceFreeFieldChangeRebaser({
		compose: (change1: 0, change2: 0) => 0,
		invert: (changes: 0) => 0,
		rebase: (change: 0, over: 0) => 0,
		filterEdits: (changes: 0) => 0,
	}),
	codecsFactory: () => noChangeCodecFamily,
	editor: { buildChildChanges: () => fail(0xb0d  ) },
	intoDelta: (change, deltaFromChild: ToDelta): FieldChangeDelta => ({}),
	relevantRemovedRoots: (change): Iterable<DeltaDetachedNodeId> => [],
	isEmpty: (change: 0) => true,
	getNestedChanges: (change: 0) => [],
	createEmpty: () => 0,
	getCrossFieldKeys: () => [],
};
export const identifier: Identifier = new FlexFieldKind(
	identifierFieldIdentifier,
	Multiplicity.Single,
	{
		changeHandler: noChangeHandler,
		allowMonotonicUpgradeFrom: new Set([]),
	},
);
export const forbidden: Forbidden = new FlexFieldKind(
	forbiddenFieldKindIdentifier,
	Multiplicity.Forbidden,
	{
		changeHandler: noChangeHandler,
		allowMonotonicUpgradeFrom: new Set(),
	},
);
export const fieldKindConfigurations: ReadonlyMap<
	ModularChangeFormatVersion,
	FieldKindConfiguration
> = new Map<ModularChangeFormatVersion, FieldKindConfiguration>([
	[
		ModularChangeFormatVersion.v3,
		new Map<FieldKindIdentifier, FieldKindConfigurationEntry>([
			[required.identifier, { kind: required, formatVersion: 2 }],
			[optional.identifier, { kind: optional, formatVersion: 2 }],
			[sequence.identifier, { kind: sequence, formatVersion: 2 }],
			[forbidden.identifier, { kind: forbidden, formatVersion: 1 }],
			[identifier.identifier, { kind: identifier, formatVersion: 1 }],
		]),
	],
	[
		ModularChangeFormatVersion.v4,
		new Map<FieldKindIdentifier, FieldKindConfigurationEntry>([
			[required.identifier, { kind: required, formatVersion: 2 }],
			[optional.identifier, { kind: optional, formatVersion: 2 }],
			[sequence.identifier, { kind: sequence, formatVersion: 3 }],
			[forbidden.identifier, { kind: forbidden, formatVersion: 1 }],
			[identifier.identifier, { kind: identifier, formatVersion: 1 }],
		]),
	],
	[
		ModularChangeFormatVersion.v5,
		new Map<FieldKindIdentifier, FieldKindConfigurationEntry>([
			[required.identifier, { kind: required, formatVersion: 2 }],
			[optional.identifier, { kind: optional, formatVersion: 2 }],
			[sequence.identifier, { kind: sequence, formatVersion: 3 }],
			[forbidden.identifier, { kind: forbidden, formatVersion: 1 }],
			[identifier.identifier, { kind: identifier, formatVersion: 1 }],
		]),
	],
]);
export function getCodecTreeForModularChangeFormat(
	version: ModularChangeFormatVersion,
): CodecTree {
	const dependencies =
		fieldKindConfigurations.get(version) ?? fail(0xc7c  );
	const children: CodecTree[] = [...dependencies.entries()].map(
		([key, { formatVersion }]) => ({
			name: `FieldKind:${key}`,
			version: formatVersion,
		}),
	);
	return {
		name: "ModularChange",
		version,
		children,
	};
}
export const fieldKinds: ReadonlyMap<FieldKindIdentifier, FlexFieldKind> = new Map(
	[required, optional, sequence, identifier, forbidden].map((s) => [s.identifier, s]),
);
export interface Identifier
	extends FlexFieldKind<
		FieldEditor<0>,
		typeof identifierFieldIdentifier,
		Multiplicity.Single
	> {}
export interface Forbidden
	extends FlexFieldKind<
		FieldEditor<0>,
		typeof forbiddenFieldKindIdentifier,
		Multiplicity.Forbidden
	> {}
export const FieldKinds: {
	readonly required: typeof required;
	readonly optional: typeof optional;
	readonly sequence: typeof sequence;
	readonly identifier: Identifier;
	readonly forbidden: Forbidden;
} = { required, optional, sequence, identifier, forbidden };
export const defaultSchemaPolicy: FullSchemaPolicy = {
	fieldKinds,
};
```

### Decision procedure: `feature-libraries/default-schema/mappedEditBuilder.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/mappedEditBuilder.ts:1-75`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export class MappedEditBuilder<TBase, TAdapted> implements IDefaultEditBuilder<TAdapted> {
	public constructor(
		private readonly baseBuilder: IDefaultEditBuilder<TBase>,
		private readonly mapDelegate: (input: TAdapted) => TBase,
	) {}
	public valueField(field: NormalizedFieldUpPath): ValueFieldEditBuilder<TAdapted> {
		const baseField = this.baseBuilder.valueField(field);
		return {
			set: (newContent: TAdapted): void => {
				const mappedContent = this.mapDelegate(newContent);
				baseField.set(mappedContent);
			},
		};
	}
	public optionalField(field: NormalizedFieldUpPath): OptionalFieldEditBuilder<TAdapted> {
		const baseField = this.baseBuilder.optionalField(field);
		return {
			set: (newContent: TAdapted | undefined, wasEmpty: boolean): void => {
				const mappedContent =
					newContent === undefined ? undefined : this.mapDelegate(newContent);
				baseField.set(mappedContent, wasEmpty);
			},
		};
	}
	public sequenceField(field: NormalizedFieldUpPath): SequenceFieldEditBuilder<TAdapted> {
		const baseField = this.baseBuilder.sequenceField(field);
		return {
			insert: (index: number, content: TAdapted): void => {
				const mappedContent = this.mapDelegate(content);
				baseField.insert(index, mappedContent);
			},
			remove: (index: number, count: number): void => {
				baseField.remove(index, count);
			},
		};
	}
	public move(
		sourceField: NormalizedFieldUpPath,
		sourceIndex: number,
		count: number,
		destinationField: NormalizedFieldUpPath,
		destinationIndex: number,
	): void {
		this.baseBuilder.move(sourceField, sourceIndex, count, destinationField, destinationIndex);
	}
	public addNodeExistsConstraint(path: NormalizedUpPath): void {
		this.baseBuilder.addNodeExistsConstraint(path);
	}
	public addNodeExistsConstraintOnRevert(path: NormalizedUpPath): void {
		this.baseBuilder.addNodeExistsConstraintOnRevert(path);
	}
	public addNoChangeConstraint(): void {
		this.baseBuilder.addNoChangeConstraint();
	}
	public addNoChangeConstraintOnRevert(): void {
		this.baseBuilder.addNoChangeConstraintOnRevert();
	}
}
```

### Decision procedure: `feature-libraries/fieldKindIdentifiers.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/fieldKindIdentifiers.ts:1-16`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const optionalIdentifier = brandConst("Optional")<FieldKindIdentifier>();
export const requiredIdentifier = brandConst("Value")<FieldKindIdentifier>();
export const sequenceIdentifier = brandConst("Sequence")<FieldKindIdentifier>();
export const identifierFieldIdentifier = brandConst("Identifier")<FieldKindIdentifier>();
```

## 5. Invariants and asserts

Unknown modular format fails 0xc7c; identifier/forbidden child edits fail 0xb0d. The no-change writer always emits 0; its unit decoder ignores its JSON input and returns 0 without its own schema validation. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/defaultFieldKinds.ts:48` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/defaultFieldKinds.ts:144`

## 6. JS-semantics hazards

Kind identifiers are branded strings on TS side but literal persisted names. Maps have intentional insertion order. Optional and required sharing a payload codec does not make multiplicity interchangeable. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/fieldKindIdentifiers.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/defaultFieldKinds.ts:107`

## 7. Test assets to reuse

Reuse field-kind compatibility and default editor tests plus codec-tree snapshots showing dependent codec mapping. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/feature-libraries/default-field-kinds/defaultChangeFamily.spec.ts:1`

## 8. Open questions

None.

