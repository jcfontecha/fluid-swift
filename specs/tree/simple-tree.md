# Simple Tree — Fluid Framework 3.11.0

## 1. Role

The schema-aware application layer projects forest nodes through identity-preserving kernels. It converts construction and mutation into the default field editors; it is not another CRDT. Swift macros and `@Observable` may replace the declaration/proxy surface, but must not replace forest identity, synchronous edits, or compatibility policy. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/core/treeNodeKernel.ts:103-153` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/prepareForInsertion.ts:56-118`

## 2. Surface used by other packages

Preserve runtime concepts: `SchemaFactory`, node/field schemas, `TreeNode`, `Tree`, `TreeBeta`/`TreeAlpha`, `TreeViewConfiguration`, allowed-type sets, schema upgrade tokens, schema snapshots, insertion preparation, node events and transactions. The public node utility surface is `schema`, `is`, `parent`, `key`, `on`, `status`, `shortId`. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/index.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/treeNodeApi.ts:60-147`

**TS-only machinery:** `Insertable*`, `ReadableField`, `NodeFromSchema`, `WithType`, nominal brands, recursive unsafe interfaces, declaration-extractor workarounds, conditional/mapped/intersection types, generic subclass signatures, and erased API detail are inference scaffolding, not persisted types. Swift may generate typed accessors and constructors directly. Runtime schema identifiers, stored keys, multiplicities, validation, lazy cycle resolution and most-derived-schema identity remain semantic. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/fieldSchema.ts:6-38` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/core/allowedTypes.ts:32-59` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/schemaFactoryRecursive.ts:6`

## 3. Wire and persisted formats

Simple-tree edits have no private op envelope: insertion creates typed forest content; edits enter the SharedTree change union. Stored-schema codecs and field changes are owned by [schema-index.md](schema-index.md), [default-schema.md](default-schema.md), [shared-tree.md](shared-tree.md). The additional format here is the **compatibility snapshot**, not a full schema serialization: metadata, constructor logic and persisted metadata cannot be recovered from it. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/simpleSchemaCodec.ts:34-70`

Snapshot v1 object insertion order is `version`, `root`, `definitions`. Root is `{kind: integer, simpleAllowedTypes: {[identifier]: {isStaged?: boolean}}}`. Each definition is a one-key union `{array:...}`, `{map:...}`, `{record:...}`, `{leaf:...}` or `{object:...}`. Container payload is `{kind,simpleAllowedTypes}`; leaf is `{kind,leafKind}`; object is `{kind,fields,allowUnknownOptionalFields?}`; each field is `{kind,simpleAllowedTypes,storedKey}`. Optional properties are omitted, never encoded as null. Definitions are sorted by identifier using ordinal string comparison; field and allowed-type entries retain iteration order. Node kind numbers are Map=0, Array=1, Object=2, Leaf=3, Record=4; field kinds Optional=0, Required=1, Identifier=2. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/simpleSchemaFormatV1.ts:20-188` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/simpleSchemaCodec.ts:48-69` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/core/treeNodeSchema.ts:487-509` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/fieldSchema.ts:48-70`

A valid empty-map compatibility snapshot (constructed by the map and field encoders) is:
```json
{"version":1,"root":{"kind":1,"simpleAllowedTypes":{"demo.Empty":{}}},"definitions":{"demo.Empty":{"map":{"kind":0,"simpleAllowedTypes":{}}}}}
```
Its empty allowed-type set permits no entries, not arbitrary values. Full snapshot field emission is transcribed below. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/simpleSchemaCodec.ts:126-213`

### Snapshot node and field encoding

Literal oracle procedure (comments removed), `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/simpleSchemaCodec.ts:116-228`:

