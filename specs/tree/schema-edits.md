# Schema Edits — Fluid Framework 3.11.0

## 1. Role

Schema-edits defines old/new stored-schema replacement payloads consumed by shared-tree change union. It does not independently sequence or rebase schema edits. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-edits/schemaChangeTypes.ts:6`

## 2. Surface used by other packages

SchemaChange `{schema:{new,old},isInverse}`, makeSchemaChangeCodec and EncodedSchemaChange. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-edits/index.ts:6`

## 3. Wire and persisted formats

JSON `{new:encodedSchema,old:encodedSchema}` in that emission order, no version or isInverse at this envelope. Each schema embeds its own v1/v2 version chosen by schemaCodecBuilder. Both use the same configured writer; decoder dispatches each independently. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-edits/schemaChangeCodecs.ts:19`


### Decision procedure: `feature-libraries/schema-edits/schemaChangeCodecs.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-edits/schemaChangeCodecs.ts:1-45`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export function makeSchemaChangeCodec(
	options: CodecWriteOptions,
): JsonCodecPart<SchemaChange, typeof EncodedSchemaChange> {
	const schemaCodec = schemaCodecBuilder.build(options);
	return {
		encode: (schemaChange: SchemaChange): EncodedSchemaChange => {
			assert(
				!schemaChange.isInverse,
				0x933  ,
			);
			return {
				new: schemaCodec.encode(schemaChange.schema.new),
				old: schemaCodec.encode(schemaChange.schema.old),
			};
		},
		decode: (encoded: EncodedSchemaChange): SchemaChange => {
			return {
				schema: {
					new: schemaCodec.decode(encoded.new),
					old: schemaCodec.decode(encoded.old),
				},
				isInverse: false,
			};
		},
		encodedSchema: EncodedSchemaChange,
	};
}
```

### Decision procedure: `feature-libraries/schema-edits/schemaChangeFormat.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-edits/schemaChangeFormat.ts:1-16`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export const EncodedSchemaChange = Type.Object({
	new: JsonCompatibleReadOnlySchema,
	old: JsonCompatibleReadOnlySchema,
});
export type EncodedSchemaChange = Static<typeof EncodedSchemaChange>;
```

### Literal replacement example

Replacing one empty v1 repository with another emits `{"new":{"version":1,"nodes":{},"root":{"kind":"Forbidden","types":[]}},"old":{"version":1,"nodes":{},"root":{"kind":"Forbidden","types":[]}}}`. With the schema-v2 writer both nested version numbers become 2; no other field is added for empty metadata-free repositories. This example follows new-before-old evaluation and has no outer schema-change version. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-edits/schemaChangeCodecs.ts:19-45`

## 4. Behavior

Encode asserts !isInverse then encodes new before old. Decode decodes new/old and sets isInverse=false. Old schema is required, not inferred from current repository. Compose/invert/rebase semantics are implemented by SharedTreeChangeFamily (companion shared-tree spec); schema-edits itself exports no algebra implementation, so do not invent an LWW schema register here. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-edits/schemaChangeCodecs.ts:24` `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-edits/schemaChangeTypes.ts:6`

### Algorithm notation and completeness

The following decision procedures are part of this specification, not external reading assignments. They preserve exact predicates, allocation order, collection traversal, return shapes and synchronous event calls. `undefined` means absent; `null` is a value; object spread is right-biased; `delete` removes a property; `Map`/`Set` iterate in insertion order. TypeBox `Optional(T)` permits absence, not null; tuples are fixed-order JSON arrays; singleton discriminated unions have exactly one case property. Assertions stop execution at the displayed short code. Helpers in another area use that area's same-named procedure; generic collection utilities retain JavaScript order. These are reference algorithms to translate into Swift, not a proposal to embed TypeScript in the client.

### Decision procedure: `feature-libraries/schema-edits/schemaChangeTypes.ts`

Source: `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-edits/schemaChangeTypes.ts:1-22`. Copyright Microsoft Corporation and contributors; MIT licensed. Imports, comments and blank lines are omitted; executable branches and declarations are retained. Each block has its own module namespace.

```ts
export interface SchemaChange {
	readonly schema: { new: TreeStoredSchema; old: TreeStoredSchema };
	readonly isInverse: boolean;
}
```

## 5. Invariants and asserts

0x933 inverse schema changes must never be transmitted. This is a real invariant, not a feature/version gate. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-edits/schemaChangeCodecs.ts:25`

## 6. JS-semantics hazards

Property order new then old and omitted isInverse are intentional. Schema payload values retain the exact metadata/null/property-order rules of schema-index. `reference/fluidframework-3.11.0/packages/dds/tree/src/feature-libraries/schema-edits/schemaChangeCodecs.ts:29`

## 7. Test assets to reuse

Reuse shared-tree change-codec snapshots containing schema/data sequences and schema replacement tests; codec round-trip must yield isInverse=false. `reference/fluidframework-3.11.0/packages/dds/tree/src/test/shared-tree/sharedTreeChangeCodec.spec.ts:1`

## 8. Open questions

None within this folder. Shared-tree companion spec must cover schema conflict/rebase/rollback policy, because it is implemented there rather than in this codec.