```typescript
function encodeNodeSchema(schema: SimpleNodeSchema): Format.SimpleNodeSchemaUnionFormat {
	const kind = schema.kind;
	switch (kind) {
		case NodeKind.Leaf: {
			return { leaf: encodeLeafNode(schema) };
		}
		case NodeKind.Array: {
			return { array: encodeContainerNode(schema) };
		}
		case NodeKind.Map: {
			return { map: encodeContainerNode(schema) };
		}
		case NodeKind.Record: {
			return { record: encodeContainerNode(schema) };
		}
		case NodeKind.Object: {
			return { object: encodeObjectNode(schema) };
		}
		default: {
			unreachableCase(kind);
		}
	}
}
function encodeLeafNode(schema: SimpleLeafNodeSchema): Format.SimpleLeafNodeSchemaFormat {
	return {
		kind: schema.kind,
		leafKind: schema.leafKind,
	};
}
function encodeContainerNode(
	schema: SimpleArrayNodeSchema | SimpleMapNodeSchema | SimpleRecordNodeSchema,
):
	| Format.SimpleArrayNodeSchemaFormat
	| Format.SimpleMapNodeSchemaFormat
	| Format.SimpleRecordNodeSchemaFormat {
	return {
		kind: schema.kind,
		simpleAllowedTypes: encodeSimpleAllowedTypes(schema.simpleAllowedTypes),
	};
}
function encodeSimpleAllowedTypes(
	simpleAllowedTypes: ReadonlyMap<string, SimpleAllowedTypeAttributes>,
): Format.SimpleAllowedTypesFormat {
	const encodedAllowedTypes: Format.SimpleAllowedTypesFormat = {};
	for (const [identifier, attributes] of simpleAllowedTypes) {
		const isStaged = attributes.isStaged instanceof SchemaUpgrade ? true : attributes.isStaged;
		encodedAllowedTypes[identifier] = { isStaged };
	}
	return encodedAllowedTypes;
}
function encodeObjectNode(
	schema: SimpleObjectNodeSchema,
): Format.SimpleObjectNodeSchemaFormat {
	const encodedFields: Format.SimpleObjectFieldSchemasFormat = {};
	for (const [fieldKey, fieldSchema] of schema.fields) {
		encodedFields[fieldKey] = encodeObjectField(fieldSchema);
	}
	return {
		kind: schema.kind,
		fields: encodedFields,
		allowUnknownOptionalFields: schema.allowUnknownOptionalFields,
	};
}
function encodeObjectField(
	fieldSchema: SimpleObjectFieldSchema,
): Format.SimpleObjectFieldSchemaFormat {
	const encodedField = encodeField(fieldSchema);
	return { ...encodedField, storedKey: fieldSchema.storedKey };
}
function encodeField(fieldSchema: SimpleFieldSchema): Format.SimpleFieldSchemaFormat {
	return {
		kind: fieldSchema.kind,
		simpleAllowedTypes: encodeSimpleAllowedTypes(fieldSchema.simpleAllowedTypes),
	};
}
```

## 4. Behavior

### Schema declarations: preserved semantics

Explicit name is `scope + "." + name`, or stringified `name` if scope is undefined (an empty scope still adds the dot). Structural names use `Collection<[JSON-quoted sorted identifiers]>`, e.g. `Array<["demo.A","demo.B"]>`; default JS lexical sort and JSON escaping are part of the identifier. Allowed types are unordered schema sets, may contain lazy references for recursion, and reject duplicate runtime entries. Resolve a recursive graph after declarations exist and memoize traversal; do not recursively expand it into an infinite Swift value. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/schemaFactoryUtils.ts:60-92` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/core/allowedTypes.ts:32-59` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/core/walkSchema.ts:6`

Object properties map to fixed stored keys; explicit `key` permits renaming a Swift property without renaming persisted data. Duplicate final stored keys fail. Required fields hold exactly one node, optional fields zero or one, identifiers exactly one immutable string with contextual generation/compression. Node schemas: object=fixed fields; map/record=arbitrary string keys with optional entries; array=one sequence field under empty stored key; leaf=unboxed number/string/boolean/null/Fluid handle. Record is a distinct public node kind but uses the same stored map-node category. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/fieldSchema.ts:48-148` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/toStoredSchema.ts:284-405` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/leafNodeSchema.ts:6`

**TS-only:** factory overloads choose inferred constructor/member types, recursive helpers work around compiler cycles, and proxy traps emulate JS properties/array methods. Swift does not need those traps, but each generated accessor must still invoke the same field operation, not mutate a sidecar model. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/node-kinds/object/objectNode.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/node-kinds/array/arrayNode.ts:1197-1201`

Map `set(key,value)` prepares content under optional map field schema then submits optional register set; undefined deletes. delete returns void, and absent deletion still invokes editor with field-is-empty flag. get absent returns undefined; has tests field presence. Map keys/values/entries/forEach promise NO stable iteration order, unlike JavaScript Map's user-facing guarantee. clear snapshots keys then deletes each in a transaction when hydrated. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/node-kinds/map/mapNode.ts:98-148` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/node-kinds/map/mapNode.ts:330-432`

Leaf input conversion occurs before storage: -0 becomes +0; finite Double remains; NaN and ±Infinity become null ONLY if nullSchema is allowed, otherwise throw UsageError. Strings, booleans, null and Fluid handles pass through; unsupported leaf objects throw. This conversion is a tree insertion rule, not simply JSON.stringify's later treatment of nonfinite numbers. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/leafNodeSchema.ts:205-245`

Object setters may clear only optional fields, enforce declared allowed types and destination stored schema, and preserve unrelated unknown optional content. Field metadata is local unless explicitly persistedMetadata; changing a Swift display label must not silently alter storedKey or schema identifier. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/fieldSchema.ts:82-148` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/prepareForInsertion.ts:56-118`

### Schema evolution: compatibility is directional

Walk root and corresponding reachable schema definitions; report all discrepancies, not merely the first. Compare leaf value kinds and stored node categories (array is an object with sequence empty-key field; record is map). Field multiplicities must match except staged optional view fields can view required stored fields. Missing view-declared stored fields produce forbidden-kind discrepancies. Extra stored fields are viewable only when forbidden, or when optional AND the object opts into `allowUnknownOptionalFields`. Compare ordinary allowed types on both sides; absent staged view types are permitted until enabled, but stored types missing from the view are not silently accepted. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/discrepancies.ts:172-349` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/discrepancies.ts:356-581`

`canView = discrepancies.isEmpty`. Build the proposed upgrade from configured staged policy (default restrictive); `canUpgrade = allowsRepoSuperset(policy, stored, proposed)`; `isEquivalent = canView && canUpgrade && allowsRepoSuperset(policy, proposed, stored)`. These are not aliases. Count each staged token's allowed-type/optional-field locations: no enabled locations means absent status (publicly disabled), some means partial, all means enabled. `includeAlreadyEnabledUpgrades` includes tokens already present even partially when producing the proposed upgrade. Unknown optional fields must survive edits by older clients. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/schemaCompatibilityTester.ts:140-236`

**TS-only:** schema narrowing and generic return types on `hasRootSchema`/`Tree.is` are compile-time conveniences. Runtime membership still uses the registered most-derived schema, not Swift superclass compatibility. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/treeNodeApi.ts:285-298`

### Compatibility discrepancy decision procedures

The following procedures are normative algorithms, not TS inference requirements: generator `yield` appends one discrepancy in iteration order; optional staging tokens are identity keys. They specify all node-kind and field/type mismatch branches.

Literal oracle procedure (comments removed), `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/discrepancies.ts:172-581`:

```typescript
function getStoredNodeSchemaType(nodeSchema: TreeNodeStoredSchema): SchemaFactoryNodeKind {
	if (nodeSchema instanceof ObjectNodeStoredSchema) {
		return ObjectNodeStoredSchema;
	}
	if (nodeSchema instanceof MapNodeStoredSchema) {
		return MapNodeStoredSchema;
	}
	if (nodeSchema instanceof LeafNodeStoredSchema) {
		return LeafNodeStoredSchema;
	}
	fail(0xbe8 );
}
function doesNodeKindMatchStoredNodeKind(
	viewKind: NodeKind,
	storedType: SchemaFactoryNodeKind,
): boolean {
	switch (viewKind) {
		case NodeKind.Leaf: {
			return storedType === LeafNodeStoredSchema;
		}
		case NodeKind.Array:
		case NodeKind.Object: {
			return storedType === ObjectNodeStoredSchema;
		}
		case NodeKind.Map:
		case NodeKind.Record: {
			return storedType === MapNodeStoredSchema;
		}
		default: {
			unreachableCase(viewKind);
		}
	}
}
export function* getDiscrepanciesInAllowedContent(
	view: TreeSchema,
	stored: TreeStoredSchema,
	upgradeCollector?: UpgradeLocationCollector,
): Iterable<Discrepancy> {
	yield* getFieldDiscrepancies(
		view.root,
		stored.rootFieldSchema,
		undefined,
		undefined,
		upgradeCollector,
	);
	for (const [identifier, storedSchema] of stored.nodeSchema) {
		const viewSchema = view.definitions.get(identifier);
		if (viewSchema !== undefined) {
			yield* getNodeDiscrepancies(identifier, viewSchema, storedSchema, upgradeCollector);
		}
	}
}
function* getNodeDiscrepancies(
	identifier: TreeNodeSchemaIdentifier,
	view: TreeNodeSchema,
	stored: TreeNodeStoredSchema,
	upgradeCollector?: UpgradeLocationCollector,
): Iterable<Discrepancy> {
	if (!doesNodeKindMatchStoredNodeKind(view.kind, getStoredNodeSchemaType(stored))) {
		yield {
			identifier,
			mismatch: "nodeKind",
			view: view.kind,
			stored: getStoredNodeSchemaType(stored),
		};
		return;
	}
	switch (view.kind) {
		case NodeKind.Object: {
			assert(
				isObjectNodeSchema(view),
				0xbe9 ,
			);
			yield* computeObjectNodeDiscrepancies(
				identifier,
				view,
				stored as ObjectNodeStoredSchema,
				upgradeCollector,
			);
			break;
		}
		case NodeKind.Array: {
			assert(
				isArrayNodeSchema(view),
				0xbea ,
			);
			const arrayStoredSchema = tryStoredSchemaAsArray(stored);
			if (arrayStoredSchema === undefined) {
				yield {
					identifier,
					mismatch: "nodeKind",
					view: NodeKind.Array,
					stored: getStoredNodeSchemaType(stored),
				};
				return;
			}
			yield* getAllowedTypeDiscrepancies(
				normalizeAndEvaluateAnnotatedAllowedTypes(view.info).types,
				arrayStoredSchema,
				brand(view.identifier),
				EmptyKey,
				false,
				upgradeCollector,
			);
			break;
		}
		case NodeKind.Map: {
			assert(
				isMapNodeSchema(view),
				0xbeb ,
			);
			yield* getFieldDiscrepancies(
				createFieldSchema(FieldKind.Optional, view.info),
				(stored as MapNodeStoredSchema).mapFields,
				identifier,
				undefined,
				upgradeCollector,
			);
			break;
		}
		case NodeKind.Record: {
			assert(
				isRecordNodeSchema(view),
				0xbec ,
			);
			yield* getFieldDiscrepancies(
				createFieldSchema(FieldKind.Optional, view.info),
				(stored as MapNodeStoredSchema).mapFields,
				identifier,
				undefined,
				upgradeCollector,
			);
			break;
		}
		case NodeKind.Leaf: {
			assert(
				view instanceof LeafNodeSchema,
				0xbed ,
			);
			const viewValue = view.leafKind;
			const storedValue = (stored as LeafNodeStoredSchema).leafValue;
			if (viewValue !== storedValue) {
				yield {
					identifier,
					mismatch: "valueSchema",
					view: viewValue,
					stored: storedValue,
				};
			}
			break;
		}
		default: {
			break;
		}
	}
}
export function findExtraAllowedTypes(
	viewAllowedTypes: readonly AnnotatedAllowedType<TreeNodeSchema>[],
	storedAllowedTypes: TreeTypeSet,
): Pick<AllowedTypeDiscrepancy, "view" | "stagedView" | "stored"> {
	const viewNodeSchemaIdentifiers = new Set(
		viewAllowedTypes.map((value) => value.type.identifier),
	);
	const view = viewAllowedTypes.filter(
		(value) =>
			!storedAllowedTypes.has(brand(value.type.identifier)) &&
			value.metadata.stagedSchemaUpgrade === undefined,
	);
	const stagedView = viewAllowedTypes.filter(
		(value) =>
			!storedAllowedTypes.has(brand(value.type.identifier)) &&
			value.metadata.stagedSchemaUpgrade !== undefined,
	);
	const stored = [...storedAllowedTypes].filter(
		(value) => !viewNodeSchemaIdentifiers.has(value),
	);
	return {
		view,
		...(stagedView.length === 0 ? {} : { stagedView }),
		stored,
	};
}
function* getFieldDiscrepancies(
	view: FieldSchema,
	stored: TreeFieldStoredSchema,
	identifier: TreeNodeSchemaIdentifier | undefined,
	fieldKey: FieldKey | undefined,
	upgradeCollector?: UpgradeLocationCollector,
): Iterable<FieldDiscrepancy> {
	assert(
		view instanceof FieldSchemaAlpha,
		0xbee ,
	);
	if (upgradeCollector !== undefined && view.isStagedOptional !== false) {
		upgradeCollector.optionalField(
			view.isStagedOptional,
			stored.kind === FieldKinds.optional.identifier,
		);
	}
	yield* getAllowedTypeDiscrepancies(
		view.allowedTypesFull.evaluate().types,
		stored.types,
		identifier,
		fieldKey,
		view.isStagedOptional !== false,
		upgradeCollector,
	);
	const viewKind =
		convertFieldKind.get(view.kind) ??
		fail(0xbef );
	if (
		viewKind.identifier !== stored.kind &&
		!(view.isStagedOptional !== false && stored.kind === FieldKinds.required.identifier)
	) {
		yield {
			identifier,
			fieldKey,
			mismatch: "fieldKind",
			view: viewKind.identifier,
			stored: stored.kind,
			...(view.isStagedOptional === false ? {} : { viewIsStagedOptional: true }),
		} satisfies FieldKindDiscrepancy;
	}
}
function* getAllowedTypeDiscrepancies(
	view: readonly AnnotatedAllowedType<TreeNodeSchema>[],
	stored: TreeTypeSet,
	identifier: TreeNodeSchemaIdentifier | undefined,
	fieldKey: FieldKey | undefined,
	viewIsStagedOptional: boolean,
	upgradeCollector?: UpgradeLocationCollector,
): Iterable<FieldDiscrepancy> {
	if (upgradeCollector !== undefined) {
		for (const allowedType of view) {
			if (allowedType.metadata.stagedSchemaUpgrade !== undefined) {
				upgradeCollector.allowedType(
					allowedType.metadata.stagedSchemaUpgrade,
					stored.has(brand(allowedType.type.identifier)),
				);
			}
		}
	}
	const discrepancies = findExtraAllowedTypes(view, stored);
	if (discrepancies.view.length > 0 || discrepancies.stored.length > 0) {
		yield {
			...discrepancies,
			identifier,
			fieldKey,
			mismatch: "allowedTypes",
			...(viewIsStagedOptional ? { viewIsStagedOptional: true } : {}),
		} satisfies AllowedTypeDiscrepancy;
	}
}
function* computeObjectNodeDiscrepancies(
	identifier: TreeNodeSchemaIdentifier,
	view: ObjectNodeSchemaPrivate,
	stored: ObjectNodeStoredSchema,
	upgradeCollector?: UpgradeLocationCollector,
): Iterable<FieldDiscrepancy> {
	const viewKeys = new Set<FieldKey>();
	for (const [_, { storedKey: fieldKey, schema: fieldSchema }] of view.flexKeyMap) {
		const storedSchema = stored.objectNodeFields.get(fieldKey);
		viewKeys.add(fieldKey);
		if (storedSchema === undefined) {
			const viewKind =
				convertFieldKind.get(fieldSchema.kind) ??
				fail(0xbf0 );
			yield {
				identifier,
				fieldKey,
				mismatch: "fieldKind",
				view: viewKind.identifier,
				stored: storedEmptyFieldSchema.kind,
				...(fieldSchema instanceof FieldSchemaAlpha && fieldSchema.isStagedOptional !== false
					? { viewIsStagedOptional: true }
					: {}),
			} satisfies FieldKindDiscrepancy;
		} else {
			yield* getFieldDiscrepancies(
				fieldSchema,
				storedSchema,
				identifier,
				fieldKey,
				upgradeCollector,
			);
		}
	}
	for (const [fieldKey, schema] of stored.objectNodeFields) {
		if (schema.kind === forbiddenFieldKindIdentifier) {
			continue;
		}
		if (
			!viewKeys.has(fieldKey) &&
			(!view.allowUnknownOptionalFields || schema.kind !== FieldKinds.optional.identifier)
		) {
			yield {
				identifier,
				fieldKey,
				mismatch: "fieldKind",
				view: storedEmptyFieldSchema.kind,
				stored: schema.kind,
			} satisfies FieldKindDiscrepancy;
		}
	}
}
```

### Nodes, insertion and moves

Unhydrated is a real editable detached construction tree, status `New`, not a half-decoded shared node. Inserting it validates destination stored schema, prepares defaults/identifiers, schedules binding to newly created forest roots, then changes the kernel to forest/anchor-backed state exactly once. The same public node object survives. Existing event listeners migrate to anchors. Hydration is irreversible: later removal gives `Removed`, not `New`; reattachment/revival can return it to `InDocument`; permanent destruction/disposal gives `Deleted`. A node is not an aliasable value: use clone for duplication and move for relocation. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/core/treeNodeKernel.ts:180-240` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/prepareForInsertion.ts:56-118` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/unhydratedFlexTreeFromInsertable.ts:6`

`insertAt(i,...values)` validates an integer gap in [0,length], converts the entire batch before editing, and calls sequence insert. A normal array argument is one item; explicit `TreeArrayNode.spread(iterable)` flattens items. It is not legal to reinsert a parented/hydrated node as fresh content. `removeAt` requires [0,length); `removeRange` defaults to [0,length), clamps end to length, validates start and ordering, then removes end-start. Concurrent clearing removes observed items, not future concurrent inserts. `splice` normalizes negative offsets and clamps count using JS rules, reads removed values, then removes and inserts within a transaction. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/node-kinds/array/arrayNode.ts:110-188` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/node-kinds/array/arrayNode.ts:1197-1280`

Move takes source [start,end) and destination **pre-move gap**. `[a,b,c,d]`, move [1,3) to gap 4 -> `[a,d,b,c]`; moving to a gap inside the source leaves visible ordering unchanged, but is NOT necessarily an empty edit: sequence editor splits detach marks around the attach gap and retains move identities. Do not optimize it away based solely on equal visible arrays. Across arrays, validate every moved type against BOTH destination view types and stored types (staged types may exist in the view but not the document). Hydrated moves require both arrays in the same context/view; hydrated↔unhydrated moves fail. Unhydrated moves use their atomic native editor. Node identity and event subscriptions move with the node. Moving into a descendant of a moved element throws (cycle prevention); when source removal shifts an ancestor of the destination field, the default edit builder adjusts that ancestor path before constructing move-in. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/node-kinds/array/arrayNode.ts:1335-1423` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/default-schema/defaultEditBuilder.ts:324-435` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/sequence-field/sequenceFieldEditor.ts:215-247`

**TS-only:** variadic tuple types, IterableTreeArrayContent wrappers' generic plumbing, index signatures, iterator return types and Array-like prototype exposure can be redesigned. Gap coordinates, ownership checks, atomic moves and ordering cannot. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/node-kinds/array/arrayNode.ts:110-188`

### Events and observable integration

Node events run synchronously after the entire batch is applied and in-schema. Shallow changes emit `nodeChanged`; descendant changes emit `treeChanged`, not ancestor `nodeChanged`. Moving/removing a node notifies its parent, not the moved node merely because its location changed. Directly changed nodes are visited in first-edited order; at each node `nodeChanged` precedes `treeChanged`; a single deep edit propagates tree notifications bottom-up. Do not substitute a global depth sort. Array event listeners share the shallow source and retain registration order; keep the oracle event-order tests as the authority for mixed listener registrations. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/treeChangeEvents.ts:32-109` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/treeNodeApi.ts:182-279`

Object node payload has `changedProperties:Set<propertyKey>` plus `changedUnknownProperties:Set<storedKey>` only if nonempty. Map/record changes report their keys. Array shallow delta is `{delta?: [retain|insert|remove]}` with `{type,count}` entries; tree delta retain additionally carries `subtreeChanged`. Missing/uncomposable marks produce `delta:undefined`, not an empty delta; consumers must reread. A deep-only array change normally suppresses nodeChanged, but unavailable marks conservatively emit it. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/treeNodeApi.ts:192-278`

Checkout path: lock edits → `beforeBatch` → apply data deltas/schema replacements in subchange order → `afterBatch` → unlock → validate appended commits. Branch `changed` callbacks are locked too; view forwards `changed` then `commitApplied`. View schema refresh tears down the old context and, if compatible, installs the new context; outside schema edits emits `schemaChanged` then `rootChanged`. Ordinary afterBatch emits rootChanged only when root identity changes and not mid-upgrade. Schema edit completion flushes pending hydration BEFORE schemaChanged/rootChanged. `@Observable` updates must reflect this synchronous order, even if UI rendering is coalesced. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1238-1275` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/schematizingTreeView.ts:285-303` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/schematizingTreeView.ts:550-642`

### Tree utilities and transactions

`Tree.contains(node,other)` (`reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/tree.ts:39-81`) walks other’s parent chain, returns true for self or any descendant, false otherwise; it is identity-based and works before/after hydration. `Tree.parent` returns the current parent or undefined at a detached/document root. `Tree.key` returns root-field key at roots, otherwise developer property key, map/record key or numeric sequence index; it reverses stored-key mapping. `Tree.schema` accepts nodes and unboxed leaves; `Tree.is` returns false for non-tree values, otherwise set-membership by schema; `Tree.status` distinguishes New/InDocument/Removed/Deleted. `shortId` prefers compressed identifiers but can return a string or undefined. These must query the live kernel; never cache parent/index in Swift. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/treeNodeApi.ts:153-305`

Beta/alpha additions cover clone/create, concise/verbose/compressed import/export, context/branch access, children and locations. Cloning creates unhydrated independent content; serialization is not identity transfer. Swift method names need not mirror release-tag interfaces. Clone preserves identifier VALUES and unknown optional fields: cloning is not a fresh-ID operation. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeBeta.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeAlpha.ts:6` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/cloneTree.ts:6`

New transaction API states: idle→mounted by checking alive/unlocked, rejecting async nesting, pushing label, starting stack with postprocessor/custom metadata, then adding preconditions. Mounted→aborted iff callback returns `rollback:true`: pop aborted label, abort stack, return `{success:false,value?}`. Otherwise add revert preconditions, close label, commit stack, clear outer label, return `{success:true,value?}`. `value` is omitted if undefined. Synchronous callback exceptions do NOT trigger this return path: breakingMethod marks the checkout broken; do not invent recovery. Async permits awaiting at the API edge, never interleaving inside synchronous change application. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1343-1454`

Node-exists constraints require `InDocument` now, then add existence constraint on anchor; revert constraints attach to the inverse. `noChange` captures no subsequent changes after callback return, requires SharedTree change format 5, and is also supported on revert. Constraint failure after sequencing is not equivalent to local rollback: fully dropped versus new-content-only outcomes differ. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:483-545` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1100-1133` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/sharedTreeChangeCodecs.ts:95-100`

Additional preserved Tree operations (TS overloads are not requirements):

| API | Semantics |
|---|---|
| Beta.create/importConcise | Construct unhydrated field content using schema inference; ambiguous plain objects require explicit typed nodes/verbose format. |
| Beta.clone | Copy persisted content INCLUDING identifiers and unknown optional fields; leaf values/handles pass through unchanged; local custom instance state is initialized, not cloned. |
| Beta.exportConcise | Snapshot with inferred type information omitted; object defaults to developer property keys. Undefined optional root remains undefined. |
| Alpha.importVerbose/exportVerbose | Typed nonleaf nodes `{type:string,fields:array-or-record}`; leaves unboxed. Import validates schema; unknown optional-field input and nonempty default omissions are not supported by this API. |
| Alpha.importCompressed/exportCompressed | Always stored keys; field-batch compression selected by minVersionForCollab; an explicitly supplied compressor must also be supplied at decode; caller owns view-schema compatibility guarantee. |
| Alpha.key2/child/children | key2 gives undefined at root (unlike stable key); numeric array index otherwise. child/children use PROPERTY keys, omit absent and unknown optional object fields; children promises no universal order. |
| Alpha.identifier.shorten/lengthen/getShort/create | Use the view's compressor to convert/create stable IDs; shortening may be unavailable; local compressed values cannot cross sessions without normalization. |

`reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeBeta.ts:51-147` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeAlpha.ts:153-216` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeAlpha.ts:311-435`

Concrete verbose array snapshot for PlainText.StringArray is `{"type":"com.fluidframework.text.StringArray","fields":["a","😀"]}`. Leaf `"x"` remains `"x"`, not `{type,fields}`. Concise counterpart is `["a","😀"]`. These are app export formats, not the forest summary itself. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/verboseTree.ts:64-115` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/conciseTree.ts:20-39`

The deprecated `Tree.runTransaction` differs: takes view or hydrated node, rejects unhydrated nodes, returns callback value or rollback sentinel; on thrown callback it aborts and rethrows. Swift must decide its public redesign explicitly while preserving whichever oracle entry point a differential case exercises. **TS-only:** overloads inferring callback root/node, success/failure union narrowing and void-result specializations need not be copied. `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/tree.ts:430-488`

## 5. Invariants and asserts

Hydration: disposed node fails 0xa2a, repeated hydration 0xa2b, duplicate public node binding 0x7f5. Root cardinality other than 0/1 fails 0xac8. Missing stored array schema fails 0xc16. Required node-in-document constraint assumes hydration (0xbc2). Schema replacements must be supersets unless the explicit internal inverse path is used (0xbe6). Reentrant edits from change callbacks fail the edit lock. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/core/treeNodeKernel.ts:186-203` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:1072-1089` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/node-kinds/array/arrayNode.ts:1342-1347` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:494-495` `reference/fluidframework-3.11.0/packages/dds/tree/src/shared-tree/treeCheckout.ts:2018-2029`

## 6. JS-semantics hazards

Do not collapse undefined/missing and null; null is a leaf, undefined clears an optional field. JS object enumeration, lexical UTF-16 sort and JSON escaping affect schema names/snapshots. Class identity checks are not structural schema equality. Arrays are tree nodes, not Swift copy-on-write values. Parent/index/identifier may change or become unavailable after edits. Defaults can require hydrated context. Event callbacks cannot become async tasks, and observation must not make reentrant edits legal. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/schemaFactoryUtils.ts:60-92` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/fieldSchema.ts:211-238` `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/treeNodeApi.ts:153-305`

## 7. Test assets to reuse

Port source suites under `src/test/simple-tree`: schemaFactory, recursive schemas, schemaCompatibilityTester, schema snapshots, object/map/array nodes, unhydrated nodes, and the event-order suite. Differential scenarios must cover schema widening versus merely viewable unknown optional fields; insertion preserving node reference/listeners; within-array overlap and cross-view rejection; nested commit/rollback; exception differences; unavailable array delta. The exact event-order fixture is `src/test/simple-tree/api/treeChangeEventOrdering.spec.ts`. `reference/fluidframework-3.11.0/packages/dds/tree/src/simple-tree/api/treeChangeEvents.ts:76-79`

## 8. Open questions

None for the semantics above. Swift macro spelling and observation integration are intentionally a redesign, not a wire-format decision.

